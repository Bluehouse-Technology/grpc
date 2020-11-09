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

-record(state, {pool, id, gun_pid, encoding, server, requests, gun_opts}).

-define(headers(Encoding, MessageType, MD),
        [{<<"grpc-encoding">>, Encoding},
         {<<"grpc-message-type">>, MessageType},
         {<<"content-type">>, <<"application/grpc+proto">>},
         {<<"user-agent">>, <<"grpc-erlang/0.1.0">>},
         {<<"te">>, <<"trailers">>} | MD]).

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

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

-spec start_link(term(), pos_integer(), server(), grpc_opts())
    -> {ok, pid()} | ignore | {error, term()}.
start_link(Pool, Id, Server, Opts) when is_map(Opts)  ->
    gen_server:start_link(?MODULE, [Pool, Id, Server, Opts], []).

-spec unary(def(), request(), grpc:metadata(), options())
    -> {ok, response(), grpc:metadata()}
     | {error, term()}.
%% @doc Unary function call
unary(Def = #{marshal := Marshal}, Input, Metadata, Options)
  when is_map(Input),
       is_map(Metadata) ->
    ChannName = maps:get(channel, Options),
    Bytes = Marshal(Input),
    call(pick(ChannName), {unary, Def, Bytes, maps:to_list(Metadata), Options}).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([Pool, Id, Server = {_, _, _}, Opts]) ->
    Encoding = maps:get(encoding, Opts, identity),
    GunOpts = maps:get(gun_opts, Opts, #{}),
    NGunOpts = maps:merge(#{protocols => [http2],
                            connect_timeout => 5000,
                            http2_opts => #{keepalive => 60000}
                           }, GunOpts),

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
    handle_call(Req, From, do_connect(State));

handle_call({unary, #{path := Path,
                      message_type := MessageType,
                      unmarshal := Unmarshal}, Bytes, Metadata, _Options},
            From,
            State = #state{gun_pid = GunPid, requests = Requests, encoding = Encoding}) ->
    Headers = ?headers(atom_to_binary(Encoding, utf8), MessageType, Metadata),
    Body = grpc_frame:encode(Encoding, Bytes),
    StreamRef = gun:post(GunPid, Path, Headers, Body),
    NState = State#state{requests = Requests#{StreamRef => {From, Unmarshal, <<>>}}},
    {noreply, NState};

handle_call(_Request, _From, State) ->
    {reply, {error, unkown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({gun_data, _GunPid, StreamRef, IsFin, Data},
            State = #state{encoding = Encoding, requests = Requests}) ->
    case maps:get(StreamRef, Requests, undefined) of
        {From, Unmarshal, Acc} ->
            NData = <<Acc/binary, Data/binary>>,
            case IsFin of
                nofin ->
                    NRequests = Requests#{StreamRef => {From, Unmarshal, NData}},
                    {noreply, State#state{requests = NRequests}};
                fin ->
                    %% Reply
                    {<<>>, [FrameBin]} = grpc_frame:split(NData, Encoding),
                    gen_server:reply(From, {ok, Unmarshal(FrameBin), []}),
                    NRequests = maps:remove(StreamRef, Requests),
                    {noreply, State#state{requests = NRequests}}
            end;
        _ ->
            logger:error("gun_data Unknown stream ref: ~p~n", [StreamRef]),
            {noreply, State}
    end;

handle_info({gun_trailers, _GunPid, StreamRef, Trailers},
            State = #state{encoding = Encoding, requests = Requests}) ->
    case maps:get(StreamRef, Requests, undefined) of
        {From, Unmarshal, Acc} ->
            {<<>>, [FrameBin]} = grpc_frame:split(Acc, Encoding),
            gen_server:reply(From, {ok, Unmarshal(FrameBin), Trailers}),
            NRequests = maps:remove(StreamRef, Requests),
            {noreply, State#state{requests = NRequests}};
        _Oth ->
            logger:error("gun_trailers Unknown stream ref: ~p, ~p~n", [StreamRef, _Oth]),
            {noreply, State}
    end;

handle_info({gun_response, _GunPid, _StreamRef, _IsFin, _Status, _Headers}, State) ->
    {noreply, State};

handle_info({gun_error, _GunPid, StreamRef, Reason},
            State = #state{requests = Requests}) ->
    case maps:get(StreamRef, Requests, undefined) of
        {From, _, _, _} ->
            gen_server:reply(From, {error, Reason}),
            NRequests = maps:remove(StreamRef, Requests),
            {noreply, State#state{requests = NRequests}};
        _ ->
            logger:error("gun_error Unknown stream ref: ~p~n", [StreamRef]),
            {noreply, State}
    end;

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

do_connect(State = #state{gun_pid = GunPid})
  when is_pid(GunPid) ->
    State;
do_connect(State = #state{server = {_, Host, Port}, gun_opts = GunOpts}) ->
    case gun:open(Host, Port, GunOpts) of
        {ok, Pid} ->
            {ok, _} = gun:await_up(Pid),
            State#state{gun_pid = Pid};
        {error, Reason} ->
            {error, Reason}
    end.

-compile({inline, [call/2, pick/1]}).

call(ChannPid, Msg) ->
    %io:format(standard_error, "~p~n", [proplists:get_value(message_queue_len, process_info(self()))]),
    gen_server:call(ChannPid, Msg, infinity).

pick(ChannName) ->
    gproc_pool:pick_worker(ChannName, self()).
