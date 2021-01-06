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

-module(grpc_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(SERVER_NAME, server).
-define(CHANN_NAME, channel).

-define(LOG(Fmt, Args), io:format(standard_error, Fmt, Args)).

%%--------------------------------------------------------------------
%% Setups
%%--------------------------------------------------------------------

all() ->
    [{group, http}, {group, https}].

groups() ->
    Tests = [t_hello, t_get_feature, t_list_features, t_record_route],
    [{http, Tests}, {https,Tests}].

init_per_group(GrpName, Cfg) ->
    DataDir = proplists:get_value(data_dir, Cfg),
    TestDir = re:replace(DataDir, "/grpc_SUITE_data", "", [{return, list}]),
    CA = filename:join([TestDir, "certs", "ca.pem"]),
    Cert = filename:join([TestDir, "certs", "cert.pem"]),
    Key = filename:join([TestDir, "certs", "key.pem"]),

    Services = #{protos => [ct_greeter_pb, ct_route_guide_pb],
                 services => #{'Greeter' => greeter_svr,
                               'routeguide.RouteGuide' => route_guide_svr}
                },
    Options = case GrpName of
                  https ->
                      [{ssl_options, [{cacertfile, CA},
                                      {certfile, Cert},
                                      {keyfile, Key}]}];
                  _ -> []
              end,
    ClientOps = case GrpName of
                    https ->
                        #{gun_opts =>
                          #{transport => ssl,
                            transport_opts => [{cacertfile, CA}]}};
                    _ -> #{}
                end,
    SvrAddr = case GrpName of
                  https -> "https://127.0.0.1:10000";
                  _ -> "http://127.0.0.1:10000"
              end,

    {ok, _} = grpc:start_server(?SERVER_NAME, 10000, Services, Options),
    {ok, _} = grpc_client_sup:create_channel_pool(?CHANN_NAME, SvrAddr, ClientOps),
    Cfg.

end_per_group(_GrpName, _Cfg) ->
    _ = grpc_client_sup:stop_channel_pool(?CHANN_NAME),
    _ = grpc:stop_server(?SERVER_NAME).

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

t_hello(_) ->
    ?assertMatch({ok, _, _},
                 greeter_client:say_hello(#{}, #{channel => ?CHANN_NAME})).

t_get_feature(_) ->
    ?assertMatch({ok, _, _},
                 routeguide_route_guide_client:get_feature(#{}, #{}, #{channel => ?CHANN_NAME})).

t_list_features(_) ->
    {ok, Stream} = routeguide_route_guide_client:list_features(#{}, #{channel => ?CHANN_NAME}),
    grpc_client:streaming(Stream, #{}, fin).

t_record_route(_) ->
    {ok, Stream} = routeguide_route_guide_client:record_route(#{}, #{channel => ?CHANN_NAME}),
    grpc_client:streaming(Stream, #{latitude => 1, longitude => 2}),
    grpc_client:streaming(Stream, #{latitude => 2, longitude => 3}),
    timer:sleep(100),
    grpc_client:streaming(Stream, #{latitude => 3, longitude => 4}, fin).
