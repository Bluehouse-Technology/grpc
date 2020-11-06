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

-module(grpc).

%% APIs
-export([ start_server/3
        , start_server/4
        , stop_server/1
        ]).

-type listen_on() :: {inet:ip_address(), inet:port_number()}.
-type services() :: #{protos := [module()],
                      services := #{ServiceName :: atom() := HandlerModule :: module()}
                     }.

-type option() :: {ssl_options, ssl:server_option()}
                | {ranch_opts, ranch:opts()}
                | {cowboy_opts, cowboy_http2:opts()}.

-type metadata() :: map().

-export_type([metadata/0]).

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

-spec start_server(any(), listen_on(), services())
    -> ok | {error, term()}.
start_server(Name, ListenOn, Services) ->
    start_server(Name, ListenOn, Services, []).

-spec start_server(any(), listen_on(), services(), [option()])
    -> ok | {error, term()}.
%% @doc Start a gRPC server
start_server(Name, ListenOn, Services, Options) ->
    _ = application:ensure_all_started(grpc),

    UserOptions = #{services => compile_service_rules(Services)},
    start_http_server(Name, listen(ListenOn), Options, UserOptions).

%% @private
%% {ServicesName, FunName} => ServiceDefs
compile_service_rules(Services0) ->
    Protos = maps:get(protos, Services0, []),

    Defineds = lists:foldr(fun(Pb, Acc) ->
                   [{S, Pb} || S <- Pb:get_service_names()] ++ Acc
               end, [], Protos),
    Services = maps:get(services, Services0, #{}),
    maps:fold(fun(SvrName, Handler, Acc) ->
        case lists:keyfind(SvrName, 1, Defineds) of
            false -> Acc;
            {_, Pb} ->
                lists:foldl(fun(RpcName, Acc2) ->
                    RpcDef = Pb:find_rpc_def(SvrName, RpcName),
                    Acc2#{{SvrName, RpcName} => RpcDef#{pb => Pb,
                                                        handler => Handler}}
                end, Acc, Pb:get_rpc_names(SvrName))
        end
    end, #{}, Services).

-spec stop_server(any()) -> ok | {error, term()}.

%% @doc Stop a gRPC server
stop_server(Name) ->
    cowboy:stop_listener(Name).

%% @private
listen({IPAddr, Port})
  when is_tuple(IPAddr),
       is_integer(Port) ->
    {IPAddr, Port};
listen(AddrStr)
  when is_list(AddrStr);
       is_binary(AddrStr) ->
    case re:split(AddrStr, ":", [{return, list}]) of
        [IPAddr, Port] ->
            {ok, IPAddr1} = inet:parse_address(IPAddr),
            {IPAddr1, list_to_integer(Port)};
        [Port] ->
            {{0,0,0,0}, list_to_integer(Port)}
    end;
listen(Port) when is_integer(Port) ->
    {{0,0,0,0}, Port}.


%%--------------------------------------------------------------------
%% Internal funcs
%%--------------------------------------------------------------------

start_http_server(Name, {Ip, Port}, Options, UserOptions) ->
    Dispatch = cowboy_router:compile(
                 [{'_', [{"/:service/:method", grpc_cowboy_h, UserOptions}]}]
                ),
    ProtoOpts0 = #{env => #{dispatch => Dispatch},
                   protocols => [http2],
                   max_received_frame_rate => {100000, 1000},
                   stream_handlers => [grpc_stream_h, cowboy_stream_h]
                   },

    Ssloptions = proplists:get_value(ssl_options, Options, []),
    TransOpts0 = #{max_connections => 1024000,
                   socket_opts => [{ip, Ip}, {port, Port} | Ssloptions]
                  },
    TransOpts = maps:merge(proplists:get_value(ranch_opts, Options, #{}), TransOpts0),
    ProtoOpts = maps:merge(proplists:get_value(cowboy_opts, Options, #{}), ProtoOpts0),
    StartFun = case Ssloptions of
                   [] -> start_clear;
                   _ -> start_tls
               end,
    cowboy:StartFun(Name, TransOpts, ProtoOpts).
