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

-module(grpc_cowboy_h).

-include("grpc.hrl").

%% cowboy callbacks
-export([init/2]).

%% Internal callbacks
-export([ handle_in/2
        , handle_out/3
        ]).

init(Req, Options) ->
    do_init(Req, Options).

%%--------------------------------------------------------------------
%% gRPC stream loop
%%--------------------------------------------------------------------

do_init(Req, Options) ->
    St = do_init_state(
           #{req => Req,
             rest => <<>>,
             headers_sent => false,
             metadata => #{},
             encoding => identity,
             compression => maps:get(compression, Options, identity),
             timeout => infinity}, Req),
    Services = maps:get(services, Options, #{}),
    RpcServicesAndName = {_, ReqRpc} =
        {binary_to_existing_atom(cowboy_req:binding(service, Req), utf8),
         binary_to_existing_atom(cowboy_req:binding(method, Req), utf8)},
    case maps:get(RpcServicesAndName, Services, undefined) of
        undefined ->
            shutdown(?GRPC_STATUS_NOT_FOUND, <<"">>, St);
        Defs ->
            case authenticate(Req, Options) of
                {true, ClientInfo} ->
                    ReqRpc1 = list_to_existing_atom(grpc_lib:list_snake_case(ReqRpc)),
                    NSt = St#{
                            decoder => decoder_func(Defs),
                            encoder => encoder_func(Defs),
                            handler => {maps:get(handler, Defs), ReqRpc1},
                            input_stream => maps:get(input_stream, Defs),
                            output_stream => maps:get(output_stream, Defs),
                            client_info => ClientInfo
                           },
                    try
                        loop(NSt)
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

loop(St) ->
    Req = maps:get(req, St),
    case cowboy_recv(Req) of
        {ok, Bytes, NReq} ->
            Rest = maps:get(rest, St),
            Compression = maps:get(compression, St),
            {NRest, Frames} = grpc_frame:split(<<Rest/binary, Bytes/binary>>, Compression),
            InEvnts = [{handle_in, [Frame]} || Frame <- Frames],
            events(InEvnts, St#{rest => NRest, req => NReq});
        {error, _Reason} ->
            shutdown(?GRPC_STATUS_INTERNAL, <<"Recv body">>, St)
    end.

events([], St) ->
    case maps:get(input_stream, St) of
        true ->
            loop(St);
        _ ->
            shutdown(?GRPC_STATUS_OK, <<"">>, St)
    end;
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
    NReq = case maps:get(headers_sent, St, false) of
               false ->
                   %% XXX: Only one "Trailers-Only" should be answered here.
                   %%      Or send a HEADERS frame only?
                   cowboy_send_header(headers(St), Req);
               _ -> Req
           end,
    cowboy_send_trailers(Trailers, NReq),
    {ok, NReq, []}.

headers(St) ->
    Meta = maps:get(metadata, St),
    Headers = case maps:get(compression, St) of
                  gzip ->
                      Meta#{<<"grpc-encoding">> => <<"gzip">>};
                  _ -> Meta
              end,
    grpc_lib:maybe_encode_headers(Headers).

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
    %% Streaming ??
    Encoder = maps:get(encoder, St),
    Compression = maps:get(compression, St),
    Bytes = grpc_frame:encode(Compression, Encoder(Resp)),

    NSt = #{req := Req}  = maybe_send_headers_first(St),
    _ = cowboy_send_body(Bytes, Req),
    {ok, NSt}.

maybe_send_headers_first(St) ->
    case maps:get(headers_sent, St, false) of
        true -> St;
        _ ->
            Req = maps:get(req, St),
            NReq = cowboy_send_header(headers(St), Req),
            St#{req => NReq, headers_sent => true}
    end.

%%--------------------------------------------------------------------
%% Cowboy layer funcs
%%--------------------------------------------------------------------

cowboy_recv(Req) ->
    Len = cowboy_req:body_length(Req),
    cowboy_recv(Req, Len, <<>>).

cowboy_recv(Req, Len, Acc) ->
    %% FIXME: Streaming??
    case catch cowboy_req:read_body(Req, #{length => Len}) of
        {ok, Bytes, NReq} ->
            {ok, <<Acc/binary, Bytes/binary>>, NReq};
        {more, Bytes, NReq} ->
            cowboy_recv(NReq, Len - byte_size(Bytes), <<Acc/binary, Bytes/binary>>);
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
