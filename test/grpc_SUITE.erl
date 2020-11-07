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

%%--------------------------------------------------------------------
%% Setups
%%--------------------------------------------------------------------

all() ->
    [{group, http}, {group, https}].

groups() ->
    Tests = [t_hello],
    [{http, Tests}, {https,Tests}].

init_per_group(GrpName, Cfg) ->
    DataDir = proplists:get_value(data_dir, Cfg),
    TestDir = re:replace(DataDir, "/grpc_SUITE_data", "", [{return, list}]),
    CA = filename:join([TestDir, "certs", "ca.pem"]),
    Cert = filename:join([TestDir, "certs", "cert.pem"]),
    Key = filename:join([TestDir, "certs", "key.pem"]),

    Services = #{protos => [ct_greeter_pb],
                 services => #{'Greeter' => greeter_svr}
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
                  https -> "https://127.0.0.1:10023";
                  _ -> "http://127.0.0.1:10023"
              end,

    {ok, _} = grpc:start_server(?SERVER_NAME, 10023, Services, Options),
    {ok, _} = grpc_client_sup:create_channel_pool(?CHANN_NAME, SvrAddr, ClientOps),
    Cfg.

end_per_group(_GrpName, _Cfg) ->
    _ = grpc_client_sup:stop_channel_pool(?CHANN_NAME),
    _ = grpc:stop_server(?SERVER_NAME).

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

t_hello(_) ->
    ?assertMatch({ok, _, _}, greeter_client:say_hello(#{}, #{channel => ?CHANN_NAME})),
    ok.
