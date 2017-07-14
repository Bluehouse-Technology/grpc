-module(h2_SUITE).
-include_lib("common_test/include/ct.hrl").
-compile(export_all).

%%--------------------------------------------------------------------
%% Run tests via erlang.mk: 
%% $> make ct
%% or:
%% $> make SKIP_DEPS=1 ct
%%
%% To run only this suite:
%% $> make SKIP_DEPS=1 ct-h2
%%
%% These tests assume that an HTTP/2 server is running on port 10000.
%% The go module in test/golang/server.go can be used for this:
%% $> go run server.go
%%--------------------------------------------------------------------

-define(BVM_TRAIL, "Berkshire Valley Management Area Trail, Jefferson, NJ, USA").
-define(BVM_TRAIL_POINT, #{latitude => 409146138,
                           longitude => -746188906}).

%%--------------------------------------------------------------------
%% Test server callback functions
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: suite() -> DefaultData
%% DefaultData: [tuple()]  
%% Description: Require variables and set default values for the suite
%%--------------------------------------------------------------------
suite() -> 
    [{timetrap, {seconds, 5}}].

%%--------------------------------------------------------------------
%% Function: init_per_suite(Config) -> Config
%% Config: [tuple()]
%%   A list of key/value pairs, holding the test case configuration.
%% Description: Initiation for the whole suite
%%
%% Note: This function is free to add any key/value pairs to the Config
%% variable, but should NOT alter/remove any existing entries.
%%--------------------------------------------------------------------
init_per_suite(Config) ->
    Config.

%%--------------------------------------------------------------------
%% Function: end_per_suite(Config) -> _
%% Config: [tuple()]
%%   A list of key/value pairs, holding the test case configuration.
%% Description: Cleanup after the whole suite
%%--------------------------------------------------------------------
end_per_suite(_Config) ->
    ok.

%%--------------------------------------------------------------------
%% Function: groups() -> [Group]
%%
%% Group = {GroupName,Properties,GroupsAndTestCases}
%% GroupName = atom()
%%   The name of the group.
%% Properties = [parallel | sequence | Shuffle | {RepeatType,N}]
%%   Group properties that may be combined.
%% GroupsAndTestCases = [Group | {group,GroupName} | TestCase]
%% TestCase = atom()
%%   The name of a test case.
%% Shuffle = shuffle | {shuffle,Seed}
%%   To get cases executed in random order.
%% Seed = {integer(),integer(),integer()}
%% RepeatType = repeat | repeat_until_all_ok | repeat_until_all_fail |
%%              repeat_until_any_ok | repeat_until_any_fail
%%   To get execution of cases repeated.
%% N = integer() | forever
%%
%% Description: Returns a list of test case group definitions.
%%--------------------------------------------------------------------
groups() ->
    [{tutorial, [sequence],
        [compile_routeguide_proto
        ,run_getfeature
        ,run_listfeatures
        ,run_routechat
        ,continuation
        ,continuation_resp
        ,routechat_flow_control
        ,routechat_throttled
        ,ping
        ,ping_timeout
        ,run_recordroute
        ]}
    ].

init_per_group(Group, Config) ->
    Port = case Group of
               _ -> 10000
           end,
    [{port, Port} | Config].

end_per_group(_, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% Function: all() -> TestCases
%% TestCases: [Case] 
%% Case: atom()
%%   Name of a test case.
%% Description: Returns a list of all test cases in this test suite
%%--------------------------------------------------------------------      
all() -> 
    [
     {group, tutorial}
    ].

%%-------------------------------------------------------------------------
%% Test cases start here.
%%-------------------------------------------------------------------------

compile_routeguide_proto(_Config) ->
    ExampleDir = filename:join(code:lib_dir(grpc, examples), "route_guide"),
    ok = grpc:compile("route_guide.proto", [{i, ExampleDir}]),
    ok = grpc_client:compile("route_guide.proto", [{i, ExampleDir}]),
    true = lists:all(fun (F) ->
                         filelib:is_file(F) 
                     end, 
                     ["route_guide.erl",
                      "route_guide_server.erl",
                      "route_guide_client.erl"
                      ]).

run_getfeature(Config) ->
    process_flag(trap_exit, true),
    Port = port(Config),
    {ok, Connection} = grpc_client:connect(tcp, "localhost", Port),
    {ok, #{result := #{name := ?BVM_TRAIL}}} = feature(Connection,
                                                       ?BVM_TRAIL_POINT).

continuation(Config) ->
    {ok, Connection} = grpc_client:connect(tcp, "localhost", port(Config)),
    %% default max message size = 16384. Note that this will be compressed
    %% so we need something that is hard to compress.
    BigHeader = list_to_binary([rand:uniform(255) || _ <- lists:seq(1, 20000)]),
    {ok, #{result := #{name := ?BVM_TRAIL}}} =
        feature(Connection,
                ?BVM_TRAIL_POINT,
                [{metadata, #{<<"big_header-bin">> => BigHeader,
                              <<"test_case">> => <<"big_header_to_server">>}}]).

continuation_resp(Config) ->
    {ok, Connection} = grpc_client:connect(tcp, "localhost", port(Config)),
    %% default max message size = 16384. Note that this will be compressed
    %% so we need something that is hard to compress.
    BigHeader = list_to_binary([rand:uniform(255) || _ <- lists:seq(1, 20000)]),
    {ok, #{result := #{name := ?BVM_TRAIL}}} =
        feature(Connection,
                ?BVM_TRAIL_POINT,
                [{metadata, #{<<"big_header-bin">> => BigHeader,
                              <<"test_case">> => <<"big_header_echo">>}}]).

run_listfeatures(Config) ->
    {ok, Connection} = grpc_client:connect(tcp, "localhost", port(Config)),
    {ok, Stream} = grpc_client:new_stream(Connection, 'RouteGuide', 
                                            'ListFeatures', route_guide),
    P1 = ?BVM_TRAIL_POINT, 
    P2 = ?BVM_TRAIL_POINT,
    ok = grpc_client:send_last(Stream, #{lo => P1, hi => P2}),
    %% A little bit of time will pass before the response arrives...
    timer:sleep(500),
    {headers,#{<<":status">> := <<"200">>}} = grpc_client:get(Stream),
    {data,#{name := ?BVM_TRAIL}} = grpc_client:get(Stream).

run_routechat(Config) ->
    route_chat(Config, [], []).

routechat_flow_control(Config) ->
    WindowManager = window_manager(0),
    route_chat(Config, [{http2_options, [{initial_window_size, 3000}]}],
                       [{http2_options, [{window_mgmt_fun, WindowManager}]}]).

routechat_throttled() ->
    %% This test takes a little bit longer.
    [{timetrap,{minutes,5}}].

routechat_throttled(Config) ->
    WindowManager = window_manager(1000),
    route_chat(Config, [{http2_options, [{initial_window_size, 3000}]}],
                       [{http2_options, [{window_mgmt_fun, WindowManager}]}]).

route_chat(Config, ConnectionOptions, StreamOptions) ->
    {ok, Connection} = grpc_client:connect(tcp, "localhost",
                                           port(Config), ConnectionOptions),
    {ok, Stream} = grpc_client:new_stream(Connection, 'RouteGuide', 
                                          'RouteChat', route_guide, 
                                          StreamOptions),
    %% use random points so that the server can remain running between
    %% tests
    P1 = #{latitude => rand:uniform(100000), 
           longitude => rand:uniform(100000)}, 
    P2 = #{latitude => rand:uniform(100000),
           longitude => rand:uniform(100000)}, 
    %% get communication going
    ok = grpc_client:send(Stream, #{location => P1, 
                                    message => "something about P1"}),
    timer:sleep(500),
    {headers, _}  = grpc_client:get(Stream),
    Msg1  = grpc_client:get(Stream),
    io:format("Msg 1: ~p~n", [Msg1]),

    %% for i = 1 to n: send a message to and receive back i messages. 
    %% 17 bytes are used for the coordinates etc., so 2000 - 17 results in
    %% a payload of 2000 bytes
    LongMessage = [$a || _ <- lists:seq(1, 2000 - 17)],
    Msg = #{location => P2, message => LongMessage},
    chat_n_times(1, 10, Stream, Msg).

chat_n_times(N, N, Stream, Msg) ->
    ok = grpc_client:send_last(Stream, Msg),
    receive_n_times(N, Stream),
    {headers, _} = grpc_client:rcv(Stream, 500);
chat_n_times(I, N, Stream, Msg) ->
    ok = grpc_client:send(Stream, Msg),
    receive_n_times(I, Stream),
    chat_n_times(I + 1, N, Stream, Msg).

receive_n_times(N, Stream) ->
    [{data, _} = grpc_client:rcv(Stream, 1500) || _ <- lists:seq(1, N)].


ping(Config) ->
    {ok, Connection} = grpc_client:connect(tcp, "localhost",
                                           port(Config)),
    {ok, _} = grpc_client:ping(Connection, 500).

ping_timeout(Config) ->
    {ok, Connection} = grpc_client:connect(tcp, "localhost",
                                           port(Config)),
    %% Presumably a timeout value of 0 will result in a timeout.
    {error, timeout} = grpc_client:ping(Connection, 0).

run_recordroute(Config) ->
    {ok, Connection} = grpc_client:connect(tcp, "localhost", port(Config)),
    {ok, Stream} = grpc_client:new_stream(Connection, 'RouteGuide', 
                                            'RecordRoute', route_guide),
    P1 = #{latitude => 1, longitude => 2}, 
    P2 = #{latitude => 3, longitude => 5},
    ok = grpc_client:send(Stream, P1),
    ok = grpc_client:send_last(Stream, P2),
    {headers,#{<<":status">> := <<"200">>}} = grpc_client:rcv(Stream, 500),
    {data, #{point_count := 2}} = grpc_client:rcv(Stream, 500).

receive_many_messages(Config) ->
    {ok, Connection} = grpc_client:connect(tcp, "localhost", port(Config)),
    Count = 30,
    Size = 3000,
    Options = [{metadata, #{<<"nr_of_points">> => integer_to_binary(Count),
                            <<"size">> => integer_to_binary(Size)}}],
    {ok, Stream} = grpc_client:new_stream(Connection, 'RouteGuide', 
                                          'ListFeatures', route_guide, Options),
    P1 = #{latitude => 1, longitude => 2}, 
    P2 = #{latitude => 3, longitude => 5},
    ok = grpc_client:send_last(Stream, #{hi => P1, lo => P2}),
    %% A little bit of time will pass before the response arrives...
    timer:sleep(500),
    {headers, _} = grpc_client:get(Stream),
    lists:foreach(fun (_) ->
                      {data, _} = grpc_client:get(Stream)
                  end, lists:seq(1, Count)),
    {headers, _} = grpc_client:get(Stream),
    eof = grpc_client:get(Stream).

secure_request(Config) ->
    process_flag(trap_exit, true),
    Options = [{verify_server_identity, true},
               {http2_options, [{transport, {ssl, [{cacertfile,
                                                    certificate("My_Root_CA.crt")}]}}
                               ]}
              ],
    {ok, Connection} = grpc_client:connect(ssl, "localhost", port(Config), Options),
    {ok, #{result := #{name := ?BVM_TRAIL}}} = feature(Connection,
                                                       ?BVM_TRAIL_POINT).
tls_connection_fails(Config) ->
    %% Fails because the client does not provide a certificate
    process_flag(trap_exit, true),
    %%VerifyFun = fun(Certificate, Event, []) -> 
                    %%ct:pal("Certificate: ~p~nEvent: ~p~n", 
                           %%[Certificate, Event]),
                    %%{valid, []}
                %%end,
    Options = [{verify_server_identity, true},
               {http2_options, [{transport, {ssl, [{verify, verify_peer},
                                                   {cacertfile,
                                                    certificate("My_Root_CA.crt")}]}}
                               ]}
              ],
    {error, {tls_alert, "handshake failure"}} = 
        grpc_client:connect(ssl, "localhost", port(Config), Options).

ssl_without_server_identification(Config) ->
    process_flag(trap_exit, true),
    TlsOptions = [{verify, verify_peer},
                  {fail_if_no_peer_cert, true},
                  {cacertfile, certificate("My_Root_CA.crt")}],
    {ok, Connection} = grpc_client:connect(ssl, "localhost", port(Config), TlsOptions),
    {ok, #{result := #{name := ?BVM_TRAIL}}} = feature(Connection,
                                                       ?BVM_TRAIL_POINT).

authenticated_request(Config) ->
    process_flag(trap_exit, true),
    TlsOptions = [{certfile, certificate("127.0.0.1.crt")},
                  {keyfile, certificate("127.0.0.1.key")},
                  {cacertfile, certificate("My_Root_CA.crt")}],
    {ok, Connection} = grpc_client:connect(ssl, "localhost", port(Config), TlsOptions),
    {ok, #{result := #{name := ?BVM_TRAIL}}} = feature(Connection,
                                                       ?BVM_TRAIL_POINT).
wrong_client_certificate(Config) ->
    process_flag(trap_exit, true),
    %% Provide a certificate that is not in the list of certificates
    %% that is accepted by the server. (Reusing "localhost" for that 
    %% purpose).
    TlsOptions = [{certfile, certificate("localhost.crt")},
                  {keyfile, certificate("localhost.key")},
                  {cacertfile, certificate("My_Root_CA.crt")}],
    {ok, Connection} = grpc_client:connect(ssl, "localhost", port(Config), TlsOptions),
    {error, #{error_type := grpc,
              grpc_status := 16}} =
        feature(Connection, ?BVM_TRAIL_POINT).

%%-----------------------------------------------------------------------------
%% Internal functions
%% ----------------------------------------------------------------------------

feature(Connection, Message) ->
    feature(Connection, Message, []).

feature(Connection, Message, Options) ->
    grpc_client:unary(Connection, Message, 'RouteGuide', 
                      'GetFeature', route_guide, Options).

%% Example certificates are in "test/certificates".
cert_dir() ->
    CertDir = filename:join([code:lib_dir(grpc, test), "certificates"]),
    true = filelib:is_dir(CertDir),
    CertDir.

%% This directory contains the certifcates of the clients that are 
%% accepted by the server.
client_cert_dir() ->
    ClientCertDir = filename:join([cert_dir(), "clients"]),
    true = filelib:is_dir(ClientCertDir),
    ClientCertDir.

certificate(FileName) ->
    R = filename:join([cert_dir(), FileName]),
    true = filelib:is_file(R),
    R.

port(Config) ->
    proplists:get_value(port, Config).

window_manager(Sleep) ->
    fun(Current, Initial, _, Data) ->
        io:format("current window: ~p~n", [Current]),
        case Current =< 2000 of
            false ->
                io:format("don't update~n"),
                {ok, Data};
            true ->
                case Sleep of
                    0 -> ok;
                    _ ->
                        io:format("sleep...~n"),
                        timer:sleep(Sleep)
                end,
                io:format("update, top up to 3000~n"),
                {{window_update, Initial - Current}, Data}
        end
    end.
