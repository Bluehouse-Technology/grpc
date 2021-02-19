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

-module(grpc_reflection_svr).

-behavior(grpc_reflection_v_1alpha_server_reflection_bhvr).

-export([server_reflection_info/2]).

%%--------------------------------------------------------------------
%% Callbacks

-spec server_reflection_info(grpc_stream:stream(), grpc:metadata())
    -> {ok, grpc_stream:stream()}.

server_reflection_info(Stream, _Md) ->
    LoopRecv = fun _Lp(St) ->
        case grpc_stream:recv(St) of
            {more, Reqs, NSt} ->
                io:format("reflection req: ~p~n", [Reqs]),
                _Lp(NSt);
            {eos, Reqs, NSt} ->
                io:format("reflection req: ~p~n", [Reqs]),
                NSt
        end
    end,
    NStream = LoopRecv(Stream),
    {ok, NStream}.
