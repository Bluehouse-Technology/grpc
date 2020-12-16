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

-module(grpc_client).

-behaviour(gen_server).

-include("grpc.hrl").

%% APIs
-export([ unary/4
        , open_stream/4
        , streaming/2
        , streaming/3
        ]).

%% APIs
-export([start_link/4]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

-export([ unary_handler_incoming/4
        , unary_handler_closed/4
        ]).

-record(state, { pool
               , id
               , gun_pid
               , mref
               , encoding
               , server
               , streams :: #{reference() := stream()}
               , gun_opts
               }).

-type request() :: map().

-type response() :: map().

-type encoding() :: identity | gzip | deflate | snappy.

-type options() ::
        #{ channel => term()
         , encoding => encoding()
         , atom() => term()
         }.

-type def() ::
        #{ path := binary()
         , service := atom()
         , message_type := binary()
         , marshal := function()
         , unmarshal := function()
         }.

-type server() :: {http | https, string(), inet:port_number()}.

-type grpc_opts() ::
        #{ encoding => encoding()
         , gun_opts => gun:opts()
         }.

-export_type([request/0, response/0, def/0, options/0, encoding/0]).

-define(headers(Encoding, MessageType, Timeout, MD),
        [{<<"grpc-encoding">>, Encoding},
         {<<"grpc-message-type">>, MessageType},
         {<<"grpc-timeout">>, ms2timeout(Timeout)},
         {<<"content-type">>, <<"application/grpc+proto">>},
         {<<"user-agent">>, <<"grpc-erlang/0.1.0">>},
         {<<"te">>, <<"trailers">>} | maps:to_list(MD)]).

-define(DEFAULT_GUN_OPTS,
        #{protocols => [http2],
          connect_timeout => 5000,
          http2_opts => #{keepalive => 60000}
         }).

-define(UNARY_TIMEOUT, 5000).

-type stream_state() :: idle | open | closed.

-type stream() :: #{ st        := {LocalState :: stream_state(),
                                   RemoteState :: stream_state()}
                   , reply_to  := pid()
                   , recvbuff  := binary()
                   , endts     := non_neg_integer()
                   , def       := def()
                   , handlers  := stream_handler()
                   , encoding  := encoding()
                   }.

-type client_pid() :: pid().

-type stream_handler() :: #{ created := {function(), list()}
                           , incoming := {function(), list()}
                           , closed := {function(), list()}
                           }.

-type grpcstream() :: #{client_pid := client_pid(),
                        stream_ref := reference(),
                        def := def()
                        }.

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

-spec start_link(term(), pos_integer(), server(), grpc_opts())
    -> {ok, pid()} | ignore | {error, term()}.
start_link(Pool, Id, Server, Opts) when is_map(Opts)  ->
    gen_server:start_link(?MODULE, [Pool, Id, Server, Opts], []).

%%--------------------------------------------------------------------
%% GRPC APIs
%%--------------------------------------------------------------------

-spec unary(def(), request(), grpc:metadata(), options())
    -> {ok, response(), grpc:metadata()}
     | {error, {grpc_error, grpc_status(), grpc_message()}}
     | {error, term()}.
%% @doc Unary function call
unary(Def, Req, Metadata, Options) ->
    Timeout = maps:get(timeout, Options, ?UNARY_TIMEOUT),

    Ref = erlang:make_ref(),
    Handlers = #{incoming => {fun ?MODULE:unary_handler_incoming/4, [self(), Ref]},
                 closed   => {fun ?MODULE:unary_handler_closed/4, [self(), Ref]}
                },
    Unmarshal = maps:get(unmarshal, Def),
    case open_stream(Def, Handlers, Metadata, Options) of
        {ok, GStream} ->
            case streaming(GStream, Req, fin) of
                ok ->
                    receive
                        {unary_resp, Ref, Frame} ->
                            receive
                                {unary_trailers, Ref, Trailers} ->
                                    {ok, Unmarshal(Frame), Trailers}
                            after Timeout ->
                                 {error, timeout}
                            end
                    after Timeout ->
                        {error, timeout}
                    end;
                E -> E
            end;
        E -> E
    end.

unary_handler_incoming(_StreamRef, [Frame], Parent, Ref) ->
    Parent ! {unary_resp, Ref, Frame}.

unary_handler_closed(_StreamRef, Trailers, Parent, Ref) ->
    Parent ! {unary_trailers, Ref, Trailers}.

-spec open_stream(def(), stream_handler(), grpc:metadata(), options())
    -> {ok, grpcstream()}
     | {error, term()}.

open_stream(Def, Handler, Metadata, Options) ->
    ClientPid = pick(maps:get(channel, Options, undefined)),
    case call(ClientPid, {open_stream, Def, Handler, Metadata, Options}) of
        {ok, StreamRef} ->
            {ok, #{stream_ref => StreamRef, client_pid => ClientPid, def => Def}};
        {error, _} = Error -> Error
    end.

-spec streaming(grpcstream(), request()) -> ok.
streaming(GStream, Req) ->
    streaming(GStream, Req, nofin).

streaming(_GStream = #{
             def        := Def,
             client_pid := ClientPid,
             stream_ref := StreamRef
          }, Req, IsFin) ->
    #{marshal := Marshal} = Def,
    Bytes = Marshal(Req),
    case call(ClientPid, {streaming, StreamRef, Bytes, IsFin}) of
        ok -> ok;
        {error, R} -> error(R)
    end.

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([Pool, Id, Server = {_, _, _}, Opts]) ->
    Encoding = maps:get(encoding, Opts, identity),
    GunOpts = maps:get(gun_opts, Opts, #{}),
    NGunOpts = maps:merge(?DEFAULT_GUN_OPTS, GunOpts),
    true = gproc_pool:connect_worker(Pool, {Pool, Id}),
    {ok, #state{
            pool = Pool,
            id = Id,
            gun_pid = undefined,
            server = Server,
            encoding = Encoding,
            streams = #{},
            gun_opts = NGunOpts}}.

handle_call(Req, From, State = #state{gun_pid = undefined}) ->
    case do_connect(State) of
        {error, Reason} ->
            {reply, {error, Reason}, State};
        NState ->
            handle_call(Req, From, NState)
    end;

handle_call({open_stream, Def = #{
                            path := Path,
                            message_type := MessageType
                          }, Handlers, Metadata, Options},
            From,
            State = #state{gun_pid = GunPid, streams = Streams, encoding = Encoding}) ->
    Timeout = maps:get(timeout, Options, ?UNARY_TIMEOUT),
    Headers = ?headers(atom_to_binary(Encoding, utf8), MessageType, Timeout, Metadata),
    StreamRef = gun:post(GunPid, Path, Headers),
    EndingTs = erlang:system_time(millisecond) + Timeout,

    Stream = #{type => stream,
               st => {open, idle},
               reply_to => From,
               recvbuff => <<>>,
               endts => EndingTs,
               def => Def,
               handlers => Handlers,
               encoding => Encoding
              },
    NState = State#state{streams = Streams#{StreamRef => Stream}},
    {reply, {ok, StreamRef}, NState};

handle_call(_Req = {streaming, StreamRef, Bytes, IsFin},
            _From,
            State = #state{gun_pid = GunPid, streams = Streams, encoding = Encoding}) ->
    case maps:get(StreamRef, Streams, undefined) of
        Stream = #{st := {open, _RS}} ->
            NBytes = grpc_frame:encode(Encoding, Bytes),
            gun:data(GunPid, StreamRef, IsFin, NBytes),
            case IsFin of
                fin ->
                    NStreams = maps:put(StreamRef, Stream#{st => {closed, _RS}}, Streams),
                    {reply, ok, State#state{streams = NStreams}};
                _ ->
                    {reply, ok, State}
            end;
        #{st := {closed, _RS}} ->
            {reply, {error, closed}, State};
        undefined ->
            {reply, {error, not_found}, State};
        _S ->
            ?LOG(error, "Bad stream state: ~p, ignore streaming request: ~p", [_S, _Req]),
            {reply, {error, bad_stream}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unkown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({gun_up, GunPid, http2}, State = #state{gun_pid = GunPid}) ->
    {noreply, State};

handle_info({gun_down, GunPid, http2, Reason, KilledStreamRefs, _},
            State = #state{gun_pid = GunPid, streams = Streams}) ->
    NowTs = erlang:system_time(millisecond),
    %% Reply killed streams error
    _ = maps:fold(fun(_, #{reply_to := From, endts := EndingTs}, _Acc) ->
        NowTs =< EndingTs andalso
          gen_server:reply(From, {error, Reason})
    end, [], maps:with(KilledStreamRefs, Streams)),
    {noreply, State#state{streams = maps:without(KilledStreamRefs, Streams)}};

handle_info({'DOWN', MRef, process, GunPid, Reason},
            State = #state{mref = MRef, gun_pid = GunPid, streams = Streams}) ->
    ?LOG(warning, "[gRPC Client] Connection process ~p down, reason: ~p~n", [GunPid, Reason]),
    NowTs = erlang:system_time(millisecond),
    _ = maps:fold(fun(_, #{reply_to := From, endts := EndingTs}, _Acc) ->
        NowTs =< EndingTs andalso
          gen_server:reply(From, {error, Reason})
    end, [], Streams),
    {noreply, State#state{gun_pid = undefined, streams = #{}}};

handle_info(Info, State = #state{streams = Streams}) when is_tuple(Info) ->
    Ls = [gun_response, gun_trailers, gun_data, gun_error],
    case lists:member(element(1, Info), Ls) of
        true ->
            StreamRef = element(3, Info),
            case maps:get(StreamRef, Streams, undefined) of
                undefined ->
                    ?LOG(warning, "[gRPC Client] Unknown stream ref: ~0p, event: ~0p", [StreamRef, Info]),
                    {noreply, State};
                Stream ->
                    NStreams =
                        case stream_handle(Info, Stream) of
                            {shutdown, normal, _Stream} ->
                                maps:remove(StreamRef, Streams);
                            {shutdown, Reason, Stream} ->
                                ?LOG(error, "[gRPC Client] Stream ~0p shutdown for ~0p", [Stream, Reason]),
                                maps:remove(StreamRef, Streams);
                            {ok, NStream} ->
                                maps:put(StreamRef, NStream, Streams);
                            ok -> Streams
                        end,
                   {noreply, State#state{streams = NStreams}}
            end;
        _ ->
            ?LOG(warning, "[gRPC Client] Unexpected info: ~p~n", [Info]),
            {noreply, State}
    end.

terminate(_Reason, #state{pool = Pool, id = Id}) ->
    gproc_pool:disconnect_worker(Pool, {Pool, Id}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Streams handle
%%--------------------------------------------------------------------

stream_handle({gun_response, _GunPid, StreamRef, nofin, Status, Headers},
              Stream = #{st := {_LS, idle}, handlers := Handlers}) ->
    case maps:get(created, Handlers, undefined) of
        undefined -> ok;
        Cbfun ->
            eval_stream_callback([StreamRef, Status, Headers], Cbfun)
    end,
    {ok, Stream#{st => {_LS, open}}};

stream_handle({gun_trailers, _GunPid, StreamRef, Trailers},
              Stream = #{st := {_LS, open}, handlers := Handlers}) ->
    case maps:get(closed, Handlers, undefined) of
        undefined -> ok;
        Cbfun ->
            eval_stream_callback([StreamRef, Trailers], Cbfun)
    end,
    case _LS == closed of
        true ->
            {shutdown, normal, Stream#{st => {_LS, closed}}};
        _ ->
            {ok, Stream#{st => {_LS, closed}}}
    end;

stream_handle({gun_data, _GunPid, StreamRef, IsFin, Data},
              Stream = #{st := {_LS, open},
                         handlers := Handlers,
                         recvbuff := Acc,
                         encoding := Encoding}) ->
    NData = <<Acc/binary, Data/binary>>,
    {Rest, Frames} = grpc_frame:split(NData, Encoding),
    case Frames /= [] andalso maps:get(incoming, Handlers, undefined) of
        false -> ok;
        undefined -> ok;
        Cbfun ->
            eval_stream_callback([StreamRef, Frames], Cbfun)
    end,
    case IsFin of
        nofin ->
            {ok, Stream#{recvbuff => Rest}};
        fin ->
            case maps:get(closed, Handlers, undefined) of
                undefined -> ok;
                Cbfun2 ->
                    eval_stream_callback([StreamRef, []], Cbfun2)
            end,
            {shutdown, normal, Stream#{st => {_LS, closed}}}
    end;

stream_handle({gun_error, _GunPid, _StreamRef, Reason}, Stream) ->
    {shutdown, Reason, Stream};

stream_handle(Info, Stream) ->
    ?LOG(error, "Unexecpted stream event: ~p, stream ~0p", [Info, Stream]).

%%--------------------------------------------------------------------
%% Internal funcs
%%--------------------------------------------------------------------

eval_stream_callback(Args0, {Fun, Args1}) ->
    erlang:apply(Fun, Args0 ++ Args1).

do_connect(State = #state{server = {_, Host, Port}, gun_opts = GunOpts}) ->
    case gun:open(Host, Port, GunOpts) of
        {ok, Pid} ->
            case gun:await_up(Pid) of
                {ok, _Protocol} ->
                    MRef = monitor(process, Pid),
                    State#state{mref = MRef, gun_pid = Pid};
                {error, Reason} ->
                    gun:close(Pid),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% Helpers

call(ChannPid, Msg) ->
    call(ChannPid, Msg, ?UNARY_TIMEOUT).

call(ChannPid, Msg, Timeout) ->
    gen_server:call(ChannPid, Msg, Timeout).

pick(ChannName) ->
    gproc_pool:pick_worker(ChannName, self()).

ms2timeout(Ms) when Ms > 1000 ->
    io_lib:format("~wS", [Ms div 1000]);
ms2timeout(Ms) ->
    io_lib:format("~wm", [Ms]).
