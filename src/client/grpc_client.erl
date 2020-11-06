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

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

-type encoding() :: none | gzip | deflate | snappy | atom().

-type options() :: #{ channel => term()
                    , encoding => encoding()
                    }.

-type def() :: #{ service := atom()
                , message_type := atom()
                , marshal := function()
                , unmarshal := function()
                }.

-spec unary(binary(), any(), def(), options()) ->
    {ok, Response :: any(), Metadata :: any()}.
unary(Path, Input, Def, Option) ->
    ChannName = maps:get(channel, Option),
    call(pick(ChannName), {unary, Path, Input, Def}).

start_link(Pool, Id, Server, Opts) when is_map(Opts)  ->
    gen_server:start_link(?MODULE, [Pool, Id, Server, Opts], []).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

-type grpc_opts() :: #{encoding => encoding(),
                       gun_opts => gun:opts()}.

init([Pool, Id, Server = {Scheme, Host, Port}, Opts]) ->
    Encoding = maps:get(encoding, Opts, none),
    GunOpts = maps:get(gun_opts, Opts, #{}),
    case gun:open(Host, Port, GunOpts#{protocols => [http2]}) of
        {ok, Pid} ->
            {ok, _} = gun:await_up(Pid),
            true = gproc_pool:connect_worker(Pool, {Pool, Id}),
            {ok, #state{
                    pool = Pool,
                    id = Id,
                    gun_pid = Pid,
                    server = Server,
                    encoding = Encoding,
                    requests = #{},
                    gun_opts = GunOpts}};
        {error, Reason} ->
            {error, Reason}
    end.

handle_call({unary, Path, Input, Def = #{message_type := MessageType,
                                         marshal := Marshal,
                                         unmarshal := Unmarshal}}, From,
            State = #state{gun_pid = GunPid, requests = Requests, encoding = Encoding}) ->
    Metadata = [], %% FIXME:
    Headers = ?headers(atom_to_binary(Encoding, utf8), MessageType, Metadata),
    Body = grpc_frame:encode(Encoding, Marshal(Input)),
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

terminate(_Reason, State = #state{pool = Pool, id = Id}) ->
    gproc_pool:disconnect_worker(Pool, {Pool, Id}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal funcs
%%--------------------------------------------------------------------

-compile({inline, [call/2, pick/1]}).

call(ChannPid, Msg) ->
    %io:format(standard_error, "~p~n", [proplists:get_value(message_queue_len, process_info(self()))]),
    gen_server:call(ChannPid, Msg, infinity).

pick(ChannName) ->
    gproc_pool:pick_worker(ChannName, self()).
