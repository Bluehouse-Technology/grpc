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
          encoding :: grpc_frame:encoding(),
          %% Streams
          streams :: #{reference() := stream()},
          %% Initial gun options
          gun_opts :: gun:opts()
         }).

-type request() :: map().

-type response() :: map().

-type eos_msg() :: {eos, list()}.

-type options() ::
        #{ channel => term()
         , encoding => grpc_frame:encoding()
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

-type client_opts() ::
        #{ encoding => grpc_frame:encoding()
         , gun_opts => gun:opts()
         }.

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

-define(DEFAULT_TIMEOUT, 5000).

-define(STREAM_RESERVED_TIMEOUT, 15000).

-type stream_state() :: idle | open | closed.

-type stream() :: #{ st       := {LocalState :: stream_state(),
                                  RemoteState :: stream_state()}
                   , mqueue   := list()
                   , hangs    := list()
                   , recvbuff := binary()
                   , encoding := grpc_frame:encoding()
                   }.

-type client_pid() :: pid().

-type grpcstream() :: #{ client_pid := client_pid()
                       , stream_ref := reference()
                       , def := def()
                       }.

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
     | {error, term()}.
%% @doc Unary function call
unary(Def, Req, Metadata, Options) ->
    Timeout = maps:get(timeout, Options, ?DEFAULT_TIMEOUT),
    case open(Def, Metadata, Options) of
        {ok, GStream} ->
            _ = send(GStream, Req, fin),
            case recv(GStream, Timeout) of
                %% XXX: ?? Recv a error trailers ??
                {ok, [Resp]} when is_map(Resp) ->
                    {ok, [{eos, Trailers}]} = recv(GStream, Timeout),
                    {ok, Resp, Trailers};
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
    ClientPid = pick(maps:get(channel, Options, undefined)),
    case call(ClientPid, {open, Def, Metadata, Options}) of
        {ok, StreamRef} ->
            {ok, #{stream_ref => StreamRef, client_pid => ClientPid, def => Def}};
        {error, _} = Error -> Error
    end.

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
    case call(ClientPid, {send, StreamRef, Bytes, IsFin}) of
        ok -> ok;
        {error, R} -> error(R)
    end.

-spec recv(grpcstream())
    -> {ok, [response() | eos_msg()]}
     | {error, term()}.
recv(GStream) ->
    recv(GStream, ?DEFAULT_TIMEOUT).

-spec recv(grpcstream(), timeout())
    -> {ok, [response() | eos_msg()]}
     | {error, term()}.
recv(#{def        := Def,
       client_pid := ClientPid,
       stream_ref := StreamRef}, Timeout) ->
    Unmarshal = maps:get(unmarshal, Def),
    Endts = erlang:system_time(millisecond) + Timeout,
    case call(ClientPid, {read, StreamRef, Endts}) of
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

init([Pool, Id, Server = {_, _, _}, Opts]) ->
    Encoding = maps:get(encoding, Opts, identity),
    GunOpts = maps:get(gun_opts, Opts, #{}),
    NGunOpts = maps:merge(?DEFAULT_GUN_OPTS, GunOpts),
    true = gproc_pool:connect_worker(Pool, {Pool, Id}),
    {ok, ensure_clean_timer(
           #state{
              pool = Pool,
              id = Id,
              gun_pid = undefined,
              server = Server,
              encoding = Encoding,
              streams = #{},
              gun_opts = NGunOpts})}.

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
    Timeout = maps:get(timeout, Options, ?DEFAULT_TIMEOUT),
    Headers = ?headers(atom_to_binary(Encoding, utf8), MessageType, Timeout, Metadata),
    StreamRef = gun:post(GunPid, Path, Headers),
    Stream = #{st       => {open, idle},
               mqueue   => [],
               hangs    => [],
               recvbuff => <<>>,
               encoding => Encoding
              },
    NState = State#state{streams = Streams#{StreamRef => Stream}},
    {reply, {ok, StreamRef}, NState};

handle_call(_Req = {send, StreamRef, Bytes, IsFin},
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
            case maps:get(StreamRef, Streams, undefined) of
                undefined ->
                    ?LOG(warning, "[gRPC Client] Unknown stream ref: ~0p, event: ~0p", [StreamRef, Info]),
                    {noreply, State};
                Stream ->
                    handle_stream_handle_result(
                      stream_handle(Info, Stream),
                      StreamRef,
                      Streams,
                      State)
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
              Stream = #{st := {closed, closed}, mqueue := MQueue}) ->
    {shutdown, normal, [{reply, From, {ok, MQueue}}], Stream#{mqueue => []}};

%% gun msgs

stream_handle({gun_response, _GunPid, _StreamRef, nofin, _Status, _Headers},
              Stream = #{st := {_LS, idle}}) ->
    %% TODO: error handling?
    {ok, Stream#{st => {_LS, open}}};

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

ensure_clean_timer(State = #state{tref = undefined}) ->
    TRef = erlang:start_timer(?STREAM_RESERVED_TIMEOUT,
                              self(),
                              clean_stopped_stream),
    State#state{tref = TRef}.

format_stream(#{st := St, recvbuff := Buff, mqueue := MQueue}) ->
    io_lib:format("#stream{st=~p, buff_size=~w, mqueue=~p}",
                  [St, byte_size(Buff), MQueue]).

call(ChannPid, Msg) ->
    call(ChannPid, Msg, ?DEFAULT_TIMEOUT).

call(ChannPid, Msg, Timeout) ->
    gen_server:call(ChannPid, Msg, Timeout).

pick(ChannName) ->
    gproc_pool:pick_worker(ChannName, self()).

ms2timeout(Ms) when Ms > 1000 ->
    io_lib:format("~wS", [Ms div 1000]);
ms2timeout(Ms) ->
    io_lib:format("~wm", [Ms]).
