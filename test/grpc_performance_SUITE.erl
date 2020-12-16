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

-module(grpc_performance_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(LOG(Fmt), io:format(standard_error, Fmt, [])).
-define(LOG(Fmt, Args), io:format(standard_error, Fmt, Args)).

-define(SERVER_NAME, server).
-define(CHANN_NAME, channel).

%%--------------------------------------------------------------------
%% Setups
%%--------------------------------------------------------------------

all() ->
    [t_performance].

init_per_suite(Cfg) ->
    Services = #{protos => [ct_greeter_pb],
                 services => #{'Greeter' => greeter_svr}
                },
    {ok, _} = grpc:start_server(?SERVER_NAME, 10000, Services),
    {ok, _} = grpc_client_sup:create_channel_pool(?CHANN_NAME, "http://127.0.0.1:10000", #{}),
    Cfg.

end_per_suite(_Cfg) ->
    _ = grpc_client_sup:stop_channel_pool(?CHANN_NAME),
    _ = grpc:stop_server(?SERVER_NAME).

%%--------------------------------------------------------------------
%% Test cases
%%--------------------------------------------------------------------

matrix() ->
    %% Procs count, Req/procs, Req size
    [ {1, 2, 10}
    , {100, 100, 1024}
    , {1000, 100, 1024}
%    , {100, 10000, 1024}    %% 1000MB
%
%    , {10000, 1, 32}        %% 312KB
%    , {1, 1000000, 32}      %% 312KB
%    , {100, 100, 32}        %% 312KB
%    , {100, 100, 64}        %% 624KB
%    , {100, 100, 128}       %% 1.24MB
%    , {100, 100, 1024}      %% 100MB
%    , {100, 100, 8192}      %% 800MB
%    , {100, 100, 65536}     %% 2500MB
    ].

t_performance(_) ->
    Res = [{M, shot_one_case(M)} || M <- matrix()],
    ?LOG("\n\n"),
    ?LOG("Statistics: \n"),
    format_result(Res).

%%--------------------------------------------------------------------
%% Internal funcs

shot_once_func(Size) ->
    Bin = chaos_bin(Size),
    HelloReq = #{name => Bin},
    fun() ->
        try greeter_client:say_hello(HelloReq, #{channel => ?CHANN_NAME}) of
            {ok, _, _} -> ok;
            Err ->
                ?LOG("1Send request failed: ~p~n", [Err]),
                error
        catch Type:Name:_Stk ->
                ?LOG("Send request failed: ~p:~p:~n", [Type, element(1,Name)]),
                error
        end
    end.

shot_one_case({Pcnt, Rcnt, Rsize}) ->
    Throughput = Pcnt * Rcnt * Rsize,
    RequestCnt = Pcnt * Rcnt,

    ShotFun = shot_once_func(Rsize),

    P = self(),
    ?LOG("\n"),
    ?LOG("===============================================\n"),
    ?LOG("--  Request: ~s, size: ~s Total: ~s\n", [format_cnt(RequestCnt), format_byte(Rsize), format_byte(Throughput)]),
    ?LOG("--\n"),
    statistics(runtime),
    statistics(wall_clock),
    [spawn(fun() ->
        [begin
             P ! {ShotFun(), I, J}
         end || J <- lists:seq(1, Rcnt)]
     end) || I <- lists:seq(1, Pcnt)],

    Clt = fun _F(0) -> ok;
              _F(X) ->
                  receive
                      {_, _I, _J} -> _F(X-1)
                  after 1000 -> ok
                  end
          end,
    Clt(Pcnt*Rcnt),
    Time1 = case statistics(runtime) of
                {_, 0} -> 1;
                {_, T1} -> T1
            end,
    Time2 = case statistics(wall_clock) of
                {_, 0} -> 1;
                {_, T2} -> T2
            end,
    ?LOG("--   Run time: ~s, Wall Clock time: ~s\n", [format_ts(Time1), format_ts(Time2)]),
    ?LOG("--        TPS: ~s/s (~s/s) \n", [format_cnt(1000*RequestCnt/Time1), format_cnt(1000*RequestCnt/Time2)]),
    ?LOG("-- Throughput: ~s/s (~s/s) \n", [format_byte(1000*Throughput/Time1), format_byte(1000*Throughput/Time2)]),
    ?LOG("===============================================\n"),
    {1000*RequestCnt/Time2, 1000*Throughput/Time2}.

%%--------------------------------------------------------------------
%% Utils

chaos_bin(S) ->
    iolist_to_binary([$a || _ <- lists:seq(1, S)]).

format_ts(Ms) ->
    case Ms > 1000 of
        true ->
            lists:flatten(io_lib:format("~.2fs", [Ms/1000]));
        _ ->
            lists:flatten(io_lib:format("~wms", [Ms]))
    end.

format_byte(Byte) ->
    if
        Byte > 1024*124 ->
            lists:flatten(io_lib:format("~.2fMB", [Byte/1024/1024]));
        Byte > 1024 ->
            lists:flatten(io_lib:format("~.2fKB", [Byte/1024]));
        true ->
            lists:flatten(io_lib:format("~wB", [Byte]))
    end.

format_cnt(Cnt) ->
    case Cnt > 1000 of
        true ->
            lists:flatten(io_lib:format("~.2fk", [Cnt / 1000]));
        _ ->
            lists:flatten(io_lib:format("~w", [Cnt]))
    end.

format_result([]) ->
    ok;
format_result([{{Pcnt, Rcnt, Rsize}, {Tps, Throughput}}|Rs]) ->
    ?LOG("\t~w, ~w, ~w, ~w\n", [Pcnt*Rcnt, Rsize, Tps, Throughput]),
    format_result(Rs).
