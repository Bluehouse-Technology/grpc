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

-define(SERVER_PORT, 10023).
-define(SERVER_NAME, server).
-define(CHANN_NAME, channel).

%%--------------------------------------------------------------------
%% Setups
%%--------------------------------------------------------------------

all() ->
    [t_performance].

init_per_suite(Cfg) ->
    %dbg:tracer(),dbg:p(all,call),
    %dbg:tpl(cowboy_clear, init,x),
    %dbg:tp(grpc_server, init,x),

    ok = compile_greeter_proto(Cfg),
    {ok, _} = grpc:start_server(?SERVER_NAME, tcp, ?SERVER_PORT, #{'Greeter' => #{handler => greeter_server, decoder => greeter}}),
    {ok, _} = grpc_client_sup:create_channel_pool(?CHANN_NAME, "http://127.0.0.1:10023", #{}),
    application:ensure_all_started(grpc),
    Cfg.

end_per_suite(_Cfg) ->
    _ = grpc_client_sup:stop_channel_pool(?CHANN_NAME),
    _ = grpc:stop_server(?SERVER_NAME),
    application:stop(grpc).

compile_greeter_proto(Cfg) ->
    DataDir = proplists:get_value(data_dir, Cfg),
    TestDir = re:replace(DataDir, "/grpc_performance_SUITE_data", "", [{return, list}]),
    ok = grpc_lib_compile:file(filename:join([TestDir, "greeter.proto"]), []),
    ok = grpc_lib_compile:file(filename:join([TestDir, "greeter.proto"]), [{generate, client}]),
    {ok, _} = compile:file("greeter_server.erl"),
    {ok, _} = compile:file("greeter_client.erl"), ok.

%%--------------------------------------------------------------------
%% Test cases
%%--------------------------------------------------------------------

matrix() ->
    %% Procs count, Req/procs, Req size
    [ {1, 20, 10240}        %% 100KB
    , {100, 20, 1024}      %% 10MB
    , {1000, 20, 1024}     %% 100MB
    %, {100, 10000, 1024}    %% 1000MB
%
%     , {10000, 1, 32}        %% 312KB
%     , {1, 1000000, 32}        %% 312KB
%     , {100, 100, 32}        %% 312KB
%    , {100, 100, 64}        %% 624KB
%    , {100, 100, 128}       %% 1.24MB
%    , {100, 100, 1024}      %% 100MB
%    , {100, 100, 8192}      %% 800MB
%    , {100, 100, 65536}     %% 2500MB
    ].

t_performance(_) ->
   % code:add_path("/Users/hejianbo/eflame/ebin"),
   % code:load_file(eflame),
   % code:load_file(eflame2),
   % code:load_file(eflame_app),
   % code:load_file(eflame_sup),

   % Pid = gproc_pool:pick_worker(?CHANN_NAME, self()),
   % spawn(fun() ->
   %    io:format("Tracing started...\n"),
   %    eflame2:write_trace(global_calls_plus_new_procs, "/tmp/ef.test.0",Pid , 10*1000),
   %    io:format("Tracing finished!\n")
   % end),

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
        try grpc_client:unary(
              <<"/Greeter/SayHello">>, HelloReq,
                #{message_type => <<"HelloRequest">>,
                  marshal => fun(I) -> greeter:encode_msg(I, 'HelloRequest') end,
                  unmarshal => fun(O) -> greeter:decode_msg(O, 'HelloReply') end },
                #{channel => ?CHANN_NAME}) of
            {ok, _, _} -> ok;
            Err ->
                ?LOG("1Send request failed: ~p~n", [Err]),
                error
        catch Type:Name:Stk ->
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
                  end
          end,
    Clt(Pcnt*Rcnt),
    {_, Time1} = statistics(runtime),
    {_, Time2} = statistics(wall_clock),
    ?LOG("--   CPU time: ~s, Procs time: ~s\n", [format_ts(Time1), format_ts(Time2)]),
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
