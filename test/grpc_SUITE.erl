-module(grpc_SUITE).
-include_lib("common_test/include/ct.hrl").
-compile(export_all).

%%--------------------------------------------------------------------
%% Run tests via erlang.mk: 
%% $> make ct
%% or:
%% $> make SKIP_DEPS=1 ct
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
    [].

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
    application:set_env(lager, error_logger_redirect, false),
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
        ,compile_routeguide_generated
        ,compile_routeguide_example
        ,start_routeguide_server
        ,run_getfeature
        ,getfeature_client
        ,run_listfeatures
        ,run_routechat
        ,run_recordroute
        ]},
     {metadata, [sequence],
        [compile_example_2
        ,start_server_2
        ,metadata_from_client
        ,error_response
        ,metadata_from_server
        ,binary_metadata_from_client
        ,binary_metadata_from_server
        ,header_overwrite
        ]},
     {compressed, [sequence],
        [start_server_2
        ,getfeature_compressed_request
        ,getfeature_compressed_response
        ]},
     {security, [sequence],
        [start_server_secure
        ,secure_request
        ]},
     {authenticated, [sequence],
        [start_server_authenticating
        ,authenticated_request
        ,tls_connection_fails
        ,wrong_client_certificate
        ]},
     {security_issues, [sequence],
        [start_server_wrong_certificate
        ,ssl_without_server_identification
        ,invalid_peer_certificate
        ]}
    ].

init_per_group(Group, Config) ->
    Port = case Group of
               tutorial -> 10000;
               metadata -> 10000;
               compressed -> 10000;
               security -> 10000;
               authenticated -> 10000;
               security_issues -> 10000
           end,
    [{port, Port} | Config].

end_per_group(Group, _Config) 
  when Group == tutorial;
       Group == metadata;
       Group == security;
       Group == compressed;
       Group == authenticated;
       Group == security_issues ->
    ok = grpc:stop_server(grpc);
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
     {group, tutorial},
     {group, metadata},
     {group, compressed},
     {group, security},
     {group, authenticated},
     {group, security_issues}
    ].

%%-------------------------------------------------------------------------
%% Test cases start here.
%%-------------------------------------------------------------------------

compile_routeguide_proto(_Config) ->
    ExampleDir = filename:join(code:lib_dir(grpc, examples), "route_guide"),
    ok = grpc:compile("route_guide.proto", [{i, ExampleDir}]),
    true = lists:all(fun (F) ->
                         filelib:is_file(F) 
                     end, 
                     ["route_guide.erl",
                      "route_guide_server.erl",
                      "route_guide_client.erl"
                      ]).

compile_routeguide_generated(_Config) ->
    true = lists:all(fun (F) ->
                         case compile:file(F) of
                             {ok, _} -> true;
                              _ -> false
                         end
                     end, 
                     ["route_guide.erl",
                      "route_guide_server.erl",
                      "route_guide_client.erl"
                     ]).

compile_routeguide_example(_Config) ->
    compile_example("route_guide_server_1.erl").

start_routeguide_server(Config) ->
    Port = port(Config),
    {ok, _} = grpc:start_server(grpc, route_guide_server_1, [{port, Port}]). 

run_getfeature(Config) ->
    process_flag(trap_exit, true),
    Port = port(Config),
    {ok, Connection} = grpc_client:connect(http, "localhost", Port),
    {ok, #{result := #{name := ?BVM_TRAIL}}} = feature(Connection,
                                                       ?BVM_TRAIL_POINT).
getfeature_client(Config) ->
    Port = port(Config),
    {ok, Connection} = grpc_client:connect(http, "localhost", Port),
    {ok, #{result := #{name := ?BVM_TRAIL}}} =
        route_guide_client:'GetFeature'(Connection, ?BVM_TRAIL_POINT, []).

getfeature_compressed_request(Config) ->
    Port = port(Config),
    {ok, Connection} = grpc_client:connect(http, "localhost", Port),
    {ok, #{result := #{name := ?BVM_TRAIL}}} = 
        feature(Connection,
                ?BVM_TRAIL_POINT,
                [{compression, gzip},
                 %% Note: the metadata below does not acutally 
                 %% do anything, but it makes this request
                 %% recognizable on the server side. 
                 {metadata, #{<<"compressed">> => <<"true">>}}]).

getfeature_compressed_response(Config) ->
    Port = port(Config),
    {ok, Connection} = grpc_client:connect(http, "localhost", Port),
    {ok, #{result := #{name := ?BVM_TRAIL}}} = 
        feature(Connection,
                ?BVM_TRAIL_POINT,
                [
                 %% Note: the metadata below is used to 
                 %% tell the server to compress the resonse.
                 %% This is a feature of the example server, in general
                 %% grpc does not offer a way to instruct the server
                 %% to compress response messages.
                 %%
                 %% Note also that the test does not check whether
                 %% compression actually happened, this can be checked
                 %% in wireshark.
                 {metadata, #{<<"compression">> => <<"true">>}}]).

run_listfeatures(Config) ->
    process_flag(trap_exit, true),
    Port = port(Config),
    {ok, Connection} = grpc_client:connect(http, "localhost", Port),
    {ok, Stream} = grpc_client:new_stream(Connection, 'RouteGuide', 
                                            'ListFeatures', route_guide),
    P1 = #{latitude => 1, longitude => 2}, 
    P2 = #{latitude => 3, longitude => 5},
    ok = grpc_client:send_last(Stream, #{hi => P1, lo => P2}),
    %% A little bit of time will pass before the response arrives...
    timer:sleep(500),
    {headers,#{<<":status">> := <<"200">>}} = grpc_client:get(Stream),
    {data,#{location := #{latitude := 4,
                          longitude := 5}, 
            name := "Louvre"}} = grpc_client:get(Stream).

run_routechat(Config) ->
    {ok, Connection} = grpc_client:connect(http, "localhost", port(Config)),
    {ok, Stream} = grpc_client:new_stream(Connection, 'RouteGuide', 
                                            'RouteChat', route_guide),
    P1 = #{latitude => 1, longitude => 2}, 
    P2 = #{latitude => 3, longitude => 5},
    ok = grpc_client:send(Stream, #{location => P1, 
                                      message => "something about P1"}),
    ok = grpc_client:send(Stream, #{location => P2, 
                                      message => "something about P2"}),
    timer:sleep(500),
    empty = grpc_client:get(Stream),
    {error, timeout} = grpc_client:rcv(Stream, 10),
    ok = grpc_client:send(Stream, #{location => P1, 
                                      message => "more about P1"}),
    {headers,#{<<":status">> := <<"200">>}} = grpc_client:rcv(Stream, 500),
    {data,#{location := #{latitude := 1,longitude := 2}, 
            message := "something about P1"}} = grpc_client:rcv(Stream, 500).

run_recordroute(Config) ->
    {ok, Connection} = grpc_client:connect(http, "localhost", port(Config)),
    {ok, Stream} = grpc_client:new_stream(Connection, 'RouteGuide', 
                                            'RecordRoute', route_guide),
    P1 = #{latitude => 1, longitude => 2}, 
    P2 = #{latitude => 3, longitude => 5},
    ok = grpc_client:send(Stream, P1),
    ok = grpc_client:send_last(Stream, P2),
    {headers,#{<<":status">> := <<"200">>}} = grpc_client:rcv(Stream, 500),
    {data, #{point_count := 2}} = grpc_client:rcv(Stream, 500).

compile_example_2(_Config) ->
    compile_example("route_guide_server_2.erl").

start_server_2(Config) ->
    {ok, _} = grpc:start_server(grpc, route_guide_server_2, [{port, port(Config)}]). 

metadata_from_client(Config) ->
    {ok, Connection} = grpc_client:connect(http, "localhost", port(Config)),
    {ok, #{result := #{name := ?BVM_TRAIL}}} = 
        feature(Connection,
                ?BVM_TRAIL_POINT,
                [{metadata, #{<<"password">> => <<"secret">>}}]).

binary_metadata_from_client(Config) ->
    {ok, Connection} = grpc_client:connect(http, "localhost", port(Config)),
    {ok, #{result := #{name := ?BVM_TRAIL}}} = 
        feature(Connection,
                ?BVM_TRAIL_POINT,
                [{metadata, #{<<"metadata-bin">> => <<1,2,3,4>>}}]).

binary_metadata_from_server(Config) ->
    {ok, Connection} = grpc_client:connect(http, "localhost", port(Config)),
    {ok, #{result := #{name := ?BVM_TRAIL},
           headers := #{<<"response-bin">> := <<1,2,3,4>>}}} = 
        feature(Connection,
                ?BVM_TRAIL_POINT,
                [{metadata, #{<<"metadata-bin-response">> => <<"true">>}}]).

header_overwrite(Config) ->
    {ok, Connection} = grpc_client:connect(http, "localhost", port(Config)),
    {error, #{error_type := grpc,
              grpc_status := 3,
              status_message := <<"invalid argument">>}} = 
        feature(Connection,
                ?BVM_TRAIL_POINT,
                [{metadata, #{<<"header_overwrite">> => <<"true">>,
                              <<":authority">> => <<"changed">>,
                              <<":scheme">> => <<"changed">>}}]).

error_response(Config) ->
    {ok, Connection} = grpc_client:connect(http, "localhost", port(Config)),
    {error, #{error_type := grpc,
              grpc_status := 7,
              status_message := <<"permission denied">>}} =
        feature(Connection,
                ?BVM_TRAIL_POINT,
                [{metadata, #{<<"password">> => <<"sekret">>}}]).

metadata_from_server(Config) ->
    {ok, Connection} = grpc_client:connect(http, "localhost", port(Config)),
    {ok, Stream} = grpc_client:new_stream(Connection, 'RouteGuide', 
                                            'ListFeatures', route_guide),
    P1 = #{latitude => 1, longitude => 2}, 
    P2 = #{latitude => 3, longitude => 5},
    ok = grpc_client:send_last(Stream, #{hi => P1, lo => P2}),
    %% A little bit of time will pass before the response arrives...
    timer:sleep(500),
    {headers,#{<<":status">> := <<"200">>,
               <<"info">> := <<"this is a test-implementation">>}} = 
        grpc_client:get(Stream),
    {data,#{location := #{latitude := 4,
                          longitude := 5}, 
            name := "Louvre"}} = grpc_client:get(Stream),
    {data, _} = grpc_client:get(Stream),
    {headers,#{<<"grpc-status">> := <<"0">>,
               <<"nr_of_points_sent">> := <<"2">>}} = 
        grpc_client:get(Stream),
    eof = grpc_client:get(Stream).

start_server_secure(Config) ->
    %% This will allow the client to use SSL and to ensure that it is indeed talking to 
    %% localhost.
    TlsOptions = [{certfile, certificate("localhost.crt")},
                  {keyfile, certificate("localhost.key")},
                  {cacertfile, certificate("My_Root_CA.crt")}],
    {ok, _} = grpc:start_server(grpc, route_guide_server_1, 
                                [{port, port(Config)},
                                 {tls_options, TlsOptions}]). 

secure_request(Config) ->
    process_flag(trap_exit, true),
    TlsOptions = [{verify_server_identity, true},
                  {cacertfile, certificate("My_Root_CA.crt")}],
    {ok, Connection} = grpc_client:connect(tls, "localhost", port(Config), TlsOptions),
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
    TlsOptions = [{verify, verify_peer},
                  {cacertfile, certificate("My_Root_CA.crt")}],
                  %%{verify_fun, {VerifyFun, []}}],
    {error, {tls_alert, "handshake failure"}} = 
        grpc_client:connect(tls, "localhost", port(Config), TlsOptions).

start_server_wrong_certificate(Config) ->
    %% Start the server with the certificate for "mydomain.com" rather
    %% than "localhost".
    TlsOptions = [{certfile, certificate("mydomain.com.crt")},
                  {keyfile, certificate("mydomain.com.key")},
                  {cacertfile, certificate("My_Root_CA.crt")}],
    {ok, _} = grpc:start_server(grpc, route_guide_server_1, 
                                [{port, port(Config)},
                                 {tls_options, TlsOptions}]). 

ssl_without_server_identification(Config) ->
    process_flag(trap_exit, true),
    TlsOptions = [{verify, verify_peer},
                  {fail_if_no_peer_cert, true},
                  {cacertfile, certificate("My_Root_CA.crt")}],
    {ok, Connection} = grpc_client:connect(tls, "localhost", port(Config), TlsOptions),
    {ok, #{result := #{name := ?BVM_TRAIL}}} = feature(Connection,
                                                       ?BVM_TRAIL_POINT).

invalid_peer_certificate(Config) ->
    %% Fails because the server uses the wrong certificate.
    TlsOptions = [{verify_server_identity, true},
                  {cacertfile, certificate("My_Root_CA.crt")}
                  ],
    {error, invalid_peer_certificate} = 
        grpc_client:connect(tls, "localhost", port(Config), TlsOptions).

start_server_authenticating(Config) ->
    process_flag(trap_exit, true),
    TlsOptions = [{certfile, certificate("localhost.crt")},
                  {keyfile, certificate("localhost.key")},
                  {cacertfile, certificate("My_Root_CA.crt")},
                  {fail_if_no_peer_cert, true},
                  {verify, verify_peer}],
    {ok, _} = grpc:start_server(grpc, route_guide_server_1, 
                                [{port, port(Config)},
                                 {client_cert_dir, client_cert_dir()},
                                 {tls_options, TlsOptions}]). 

authenticated_request(Config) ->
    process_flag(trap_exit, true),
    TlsOptions = [{certfile, certificate("127.0.0.1.crt")},
                  {keyfile, certificate("127.0.0.1.key")},
                  {cacertfile, certificate("My_Root_CA.crt")}],
    {ok, Connection} = grpc_client:connect(tls, "localhost", port(Config), TlsOptions),
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
    {ok, Connection} = grpc_client:connect(tls, "localhost", port(Config), TlsOptions),
    {error, #{error_type := grpc,
              grpc_status := 16}} =
        feature(Connection, ?BVM_TRAIL_POINT).

%%-----------------------------------------------------------------------------
%% Internal functions
%% ----------------------------------------------------------------------------
compile_example(File) ->
    ExampleDir = filename:join([code:lib_dir(grpc, examples), 
                                "route_guide",
                                "server"]),
    {ok, _} = compile:file(filename:join(ExampleDir, File)).

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

