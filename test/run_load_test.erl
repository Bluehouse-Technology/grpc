%% use make to run the tests (see Makefile):
%% $> make grpc_load_test
%% $> make rpc_load_test

-module(run_load_test).
-export([start_grpc_server/0]).
-export([start_native_server/0]).
-export([start_client/0]).

start_grpc_server() ->
    {ok, _} = grpc:start_server(load_test, tcp, 10000,
                                #{get_stats => #{handler => statistics_server}}),
    log_msg("Server started~n", []).

start_native_server() ->
    ok.

%% If Rpc_type == grpc, Server is the host name of the server
%% ("localhost", typically).
%% If Rpc_type == native, Server is the erlang node name, for example
%% 'grpc_test@localhost'.
start_client() ->
    Rpc_type  = get_arg_val(rpc_type, grpc),
    ServerArg = get_arg_val(server, undefined),
    N_workers = get_arg_val(num_workers, 100),
    N_reqs    = get_arg_val(num_requests_per_worker, 100),
    Server = case Rpc_type of 
                 native -> list_to_atom(ServerArg);
                 grpc -> ServerArg;
                 undefined -> io:format("Error: server argument must be provided~n")
             end,
    start(Server, N_workers, N_reqs, Rpc_type).

get_arg_val(Tag, Def_val) ->
    try
        [Val_str] = proplists:get_value(Tag, init:get_arguments()),
        case Tag of
            server ->
                Val_str;
            rpc_type ->
                Val_atom  = list_to_atom(Val_str),
                true      = ((Val_atom == native) orelse (Val_atom == grpc)),
                Val_atom;
            _ ->
                Val_int   = list_to_integer(Val_str),
                true      = is_integer(Val_int),
                true      = (Val_int > 0),
                Val_int
        end
    catch _:_ ->
            Def_val
    end.

start(Server, Num_workers, Num_reqs, Rpc_type) ->
    ets:new(ts_counters, [named_table, public, {write_concurrency, true}, {read_concurrency, true}]),
    ets:new(counters,    [named_table, public, {write_concurrency, true}, {read_concurrency, true}]),
    ets:new(worker_pids, [named_table, public, {write_concurrency, true}, {read_concurrency, true}]),
    log_msg("Starting spawn of ~p workers...~n", [Num_workers]),
    spawn_workers(Num_workers, Num_reqs, Rpc_type, Server),
    log_msg("Finished spawning workers~n", []),
    wait_for_finish(),
    print_results(),
    erlang:halt().

spawn_workers(0, _, _, _) ->
    ok;
spawn_workers(Num_workers, Num_reqs, Rpc_type, Server) ->
    Pid = spawn(fun() ->
                        worker_init(Num_reqs, Rpc_type, Server)
                end),
    ets:insert(worker_pids, {Pid, []}),
    Pid ! start,
    spawn_workers(Num_workers - 1, Num_reqs, Rpc_type, Server).

wait_for_finish() ->
    case ets:info(worker_pids, size) of
        0 ->
            ok;
        N ->
            log_msg("Waiting for ~p workers to finish...~n", [N]),
            timer:sleep(5000),
            wait_for_finish()
    end.

worker_init(Num_reqs, Rpc_type=grpc, Server) when is_list(Server) ->
    receive
        start ->
            {ok, Connection} = grpc_client:connect(tcp, Server, 10000),
            worker_loop(Num_reqs, Connection, Rpc_type, Server)
    end;
worker_init(Num_reqs, Rpc_type=native, Server) ->
    receive
        start ->
            worker_loop(Num_reqs, undefined, Rpc_type, Server)
    end.

worker_loop(0, _, _, _) ->
    ets:delete(worker_pids, self()),
    ok;
worker_loop(N, Connection, Rpc_type, Server) ->
    update_counter(req_attempted, 1),
    case do_rpc(Connection, Rpc_type, Server) of
        ok ->
            update_ts_counter(success, 1);
        {badrpc, Reason} ->
            update_ts_counter(Reason, 1)
    end,
    worker_loop(N - 1, Connection, Rpc_type, Server).

do_rpc(Connection, grpc, _) ->
    case statistics_client:get_stats(Connection,
                                     #{type_field => microstate_accounting}, []) of
        {ok, #{}} ->
            ok;
        Other ->
            Other
    end;
do_rpc(_, native, Server) when is_atom(Server) ->
    case rpc:call(Server, erlang, statistics, [microstate_accounting]) of
        L when is_list(L) ->
            ok;
        {badrpc, Reason} ->
            {error, Reason}
    end.

update_ts_counter(Key, Val) ->
    Key_ts = {calendar:local_time(), Key},
    ets:update_counter(ts_counters, Key_ts, {2, Val}, {Key_ts, 0}).

update_counter(Key, Val) ->
    ets:update_counter(counters, Key, {2, Val}, {Key, 0}).

log_msg(Fmt, Args) ->
    io:format("~s -- " ++ Fmt, [printable_ts(calendar:local_time()) | Args]).

print_results() ->
    Dict = lists:foldl(
               fun({{Ts, Key}, Val}, X_dict) ->
                       dict:update(Ts, 
                                   fun(Res_tvl) ->
                                           [{Key, Val} | Res_tvl]
                                   end, [{Key, Val}], X_dict)
               end, dict:new(), ets:tab2list(ts_counters)),
    Res_tvl         = lists:keysort(1, dict:to_list(Dict)),
    Start_time      = element(1, hd(Res_tvl)),
    End_time        = element(1, hd(lists:reverse(Res_tvl))),
    {TT_d, TT_s}    = calendar:time_difference(Start_time, End_time),
    TT_secs         = TT_d*86400 + calendar:time_to_seconds(TT_s),
    [{_, Num_reqs}] = ets:lookup(counters, req_attempted),
    ReqsPerSec = case TT_secs of
                     0 -> undefined;
                     _ -> trunc(Num_reqs/TT_secs)
                 end,
    io:format("~n", []),
    io:format("Start time                   : ~s~n", [printable_ts(Start_time)]),
    io:format("End time                     : ~s~n", [printable_ts(End_time)]),
    io:format("Elapsed time (seconds)       : ~p~n", [TT_secs]),
    io:format("Number of attempted requests : ~p~n", [Num_reqs]),
    io:format("Req/sec                      : ~p~n", [ReqsPerSec]),
    io:format("~n", []),
    io:format("~-30.30.\ss success, timeout, not_connected~n", ["Timestamp"]),
    lists:foreach(fun({X_key, X_vals}) ->
                          X_succ     = proplists:get_value(success, X_vals, 0),
                          X_timeout  = proplists:get_value(timeout, X_vals, 0),
                          X_not_conn = proplists:get_value(not_connected, X_vals, 0),
                          io:format("~s\t\t~10.10.\sw, ~7.7.\sw, ~13.13.\sw~n", 
                                    [printable_ts(X_key),
                                     X_succ, 
                                     X_timeout, X_not_conn])
                  end, Res_tvl).
printable_ts({{Y, M, D}, {H, Mi, S}}) ->
    io_lib:format("~p-~2.2.0w-~2.2.0w_~2.2.0w:~2.2.0w:~2.2.0w", [Y, M, D, H, Mi, S]).
