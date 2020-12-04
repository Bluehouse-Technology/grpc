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
       %, stream/1
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

-record(state, {pool, id, gun_pid, mref, encoding, server, requests, gun_opts}).

-type request() :: map().

-type response() :: map().

-type encoding() :: identity | gzip | deflate | snappy.

-type options() ::
        #{ channel => term()
         , encoding => encoding()
         , atom => term()
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

-define(headers(Encoding, MessageType, MD),
        [{<<"grpc-encoding">>, Encoding},
         {<<"grpc-message-type">>, MessageType},
         {<<"content-type">>, <<"application/grpc+proto">>},
         {<<"user-agent">>, <<"grpc-erlang/0.1.0">>},
         {<<"te">>, <<"trailers">>} | MD]).

-define(DEFAULT_GUN_OPTS,
        #{protocols => [http2],
          connect_timeout => 5000,
          http2_opts => #{keepalive => 60000}
         }).

-define(UNARY_TIMEOUT, 5000).

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

-spec start_link(term(), pos_integer(), server(), grpc_opts())
    -> {ok, pid()} | ignore | {error, term()}.
start_link(Pool, Id, Server, Opts) when is_map(Opts)  ->
    gen_server:start_link(?MODULE, [Pool, Id, Server, Opts], []).

-spec unary(def(), request(), grpc:metadata(), options())
    -> {ok, response(), grpc:metadata()}
     | {error, {grpc_error, grpc_status(), grpc_message()}}
     | {error, term()}.
%% @doc Unary function call
unary(Def = #{marshal := Marshal,
              unmarshal := Unmarshal}, Input, Metadata, Options)
  when is_map(Input),
       is_map(Metadata) ->
    case maps:get(channel, Options, undefined) of
        undefined ->
            {error, miss_channel_option};
        ChannName ->
            ChannName = maps:get(channel, Options),
            Timeout = maps:get(timeout, Options, ?UNARY_TIMEOUT),
            Bytes = Marshal(Input),
            case call(pick(ChannName),
                      {unary, Def, Bytes, maps:to_list(Metadata), Options},
                      Timeout + 1000) of
                {ok, Output, ReplyMetadata} ->
                    {ok, Unmarshal(Output), ReplyMetadata};
                {error, Reason} ->
                    {error, Reason}
            end
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
            requests = #{},
            gun_opts = NGunOpts}}.

handle_call(Req = {unary, _, _, _, _}, From, State = #state{gun_pid = undefined}) ->
    case do_connect(State) of
        {error, Reason} ->
            {reply, {error, Reason}, State};
        NState ->
            handle_call(Req, From, NState)
    end;

handle_call({unary, #{path := Path,
                      message_type := MessageType}, Bytes, Metadata, Options},
            From,
            State = #state{gun_pid = GunPid, requests = Requests, encoding = Encoding}) ->
    Headers = ?headers(atom_to_binary(Encoding, utf8), MessageType, Metadata),
    Body = grpc_frame:encode(Encoding, Bytes),
    StreamRef = gun:post(GunPid, Path, Headers, Body),
    EndingTs = erlang:system_time(millisecond) + maps:get(timeout, Options, ?UNARY_TIMEOUT),
    NState = State#state{requests = Requests#{StreamRef => {From, EndingTs, <<>>}}},
    {noreply, NState};

handle_call(_Request, _From, State) ->
    {reply, {error, unkown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({gun_data, GunPid, StreamRef, IsFin, Data},
            State = #state{encoding = Encoding, requests = Requests}) ->
    NowTs = erlang:system_time(millisecond),
    case maps:get(StreamRef, Requests, undefined) of
        {_, EndingTs, _} when NowTs > EndingTs ->
            _ = gun:cancel(GunPid, StreamRef),
            flush_stream(GunPid, StreamRef),
            NRequests = maps:remove(StreamRef, Requests),
            {noreply, State#state{requests = NRequests}};
        {From, EndingTs, Acc} ->
            NData = <<Acc/binary, Data/binary>>,
            case IsFin of
                nofin ->
                    NRequests = Requests#{StreamRef => {From, EndingTs, NData}},
                    {noreply, State#state{requests = NRequests}};
                fin ->
                    {<<>>, [FrameBin]} = grpc_frame:split(NData, Encoding),
                    gen_server:reply(From, {ok, FrameBin, []}),
                    NRequests = maps:remove(StreamRef, Requests),
                    {noreply, State#state{requests = NRequests}}
            end;
        _ ->
            logger:error("gun_data Unknown stream ref: ~p~n", [StreamRef]),
            {noreply, State}
    end;

handle_info({gun_trailers, GunPid, StreamRef, Trailers},
            State = #state{encoding = Encoding, requests = Requests}) ->
    NowTs = erlang:system_time(millisecond),
    case maps:get(StreamRef, Requests, undefined) of
        {_, EndingTs, _} when NowTs > EndingTs ->
            _ = gun:cancel(GunPid, StreamRef),
            flush_stream(GunPid, StreamRef),
            NRequests = maps:remove(StreamRef, Requests),
            {noreply, State#state{requests = NRequests}};
        {From, _EndingTs, Acc} ->
            GrpcStatus = proplists:get_value(<<"grpc-status">>, Trailers),
            GrpcMessags = proplists:get_value(<<"grpc-message">>, Trailers, <<>>),
            case GrpcStatus of
                ?GRPC_STATUS_OK ->
                    {<<>>, [FrameBin]} = grpc_frame:split(Acc, Encoding),
                    gen_server:reply(From, {ok, FrameBin, Trailers});
                _ ->
                    gen_server:reply(From, {error, {grpc_error, GrpcStatus, GrpcMessags}})
            end,
            NRequests = maps:remove(StreamRef, Requests),
            {noreply, State#state{requests = NRequests}};
        _ ->
            logger:error("gun_trailers Unknown stream ref: ~p~n", [StreamRef]),
            {noreply, State}
    end;

handle_info({gun_response, _GunPid, _StreamRef, _IsFin, _Status, _Headers}, State) ->
    {noreply, State};

handle_info({gun_error, _GunPid, StreamRef, Reason},
            State = #state{requests = Requests}) ->
    NowTs = erlang:system_time(millisecond),
    case maps:get(StreamRef, Requests, undefined) of
        {_, EndingTs, _} when NowTs > EndingTs ->
            NRequests = maps:remove(StreamRef, Requests),
            {noreply, State#state{requests = NRequests}};
        {From, _, _} ->
            gen_server:reply(From, {error, Reason}),
            NRequests = maps:remove(StreamRef, Requests),
            {noreply, State#state{requests = NRequests}};
        _ ->
            logger:error("gun_error Unknown stream ref: ~p~n", [StreamRef]),
            {noreply, State}
    end;

handle_info({gun_up, GunPid, http2}, State = #state{gun_pid = GunPid}) ->
    {noreply, State};

handle_info({gun_down, GunPid, http2, Reason, KilledStreams, _}, State = #state{gun_pid = GunPid, requests = Requests}) ->
    NowTs = erlang:system_time(millisecond),
    NRequests = lists:foldl(fun(StreamRef, Acc) ->
                                case maps:take(StreamRef, Acc) of
                                    error -> Acc;
                                    {{_, EndingTs, _}, NAcc} when NowTs > EndingTs ->
                                        NAcc;
                                    {{From, _, _}, NAcc} ->
                                        gen_server:reply(From, {error, Reason}),
                                        NAcc
                                end
                            end, Requests, KilledStreams),
    {noreply, State#state{requests = NRequests}};

handle_info({'DOWN', MRef, process, GunPid, Reason},
            State = #state{mref = MRef, gun_pid = GunPid, requests = Requests}) ->
    logger:warning("Gun process ~p down, reason: ~p~n", [GunPid, Reason]),
    NowTs = erlang:system_time(millisecond),
    lists:foreach(fun({_, {_, EndingTs, _}}) when NowTs > EndingTs ->
                      ok;
                     ({_, {From, _, _}}) ->
                      gen_server:reply(From, {error, Reason})
                  end, maps:to_list(Requests)),
    {noreply, State#state{gun_pid = undefined, requests = #{}}};

handle_info(Info, State) ->
    logger:warning("Unexpected info: ~p~n", [Info]),
    {noreply, State}.

terminate(_Reason, #state{pool = Pool, id = Id}) ->
    gproc_pool:disconnect_worker(Pool, {Pool, Id}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

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

-compile({inline, [call/3, pick/1]}).

call(ChannPid, Msg, Timeout) ->
    gen_server:call(ChannPid, Msg, Timeout).

pick(ChannName) ->
    gproc_pool:pick_worker(ChannName, self()).

flush_stream(GunPid, StreamRef) ->
    receive
        {gun_response, GunPid, StreamRef, _, _, _} ->
            flush_stream(GunPid, StreamRef);
        {gun_data, GunPid, StreamRef, _, _} ->
            flush_stream(GunPid, StreamRef);
        {gun_trailers, GunPid, StreamRef, _} ->
			flush_stream(GunPid, StreamRef);
        {gun_error, GunPid, StreamRef, _} ->
            flush_stream(GunPid, StreamRef)
	after 0 ->
		ok
	end.