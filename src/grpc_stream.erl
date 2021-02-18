%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

%% The gRPC stream
-module(grpc_stream).

-behavior(cowboy_handler).

-include("grpc.hrl").

%% APIs
-export([ recv/1
        , recv/2
        , reply/2
        ]).

%% cowboy callbacks
-export([init/2]).

%% Internal callbacks
-export([ handle_in/2
        , handle_out/3
        ]).

-type stream() :: #{ req           := cowboy_req:req()
                   , rest          := binary()
                   , metadata      := map()
                   , encoding      := grpc_frame:encoding()
                   , compression   := grpc_frame:compression()
                   , decoder       := function()
                   , encoder       := function()
                   , handler       := {atom(), atom()}
                   , is_unary      := boolean()
                   , input_stream  := boolean()
                   , output_stream := boolean()
                   , client_info   := map()
                   }.

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

recv(St) ->
    recv(St, 15000).

-spec recv(stream(), timeout()) -> {more | eos, [map()], stream()}.
recv(St = #{req         := Req,
            rest        := Rest,
            decoder     := Decoder,
            compression := Compression}, Timeout) ->
    {More, Bytes, NReq} = cowboy_req:read_body(Req, #{length => 5, period => Timeout}),
    {NRest, Frames} = grpc_frame:split(<<Rest/binary, Bytes/binary>>, Compression),

    NSt = St#{rest => NRest, req => NReq},
    Requests = lists:map(Decoder, Frames),
    case More of
        more -> {more, Requests, NSt};
        _ -> {eos, Requests, NSt}
    end.

-spec reply(stream(), map() | list(map())) -> ok.

reply(St, Resp) when is_map(Resp) ->
    reply(St, [Resp]);

reply(#{req         := Req,
        encoder     := Encoder,
        compression := Compression}, Resps) ->
    IoData = lists:map(fun(F) ->
                grpc_frame:encode(Compression, F)
             end, lists:map(Encoder, Resps)),
    ok = cowboy_req:stream_body(IoData, nofin, Req).

%%--------------------------------------------------------------------
%% Cowboy handler callback

init(Req, Options) ->
    St = do_init_state(
           #{req => Req,
             rest => <<>>,
             metadata => #{},
             encoding => identity,
             compression => maps:get(compression, Options, identity),
             timeout => infinity}, Req),
    Services = maps:get(services, Options, #{}),
    RpcServicesAndName = {_, ReqRpc} =
        {cowboy_req:binding(service, Req), cowboy_req:binding(method, Req)},
    case maps:get(RpcServicesAndName, Services, undefined) of
        undefined ->
            shutdown(?GRPC_STATUS_NOT_FOUND, <<"">>, send_headers_first(St));
        Defs ->
            case authenticate(Req, Options) of
                {true, ClientInfo} ->
                    ReqRpc1 = list_to_existing_atom(grpc_lib:list_snake_case(ReqRpc)),
                    NSt = St#{
                            decoder => decoder_func(Defs),
                            encoder => encoder_func(Defs),
                            handler => {maps:get(handler, Defs), ReqRpc1},
                            is_unary => not maps:get(input_stream, Defs)
                                        andalso not maps:get(output_stream, Defs),
                            input_stream => maps:get(input_stream, Defs),
                            output_stream => maps:get(output_stream, Defs),
                            client_info => ClientInfo
                           },
                    try
                        before_loop(send_headers_first(NSt))
                    catch T:R:Stk ->
                        ?LOG(error, "Stream process crashed: ~p, ~p, stacktrace: ~p~n",
                                     [T, R, Stk]),
                        shutdown(?GRPC_STATUS_INTERNAL, <<"Internal error">>, St)
                    end;
                _ ->
                    shutdown(?GRPC_STATUS_UNAUTHENTICATED, <<"">>, St)
            end
    end.

do_init_state(St, #{headers := Headers}) ->
    maps:fold(fun process_header/3, St, Headers).

process_header(<<"grpc-timeout">>, Value, Acc) ->
    Acc#{timeout => Value};
process_header(<<"grpc-encoding">>, Value, Acc) ->
    Acc#{encoding => Value};
process_header(<<"grpc-message-type">>, Value, Acc) ->
    Acc#{message_type => Value};
process_header(<<"user-agent">>, Value, Acc) ->
    Acc#{user_agent => Value};
process_header(<<"content-type">>, Value, Acc) ->
    Acc#{content_type => Value};
process_header(K, _Value, Acc)
  when K == <<"te">>;
       K == <<"content-length">> ->
    %% XXX: not clear what should be done with this header
    Acc;
process_header(Key, Value, #{metadata := Metadata} = Acc) ->
    {_, DecodedValue} = grpc_lib:maybe_decode_header({Key, Value}),
    Acc#{metadata => Metadata#{Key => DecodedValue}}.

authenticate(Req, #{auth_fun := AuthFun}) when is_function(AuthFun) ->
    case cowboy_req:cert(Req) of
        undefined ->
            false;
        Cert when is_binary(Cert) ->
            AuthFun(Cert)
    end;
authenticate(_Req, _Options) ->
    {true, undefined}.

decoder_func(#{pb := Pb, input := InputName}) ->
    fun(Frame) ->
        Pb:decode_msg(Frame, InputName)
    end.
encoder_func(#{pb := Pb, output := OutputName}) ->
    fun(Msg) ->
        Pb:encode_msg(Msg, OutputName)
    end.

before_loop(St = #{is_unary := true}) ->
    Req = maps:get(req, St),
    case cowboy_recv(Req) of
        {ok, Bytes, NReq} ->
            Rest = maps:get(rest, St),
            Compression = maps:get(compression, St),
            {NRest, Frames} = grpc_frame:split(<<Rest/binary, Bytes/binary>>, Compression),
            InEvnts = [{handle_in, [Frame]} || Frame <- Frames],
            NSt = events(InEvnts, St#{rest => NRest, req => NReq}),
            shutdown(?GRPC_STATUS_OK, <<"">>, NSt);
        {error, _Reason} ->
            shutdown(?GRPC_STATUS_INTERNAL, <<"Recv body">>, St)
    end;

before_loop(St = #{is_unary := false}) ->
    try
        Metadata = maps:get(metadata, St),
        {Mod, Fun} = maps:get(handler, St),
        case apply(Mod, Fun, [St, Metadata]) of
            {ok, NSt} ->
                shutdown(?GRPC_STATUS_OK, <<"">>, NSt);
            {Code, Reason, NSt} ->
                shutdown(Code, Reason, NSt)
        end
    catch T:R:Stk ->
        ?LOG(error, "Handle frame crashed: {~p, ~p} stacktrace: ~0p~n",
                     [T, R, Stk]),
        shutdown(?GRPC_STATUS_INTERNAL, <<"RPC Execution Crashed">>, St)
    end.

events([], St) ->
    St;
events([{F, Args} | Events], St) ->
    case apply(?MODULE, F, Args ++ [St]) of
        {shutdown, Code, Message} ->
            shutdown(Code, Message, St);
        {ok, NEvents, NSt} ->
            events(NEvents ++ Events, NSt);
        {ok, NSt} ->
            events(Events, NSt)
    end.

shutdown(Status, Message, St) ->
    Req = maps:get(req, St),
    Trailers = #{<<"grpc-status">> => Status,
                 <<"grpc-message">> => Message
                },
    cowboy_send_trailers(Trailers, Req),
    {ok, Req, []}.

headers(St) ->
    Meta = maps:get(metadata, St),
    Headers = case maps:get(compression, St) of
                  gzip ->
                      Meta#{<<"grpc-encoding">> => <<"gzip">>};
                  _ -> Meta
              end,
    NHeaders = Headers#{
                 <<"content-type">> => <<"application/grpc">>
                },
    grpc_lib:maybe_encode_headers(NHeaders).

%% Ret :: {shutdown, Code, Message}
%%      | {ok, NEvents, NSt}
%%
%% event :: {handle_out, [headers, Hs]}
%%        | {handle_rpc, [x]}
handle_in(Frame, St) ->
    Decoder = maps:get(decoder, St),
    try
        Request = Decoder(Frame),
        Metadata = maps:get(metadata, St),
        {Mod, Fun} = maps:get(handler, St),
        case apply(Mod, Fun, [Request, Metadata]) of
            {ok, Resp, NMetadata} ->
                {ok, [{handle_out, [reply, Resp]}], St#{metadata => NMetadata}};
            {error, Code} ->
                %% FIXME: Streaming: shutdown / reply_error ??
                {shutdown, Code, <<"">>}
        end
    catch T:R:Stk ->
        ?LOG(error, "Handle frame crashed: {~p, ~p} stacktrace: ~0p~n",
                     [T, R, Stk]),
        {shutdown, ?GRPC_STATUS_INTERNAL, <<"RPC Execution Crashed">>}
    end.

handle_out(reply, Resp, St) ->
    Encoder = maps:get(encoder, St),
    Compression = maps:get(compression, St),
    Bytes = grpc_frame:encode(Compression, Encoder(Resp)),

    #{req := Req} = St,
    _ = cowboy_send_body(Bytes, Req),
    {ok, St}.

send_headers_first(St) ->
    Req = maps:get(req, St),
    NReq = cowboy_send_header(headers(St), Req),
    St#{req => NReq}.

%%--------------------------------------------------------------------
%% Cowboy layer funcs
%%--------------------------------------------------------------------

cowboy_recv(Req) ->
    cowboy_recv(Req, <<>>).

cowboy_recv(Req, Acc) ->
    %% FIXME: Streaming??
    %% Read at least 5 bytes
    case catch cowboy_req:read_body(Req, #{length => 5}) of
        {ok, Bytes, NReq} ->
            {ok, <<Acc/binary, Bytes/binary>>, NReq};
        {more, Bytes, NReq} ->
            cowboy_recv(NReq, <<Acc/binary, Bytes/binary>>);
        {'EXIT', {Reason, _Stk}} ->
            ?LOG(error, "Read body occuring an error: ~p, stacktrace: ~p~n", [Reason, _Stk]),
            {error, Reason}
    end.

cowboy_send_header(Headers, Req) ->
    cowboy_req:stream_reply(200, Headers, Req).

cowboy_send_body(Bytes, Req) ->
    ok = cowboy_req:stream_body(Bytes, nofin, Req).

cowboy_send_trailers(Trailers, Req) ->
    ok = cowboy_req:stream_trailers(Trailers, Req).
