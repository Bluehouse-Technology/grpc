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
-export([unary/4]).

-export([ open/3
        , send/2
        , send/3
        , recv/1
        , recv/2
        ]).

-export([start_link/4]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

-record(state, {
          %% Pool name
          pool,
          %% The worker id in the pool
          id,
          %% Server address
          server :: server(),
          %% Gun connection pid
          gun_pid :: undefined | pid(),
          %% The Monitor referebce for gun connection pid
          mref :: undefined | reference(),
          %% Clean timer reference
          tref :: undefined | reference(),
          %% Encoding for gRPC packets
          %% XXX: Bad impl.
          encoding :: grpc_frame:encoding(),
          %% Streams
          streams :: #{reference() := stream()},
          %% Client options
          client_opts :: client_opts(),
          %% Flush timer reference
          flush_timer_ref :: undefined | reference()
         }).

-type request() :: map().

-type response() :: map().

-type eos_msg() :: {eos, list()}.

-type options() ::
        #{ channel => term()
         %% The grpc-encoding method
         %% Default is identity
         , encoding => grpc_frame:encoding()
         %% The timeout to receive the response of request. The clock starts
         %% ticking when the request is sent
         %%
         %% Time is in milliseconds
         %%
         %% Default is infinity
         , timeout => non_neg_integer()
         %% Connection time-out time, used during the initial request,
         %% when the client is connecting to the server
         %%
         %% Time is in milliseconds
         %%
         %% Default equal to timeout option
         , connect_timeout => non_neg_integer()
         }.

-type def() ::
        #{ path := binary()
         , service := atom()
         , message_type := binary()
         , marshal := function()
         , unmarshal := function()
         }.

-type server() :: {http | https, string(), inet:port_number()}.

-type client_opts() ::
        #{ encoding => grpc_frame:encoding()
         , gun_opts => gun:opts()
         , stream_batch_size => non_neg_integer()
         , stream_batch_delay_ms => non_neg_integer()
         }.

-define(DEFAULT_GUN_OPTS,
        #{protocols => [http2],
          connect_timeout => 5000,
          http2_opts => #{keepalive => 60000},
          transport_opts => [{nodelay, true}]
         }).

-define(STREAM_RESERVED_TIMEOUT, 15000).

-define(DEFAULT_STREAMING_DELAY, 20).
-define(DEFAULT_STREAMING_BATCH_SIZE, 16384).

-type stream_state() :: idle | open | closed.

-type stream() :: #{ st       := {LocalState :: stream_state(),
                                  RemoteState :: stream_state()}
                   , mqueue   := list()
                   , hangs    := list()
                   , recvbuff := binary()
                   , sendbuff := iolist()
                   , sendbuff_size := non_neg_integer()
                   , sendbuff_last_flush_ts := non_neg_integer()
                   , encoding := grpc_frame:encoding()
                   }.

-type client_pid() :: pid().

-type grpcstream() :: #{ client_pid := client_pid()
                       , stream_ref := reference()
                       , def := def()
                       }.

-dialyzer({nowarn_function, [have_buffered_bytes/1]}).

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

-spec start_link(term(), pos_integer(), server(), client_opts())
    -> {ok, pid()} | ignore | {error, term()}.
start_link(Pool, Id, Server, Opts) when is_map(Opts)  ->
    gen_server:start_link(?MODULE, [Pool, Id, Server, Opts], []).

%%--------------------------------------------------------------------
%% gRPC APIs

-spec unary(def(), request(), grpc:metadata(), options())
    -> {ok, response(), grpc:metadata()}
     | {error, {grpc_status_name(), grpc_message()}}
     | {error, term()}.
%% @doc Unary function call
unary(Def, Req, Metadata, Options) ->
    Timeout = maps:get(timeout, Options, infinity),
    case open(Def, Metadata, Options) of
        {ok, GStream} ->
            _ = send(GStream, Req, fin),
            case recv(GStream, Timeout) of
                {ok, [Resp]} when is_map(Resp) ->
                    {ok, [{eos, Trailers}]} = recv(GStream, Timeout),
                    {ok, Resp, Trailers};
                {ok, [{eos, Trailers}]} ->
                    %% Not data responed, only error trailers
                    {error, trailers_to_error(Trailers)};
                {ok, [Resp, Trailers]} ->
                    {ok, Resp, Trailers};
                {error, _} = E -> E
            end;
        E -> E
    end.

-spec open(def(), grpc:metadata(), options())
    -> {ok, grpcstream()}
     | {error, term()}.

open(Def, Metadata, Options) ->
    ClientPid = pick(
                  maps:get(channel, Options, undefined),
                  maps:get(key_dispatch, Options, self())
                 ),
    case call(ClientPid, {open, Def, Metadata, Options}, connect_timeout(Options)) of
        {ok, StreamRef} ->
            {ok, #{stream_ref => StreamRef, client_pid => ClientPid, def => Def}};
        {error, _} = Error -> Error
    end.

connect_timeout(Options) ->
    maps:get(
      connect_timeout,
      Options,
      maps:get(timeout, Options, infinity)
     ).

-spec send(grpcstream(), request()) -> ok.
send(GStream, Req) ->
    send(GStream, Req, nofin).

send(_GStream = #{
             def        := Def,
             client_pid := ClientPid,
             stream_ref := StreamRef
          }, Req, IsFin) ->
    #{marshal := Marshal} = Def,
    Bytes = Marshal(Req),
    case call(ClientPid, {send, StreamRef, Bytes, IsFin}, infinity) of
        ok -> ok;
        {error, R} -> error(R)
    end.

-spec recv(grpcstream())
    -> {ok, [response() | eos_msg()]}
     | {error, term()}.
recv(GStream) ->
    recv(GStream, infinity).

-spec recv(grpcstream(), timeout())
    -> {ok, [response() | eos_msg()]}
     | {error, term()}.
recv(#{def        := Def,
       client_pid := ClientPid,
       stream_ref := StreamRef}, Timeout) ->
    Unmarshal = maps:get(unmarshal, Def),
    Endts = case Timeout of
                infinity -> infinity;
                _ -> erlang:system_time(millisecond) + Timeout
            end,
    case call(ClientPid, {read, StreamRef, Endts}, Timeout) of
        {error, _} = E -> E;
        {IsMore, Frames} ->
            Msgs = lists:map(fun({eos, Trailers}) -> {eos, Trailers};
                         (Bin) -> Unmarshal(Bin)
                   end, Frames),
            {IsMore, Msgs}
    end.

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([Pool, Id, Server = {_, _, _}, ClientOpts0]) ->
    Encoding = maps:get(encoding, ClientOpts0, identity),
    Opts = maps:put(
             gun_opts,
             maps:merge(?DEFAULT_GUN_OPTS, maps:get(gun_opts, ClientOpts0, #{})),
             ClientOpts0
            ),
    true = gproc_pool:connect_worker(Pool, {Pool, Id}),
    {ok, ensure_clean_timer(
           #state{
              pool = Pool,
              id = Id,
              gun_pid = undefined,
              server = Server,
              encoding = Encoding,
              streams = #{},
              client_opts = Opts})}.

handle_call(Req, From, State = #state{gun_pid = undefined}) ->
    case do_connect(State) of
        {error, Reason} ->
            {reply, {error, Reason}, State};
        NState ->
            handle_call(Req, From, NState)
    end;

handle_call({open, #{path := Path,
                     message_type := MessageType
                    }, Metadata, Options},
            _From,
            State = #state{gun_pid = GunPid, streams = Streams, encoding = Encoding}) ->
    Timeout = maps:get(timeout, Options, infinity),
    Headers = assemble_grpc_headers(atom_to_binary(Encoding, utf8),
                                    MessageType,
                                    Timeout,
                                    Metadata
                                   ),
    StreamRef = gun:post(GunPid, Path, Headers),
    Stream = #{st       => {open, idle},
               mqueue   => [],
               hangs    => [],
               recvbuff => <<>>,
               sendbuff => [],
               sendbuff_size => 0,
               sendbuff_last_flush_ts => 0,
               encoding => Encoding
              },
    NState = State#state{streams = Streams#{StreamRef => Stream}},
    {reply, {ok, StreamRef}, NState};

handle_call(_Req = {send, StreamRef, Bytes, IsFin},
            _From,
            State = #state{gun_pid = GunPid, streams = Streams, encoding = Encoding,
                           client_opts = ClientOpts}) ->
    case maps:get(StreamRef, Streams, undefined) of
        Stream = #{st := {open, _RS}} ->
            NBytes = grpc_frame:encode(Encoding, Bytes),
            BatchSize = maps:get(
                          stream_batch_size,
                          ClientOpts,
                          ?DEFAULT_STREAMING_BATCH_SIZE
                         ),
            NStream = maybe_send_data(NBytes, IsFin, StreamRef, Stream, GunPid, BatchSize),
            NStreams = maps:put(StreamRef, NStream, Streams),
            {reply, ok, ensure_flush_timer(State#state{streams = NStreams})};
        #{st := {closed, _RS}} ->
            {reply, {error, closed}, State};
        undefined ->
            {reply, {error, not_found}, State};
        _S ->
            {reply, {error, bad_stream}, State}
    end;

handle_call(_Req = {read, StreamRef, Endts},
            From,
            State = #state{streams = Streams}) ->
    case maps:get(StreamRef, Streams, undefined) of
        undefined ->
            {reply, {error, not_found}, State};
        Stream ->
            handle_stream_handle_result(
              stream_handle({read, From, StreamRef, Endts}, Stream),
              StreamRef,
              Streams,
              State)
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unkown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({timeout, TRef, clean_stopped_stream},
            State = #state{tref = TRef, streams = Streams}) ->
    Nowts = erlang:system_time(millisecond),
    NStreams = maps:filter(
                 fun(_, #{stopped := Stoppedts}) ->
                       Nowts < Stoppedts + ?STREAM_RESERVED_TIMEOUT;
                    (_, _) -> true
                 end, Streams),
    {noreply, ensure_clean_timer(State#state{streams = NStreams, tref = undefined})};

handle_info({timeout, TRef, flush_streams_sendbuff},
            State0 = #state{flush_timer_ref = TRef}) ->
    State = State0#state{flush_timer_ref = undefined},
    Nowts = erlang:system_time(millisecond),
    {noreply, ensure_flush_timer(flush_streams(Nowts, State))};

handle_info({gun_up, GunPid, http2}, State = #state{gun_pid = GunPid}) ->
    {noreply, State};

handle_info({gun_down, GunPid, http2, Reason, KilledStreamRefs, _},
            State = #state{gun_pid = GunPid, streams = Streams}) ->
    Nowts = erlang:system_time(millisecond),
    %% Reply killed streams error
    _ = maps:fold(fun(_, #{hangs := Hangs}, _Acc) ->
        lists:foreach(fun({From, Endts}) ->
            Endts > Nowts andalso
              gen_server:reply(From, {error, {connection_down, Reason}})
        end, Hangs)
    end, [], maps:with(KilledStreamRefs, Streams)),
    {noreply, State#state{streams = maps:without(KilledStreamRefs, Streams)}};

handle_info({'DOWN', MRef, process, GunPid, Reason},
            State = #state{mref = MRef, gun_pid = GunPid, streams = Streams}) ->
    Nowts = erlang:system_time(millisecond),
    _ = maps:fold(fun(_, #{hangs := Hangs}, _Acc) ->
        lists:foreach(fun({From, Endts}) ->
            Endts > Nowts andalso
              gen_server:reply(From, {error, {connection_down, Reason}})
        end, Hangs)
    end, [], Streams),
    {noreply, State#state{gun_pid = undefined, streams = #{}}};

handle_info(Info, State = #state{streams = Streams}) when is_tuple(Info) ->
    Ls = [gun_response, gun_trailers, gun_data, gun_error],
    case lists:member(element(1, Info), Ls) of
        true ->
            StreamRef = element(3, Info),
            case StreamRef of
                {stop, {goaway, StreamID, ErrCode, _AddData}, Reason} ->
                    %% Ignore the goaway message; the state of the stream
                    %% will be cleared in the gun_down event
                    ?LOG(debug, "[gRPC Client] Stream ~w goaway, "
                                "error_code: ~0p, details: ~0p",
                                [StreamID, ErrCode, Reason]),
                    {noreply, State};
                _ ->
                    case maps:get(StreamRef, Streams, undefined) of
                        undefined ->
                            ?LOG(warning, "[gRPC Client] Unknown stream ref: ~0p, "
                                          "event: ~0p", [StreamRef, Info]),
                            {noreply, State};
                        Stream ->
                            handle_stream_handle_result(
                              stream_handle(Info, Stream),
                              StreamRef,
                              Streams,
                              State)
                    end
            end;
        _ ->
            ?LOG(warning, "[gRPC Client] Unexpected info: ~p~n", [Info]),
            {noreply, State}
    end.

terminate(_Reason, #state{pool = Pool, id = Id}) ->
    gproc_pool:disconnect_worker(Pool, {Pool, Id}).

%% downgrade to Vsn
code_change({down, _Vsn},
            State = #state{
                       client_opts = ClientOpts,
                       flush_timer_ref = TRef
                      }, [Vsn]) ->
    NState =
        case re:run(Vsn, "0\\.6\\.[0-6]$", [{capture, none}]) of
            match ->
                GunOpts = maps:get(gun_opts, ClientOpts, ?DEFAULT_GUN_OPTS),
                _ = is_reference(TRef) andalso erlang:cancel_timer(TRef),
                %% flush all streams to avoid buffered data lost
                State1 = flush_streams(infinity, State),
                list_to_tuple(
                  lists:droplast(lists:droplast(tuple_to_list(State1)))
                  ++ [GunOpts]
                 );
            _ -> State
        end,
    {ok, NState};
%% upgrade from Vsn
code_change(_Vsn,
            {state,
             Pool, Id, Server, GunPid, MRef,
             TRef, Encoding, Streams, GunOpts}, [Vsn]) ->
    NState =
        case re:run(Vsn, "0\\.6\\.[0-6]$", [{capture, none}]) of
            match ->
                ClientOpts = #{encoding => Encoding,
                               gun_opts => GunOpts},
                NStreams = maps:map(
                             fun(_, Stream) ->
                                Stream#{
                                  sendbuff => [],
                                  sendbuff_size => 0,
                                  sendbuff_last_flush_ts => 0
                                 }
                             end, Streams),
                {state, Pool, Id, Server, GunPid, MRef,
                 TRef, Encoding, NStreams, ClientOpts, undefined};
            _ -> error({bad_vsn_in_code_change, Vsn})
        end,
    {ok, NState}.

%%--------------------------------------------------------------------
%% Handle stream handle

handle_stream_handle_result(ok, _StreamRef, Streams, State) ->
    {noreply, State#state{streams = Streams}};
handle_stream_handle_result({ok, Stream}, StreamRef, Streams, State) ->
    {noreply, State#state{streams = Streams#{StreamRef => Stream}}};
handle_stream_handle_result({ok, Events, Stream}, StreamRef, Streams, State) ->
    _ = run_events(Events),
    {noreply, State#state{streams = Streams#{StreamRef => Stream}}};
handle_stream_handle_result({shutdown, _Reason, _Stream}, StreamRef, Streams, State) ->
    _Reason /= normal andalso
        ?LOG(error, "[gRPC Client] Stream shutdown reason: ~p, stream: ~s",
             [_Reason, format_stream(_Stream)]),
    {noreply, State#state{streams = maps:remove(StreamRef, Streams)}};
handle_stream_handle_result({shutdown, _Reason, Events, _Stream}, StreamRef, Streams, State) ->
    _Reason /= normal andalso
        ?LOG(error, "[gRPC Client] Stream shutdown reason: ~p, stream: ~s",
             [_Reason, format_stream(_Stream)]),
    _ = run_events(Events),
    {noreply, State#state{streams = maps:remove(StreamRef, Streams)}}.

run_events([]) ->
    ok;
run_events([{reply, From, Msg}|Es]) ->
    gen_server:reply(From, Msg),
    run_events(Es).

%%--------------------------------------------------------------------
%% Streams handle
%%--------------------------------------------------------------------

%% api calls

stream_handle({read, From, _StreamRef, EndTs},
             Stream = #{mqueue := [], hangs := Hangs}) ->
    {ok, Stream#{hangs => [{From, EndTs}|Hangs]}};

stream_handle({read, From, _StreamRef, _EndTs},
              Stream = #{st := {_LS, open}, mqueue := MQueue}) when MQueue /= [] ->
    {ok, [{reply, From, {ok, MQueue}}], Stream#{mqueue => []}};

stream_handle({read, From, _StreamRef, _EndTs},
    Stream = #{st := {_LS, closed}, mqueue := MQueue}) when MQueue /= [] ->
    {shutdown, normal, [{reply, From, {ok, MQueue}}], Stream#{mqueue => []}};

stream_handle({read, From, _StreamRef, _EndTs},
              Stream = #{st := {closed, closed}, mqueue := MQueue}) ->
    {shutdown, normal, [{reply, From, {ok, MQueue}}], Stream#{mqueue => []}};

%% gun msgs

stream_handle({gun_response, _GunPid, _StreamRef, IsFin, _Status, Headers},
              Stream = #{st := {_LS, idle}}) ->
    case IsFin of
        nofin ->
            {ok, Stream#{st => {_LS, open}}};
        fin ->
            handle_remote_closed(Headers, Stream)
    end;

stream_handle({gun_trailers, _GunPid, _StreamRef, Trailers},
              Stream = #{st := {_LS, open}}) ->
    handle_remote_closed(Trailers, Stream);

stream_handle({gun_data, _GunPid, _StreamRef, nofin, Data},
              Stream = #{st := {_LS, open},
                         recvbuff := Acc,
                         encoding := Encoding}) ->
    NData = <<Acc/binary, Data/binary>>,
    case grpc_frame:split(NData, Encoding) of
        {Rest, []} ->
            {ok, Stream#{recvbuff => Rest}};
        {Rest, Frames} ->
            case clean_hangs(Stream#{recvbuff => Rest}) of
                NStream = #{hangs := [], mqueue := MQueue} ->
                    {ok, NStream#{mqueue => MQueue ++ Frames}};
                NStream = #{hangs := [{From, _}|NHangs], mqueue := MQueue} ->
                    {ok, [{reply, From, {ok, MQueue ++ Frames}}], NStream#{hangs => NHangs}}
            end
    end;

stream_handle({gun_data, _GunPid, _StreamRef, fin, Data},
               Stream = #{st := {_LS, open},
                         recvbuff := Acc,
                         encoding := Encoding}) ->
    NData = <<Acc/binary, Data/binary>>,
    case grpc_frame:split(NData, Encoding) of
        {<<>>, []} ->
            handle_remote_closed([], Stream);
        {<<>>, Frames} ->
            MQueue = maps:get(mqueue, Stream),
            handle_remote_closed([], Stream#{recvbuff => <<>>, mqueue => MQueue ++ Frames})
    end;


stream_handle({gun_error, _GunPid, _StreamRef, {stream_error, no_error, 'Stream reset by server.'}},
              Stream = #{st := {_LS, closed}, mqueue := MQueue}) when MQueue =/= [] ->
    {ok, Stream};
stream_handle({gun_error, _GunPid, _StreamRef, Reason}, Stream) ->
    {shutdown, Reason, Stream};

stream_handle(Info, Stream) ->
    ?LOG(error, "Unexecpted stream event: ~p, stream ~0p", [Info, Stream]).

handle_remote_closed(Trailers, Stream = #{st := {closed, _}}) ->
    case clean_hangs(Stream#{st => {closed, closed}}) of
        NStream = #{hangs := [{From, _}|NHangs], mqueue := MQueue} ->
            Events1 = [{reply, From, {ok, MQueue ++ [{eos, Trailers}]}}],
            Events2 = lists:map(fun({F, _}) -> {reply, F, {error, closed}} end, NHangs),
            {shutdown, normal, Events1 ++ Events2, NStream#{hangs => [], mqueue => []}};
        NStream = #{hangs := [], mqueue := MQueue} ->
            {ok, NStream#{mqueue => MQueue ++ [{eos, Trailers}],
                          stopped => erlang:system_time(millisecond)}}
    end;

handle_remote_closed(Trailers, Stream = #{st := {Ls, _}}) ->
    case clean_hangs(Stream#{st => {Ls, closed}}) of
        NStream = #{hangs := [{From, _}|NHangs], mqueue := MQueue} ->
            Events1 = [{reply, From, {ok, MQueue ++ [{eos, Trailers}]}}],
            Events2 = lists:map(fun({F, _}) -> {reply, F, {error, closed}} end, NHangs),
            {ok, Events1 ++ Events2, NStream#{hangs => [], mqueue => []}};
        NStream = #{hangs := [], mqueue := MQueue} ->
            {ok, NStream#{mqueue => MQueue ++ [{eos, Trailers}]}}
    end.

clean_hangs(Stream = #{hangs := []}) ->
    Stream;
clean_hangs(Stream = #{hangs := Hangs}) ->
    Nowts = erlang:system_time(millisecond),
    Hangs1 = lists:filter(fun({_, T}) -> T >= Nowts end, Hangs),
    Stream#{hangs => Hangs1}.

%%--------------------------------------------------------------------
%% Internal funcs
%%--------------------------------------------------------------------

do_connect(State = #state{server = {_, Host, Port}, client_opts = ClientOpts}) ->
    GunOpts = maps:get(gun_opts, ClientOpts, #{}),
    case gun:open(Host, Port, GunOpts) of
        {ok, Pid} ->
            case gun_await_up_helper(Pid) of
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

gun_await_up_helper(Pid) ->
    gun_await_up_helper(Pid, 50, undefined).
gun_await_up_helper(_Pid, 0, LastRet) ->
   LastRet ;
gun_await_up_helper(Pid, Retry, LastRet) ->
    case gun:await_up(Pid, 100) of
        {ok, _} = Ret ->
            Ret;
        {error, timeout} ->
            case gun_last_reason(Pid) of
                undefined ->
                    gun_await_up_helper(Pid, Retry-1, LastRet);
                Reason ->
                    {error, Reason}
            end;
        {error, _} = Ret ->
            Ret
    end.

gun_last_reason(Pid) ->
    %% XXX: Hard-coded to get detailed reason, because gun
    %% does not expose it with a function
    lists:last(
      tuple_to_list(
        element(2, sys:get_state(Pid)))
     ).

%%--------------------------------------------------------------------
%% Helpers

flush_streams(Nowts, State = #state{streams = Streams,
                                    gun_pid = GunPid,
                                    client_opts = ClientOpts}) ->
    Intv = maps:get(stream_batch_delay_ms, ClientOpts, ?DEFAULT_STREAMING_DELAY),
    NStreams =
        maps:map(
          fun(_, Stream = #{sendbuff_size := 0}) ->
                  Stream;
             (_, Stream = #{sendbuff_last_flush_ts := Ts})
               when Nowts < (Ts + Intv) ->
                  Stream;
             (StreamRef, Stream = #{sendbuff := IolistData,
                                    sendbuff_last_flush_ts := Ts})
               when Nowts >= (Ts + Intv) ->
                  ok = gun:data(GunPid, StreamRef, nofin, lists:reverse(IolistData)),
                  Stream#{sendbuff := [], sendbuff_size := 0, sendbuff_last_flush_ts := Nowts}
          end, Streams),
   State#state{streams = NStreams}.

maybe_send_data(Bytes, IsFin, StreamRef,
          Stream = #{st := {_, _RS},
                     sendbuff := IolistData0,
                     sendbuff_size := BufferSize0}, GunPid, BatchSize) ->
    IolistData = [Bytes | IolistData0],
    IolistSize = BufferSize0 + iolist_size(Bytes),
    case IsFin == fin orelse IolistSize >= BatchSize of
        true ->
            NData = lists:reverse(IolistData),
            ok = gun:data(GunPid, StreamRef, IsFin, NData),
            case IsFin of
                fin ->
                    Stream#{st := {closed, _RS},
                            sendbuff := [],
                            sendbuff_size := 0
                           };
                _ ->
                    Stream#{sendbuff := [],
                            sendbuff_size := 0
                           }
            end;
        false ->
            Stream#{sendbuff := IolistData, sendbuff_size := IolistSize}
    end.

trailers_to_error([]) ->
    stream_closed_without_any_response;
trailers_to_error(Trailers) ->
    {grpc_utils:codename(
       proplists:get_value(<<"grpc-status">>, Trailers, ?GRPC_STATUS_OK)
      ),
     proplists:get_value(<<"grpc-message">>, Trailers, <<>>)}.

ensure_clean_timer(State = #state{tref = undefined}) ->
    TRef = erlang:start_timer(?STREAM_RESERVED_TIMEOUT,
                              self(),
                              clean_stopped_stream),
    State#state{tref = TRef}.

ensure_flush_timer(State = #state{streams = Streams,
                                  flush_timer_ref = undefined,
                                  client_opts = ClientOpts
                                 }) ->
    case have_buffered_bytes(Streams) of
        true ->
            Intv = maps:get(stream_batch_delay_ms, ClientOpts, ?DEFAULT_STREAMING_DELAY),
            TRef = erlang:start_timer(Intv, self(), flush_streams_sendbuff),
            State#state{flush_timer_ref = TRef};
        _ ->
            State
    end;
ensure_flush_timer(State) ->
    State.

have_buffered_bytes(Streams) when is_map(Streams) ->
    have_buffered_bytes(maps:next(maps:iterator(Streams)));

have_buffered_bytes({_StreamRef, #{sendbuff_size := 0}, I}) ->
    have_buffered_bytes(maps:next(I));
have_buffered_bytes({_StreamRef, #{sendbuff_size := S}, _I}) when S > 0 ->
    true;
have_buffered_bytes({_StreamRef, #{sendbuff_size := S}, none}) ->
    S > 0;
have_buffered_bytes(none) ->
    false.

format_stream(#{st := St, recvbuff := Buff, mqueue := MQueue}) ->
    io_lib:format("#stream{st=~p, buff_size=~w, mqueue=~p}",
                  [St, byte_size(Buff), MQueue]).

%% copied from gen.erl and gen_server.erl
call(Process, Request, Timeout) ->
    Mref = erlang:monitor(process, Process),

    %% OTP-21:
    %% Auto-connect is asynchronous. But we still use 'noconnect' to make sure
    %% we send on the monitored connection, and not trigger a new auto-connect.
    %%
    erlang:send(Process, {'$gen_call', {self(), Mref}, Request}, [noconnect]),

    receive
        {Mref, Reply} ->
            erlang:demonitor(Mref, [flush]),
            Reply;
        {'DOWN', Mref, _, _, Reason} ->
            exit(Reason)
    after Timeout ->
              erlang:demonitor(Mref, [flush]),
              {error, {grpc_utils:codename(?GRPC_STATUS_DEADLINE_EXCEEDED),
                       <<"Waiting for response timeout">>}}
    end.

pick(ChannName, Key) ->
    gproc_pool:pick_worker(ChannName, Key).

assemble_grpc_headers(Encoding, MessageType, Timeout, MD) ->
    [{<<"content-type">>, <<"application/grpc+proto">>},
     {<<"user-agent">>, <<"grpc-erlang/0.1.0">>},
     {<<"grpc-encoding">>, Encoding},
     {<<"grpc-message-type">>, MessageType},
     {<<"te">>, <<"trailers">>}]
    ++ assemble_grpc_timeout_header(Timeout)
    ++ assemble_grpc_metadata_header(MD).

assemble_grpc_timeout_header(infinity) ->
    [];
assemble_grpc_timeout_header(Timeout) ->
    [{<<"grpc-timeout">>, ms2timeout(Timeout)}].

assemble_grpc_metadata_header(MD) ->
    maps:to_list(MD).

ms2timeout(Ms) when Ms > 1000 ->
    [integer_to_list(Ms div 1000), $S];
ms2timeout(Ms) ->
    [integer_to_list(Ms), $m].
