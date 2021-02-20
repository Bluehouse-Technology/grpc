%%--------------------------------------------------------------------
%% Copyright (c) 2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(grpc_health_svr).

-behavior(grpc_health_v_1_health_bhvr).

-export([ check/2
        , watch/2
        ]).

-dialyzer({nowarn_function, [check/2, watch/2]}).

%%--------------------------------------------------------------------
%% Callbacks

-spec check(grpc_health_pb:health_check_request(), grpc:metadata())
    -> {ok, grpc_health_pb:health_check_response(), grpc:metadata()}
     | {error, grpc_stream:error_response()}.
check(#{service := _Service}, _Md) ->
    %% TODO: How to get the Service running status?
    {ok, #{status => 'SERVING'}}.

-spec watch(grpc_stream:stream(), grpc:metadata())
    -> {ok, grpc_stream:stream()}.
watch(Stream, _Md) ->
    %% TODO: How to get the Service running status?
    {eos, [#{service := _Service}], NStream} = grpc_stream:recv(Stream),
    RelpyLp = fun _Lp() ->
                grpc_stream:reply(NStream, [#{status => 'SERVING'}]),
                timer:sleep(15000),
                _Lp()
              end,
    RelpyLp(),
    {ok, NStream}.
