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
        ,compile_routeguide_generated
        ,compile_routeguide_example
        ,start_routeguide_server
        ,run_getfeature
        ,getfeature_client
        ,run_listfeatures
        ,stop_stream
        ,run_routechat
        ,run_recordroute
        ,flow_control
        ]},
     {more_services, [sequence],
        [compile_hello_world
        ,start_server_4
        ,run_getfeature
        ,run_bonjour]},
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
     {h2_client, [sequence],
      [compile_example_3
       ,start_server_3
       ,receive_many_messages]},
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
        ]},
     {middlewares, [sequence],
        [compile_routeguide_middleware_example
        ,start_server_5
        ,getfeature_middlewares
        ]}
    ].

init_per_group(Group, Config) ->
    %%H2Client = grpc_client_chatterbox_adapter,
    H2Client = http2_client,
    Port = case Group of
               tutorial -> 10000;
               metadata -> 10000;
               compressed -> 10000;
               security -> 10000;
               authenticated -> 10000;
               security_issues -> 10000;
               _ -> 10000
           end,
    [{port, Port}, {server, Group}, {h2_client, H2Client} | Config].

end_per_group(Group, _Config)
  when Group == tutorial;
       Group == metadata;
       Group == more_services;
       Group == h2_client;
       Group == security;
       Group == compressed;
       Group == authenticated;
       Group == security_issues;
       Group == middlewares ->
    ok = grpc:stop_server(Group);
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
     {group, more_services},
     {group, metadata},
     {group, h2_client},
     {group, compressed},
     {group, security},
     {group, authenticated},
     {group, security_issues},
     {group, middlewares}
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

compile_routeguide_middleware_example(_Config) ->
    compile_example("route_guide_logging_middleware.erl").

start_routeguide_server(Config) ->
    Port = port(Config),
    Server = server(Config),
    Spec = #{'RouteGuide' => #{handler => route_guide_server_1}},
    {ok, _} = grpc:start_server(Server, tcp, Port, Spec, []).

run_getfeature(Config) ->
    Port = port(Config),
    {ok, Connection} = grpc_client:connect(tcp, "localhost", Port,
                                           [{http2_client, h2_client(Config)}]),
    {ok, #{result := #{name := ?BVM_TRAIL}}} = feature(Connection,
                                                       ?BVM_TRAIL_POINT).

run_bonjour(Config) ->
    Port = port(Config),
    {ok, Connection} = grpc_client:connect(tcp, "localhost", Port,
                                           [{http2_client, h2_client(Config)}]),
    {ok, #{result := #{message := "Bonjour, World"}}} =
        grpc_client:unary(Connection, #{name => "World"}, 'Greeter',
                          'SayHello', helloworld, []).

getfeature_client(Config) ->
    Port = port(Config),
    {ok, Connection} = grpc_client:connect(tcp, "localhost", Port, [{http2_client, h2_client(Config)}]),
    {ok, #{result := #{name := ?BVM_TRAIL}}} =
        route_guide_client:'GetFeature'(Connection, ?BVM_TRAIL_POINT, []).

getfeature_compressed_request(Config) ->
    Port = port(Config),
    {ok, Connection} = grpc_client:connect(tcp, "localhost", Port, [{http2_client, h2_client(Config)}]),
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
    {ok, Connection} = grpc_client:connect(tcp, "localhost", Port, [{http2_client, h2_client(Config)}]),
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

getfeature_middlewares(Config) ->
    false = filelib:is_file("route_guide_middleware_log"),
    Port = port(Config),
    {ok, Connection} = grpc_client:connect(tcp, "localhost", Port, [{http2_client, h2_client(Config)}]),
    {ok, #{result := #{name := ?BVM_TRAIL}}} = feature(Connection, ?BVM_TRAIL_POINT, []),
    true = filelib:is_file("route_guide_middleware_log").

run_listfeatures(Config) ->
    {ok, Connection} = grpc_client:connect(tcp, "localhost", port(Config), [{http2_client, h2_client(Config)}]),
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
    {ok, Connection} = grpc_client:connect(tcp, "localhost", port(Config), [{http2_client, h2_client(Config)}]),
    {ok, Stream} = grpc_client:new_stream(Connection, 'RouteGuide',
                                            'RouteChat', route_guide),
    timer:sleep(500),
    empty = grpc_client:get(Stream),
    P1 = #{latitude => 1, longitude => 2},
    P2 = #{latitude => 3, longitude => 5},
    ok = grpc_client:send(Stream, #{location => P1,
                                      message => "something about P1"}),
    ok = grpc_client:send(Stream, #{location => P2,
                                      message => "something about P2"}),
    empty = grpc_client:get(Stream),
    {error, timeout} = grpc_client:rcv(Stream, 10),
    ok = grpc_client:send(Stream, #{location => P1,
                                      message => "more about P1"}),
    {headers,#{<<":status">> := <<"200">>}} = grpc_client:rcv(Stream, 500),
    {data,#{location := #{latitude := 1,longitude := 2},
            message := "something about P1"}} = grpc_client:rcv(Stream, 500).

stop_stream(Config) ->
    {ok, Connection} = grpc_client:connect(tcp, "localhost", port(Config), [{http2_client, h2_client(Config)}]),
    {ok, Stream} = grpc_client:new_stream(Connection, 'RouteGuide',
                                            'RouteChat', route_guide),
    timer:sleep(500),
    empty = grpc_client:get(Stream),
    P1 = #{latitude => 1, longitude => 2},
    P2 = #{latitude => 3, longitude => 5},
    ok = grpc_client:send(Stream, #{location => P1,
                                      message => "something about P1"}),
    ok = grpc_client:send(Stream, #{location => P2,
                                      message => "something about P2"}),
    empty = grpc_client:get(Stream),
    {error, timeout} = grpc_client:rcv(Stream, 10),
    ok = grpc_client:send(Stream, #{location => P1,
                                      message => "more about P1"}),
    {headers,#{<<":status">> := <<"200">>}} = grpc_client:rcv(Stream, 500),
    ok = grpc_client:stop_stream(Stream).

run_recordroute(Config) ->
    {ok, Connection} = grpc_client:connect(tcp, "localhost", port(Config), [{http2_client, h2_client(Config)}]),
    {ok, Stream} = grpc_client:new_stream(Connection, 'RouteGuide',
                                            'RecordRoute', route_guide),
    P1 = #{latitude => 1, longitude => 2},
    P2 = #{latitude => 3, longitude => 5},
    ok = grpc_client:send(Stream, P1),
    ok = grpc_client:send_last(Stream, P2),
    {headers,#{<<":status">> := <<"200">>}} = grpc_client:rcv(Stream, 500),
    {data, #{point_count := 2}} = grpc_client:rcv(Stream, 500).

flow_control(Config) ->
    %% use RouteChat to send some big messages to the server, to see if flow control is working.
    {ok, Connection} = grpc_client:connect(tcp, "localhost", port(Config), [{http2_client, h2_client(Config)}]),
    {ok, Stream} = grpc_client:new_stream(Connection, 'RouteGuide',
                                            'RouteChat', route_guide),
    timer:sleep(500),
    P1 = #{latitude => 1, longitude => 2},
    ok = grpc_client:send(Stream, #{location => P1,
                                    message => "something about P1"}),
    %% We need to send more than 65535 bytes, because that is the window size
    send_10K_bytes(Stream, 8),
    %% Now trigger a response message by sending something more about P1
    ok = grpc_client:send(Stream, #{location => P1,
                                    message => "more about P1"}),
    {headers,#{<<":status">> := <<"200">>}} = grpc_client:rcv(Stream, 500),
    {data,#{location := #{latitude := 1,longitude := 2},
            message := "something about P1"}} = grpc_client:rcv(Stream, 500).

send_10K_bytes(Stream, N) ->
    Message = lists:flatten(["0123456789" || _ <- lists:seq(1, 1000)]),
    [send_big_message(Stream, Message, M) || M <- lists:seq(1, N)].

%% The messages must be about different points, otherwise we start getting
%% response messages (which we don't want).
send_big_message(Stream, Message, N) ->
    P = #{latitude => N, longitude => N},
    ok = grpc_client:send(Stream, #{location => P,
                                    message => Message}),
    %% allow the WINDOW_UPDATE message to arrive
    timer:sleep(500).

compile_hello_world(_Config) ->
    ExampleDir = filename:join(code:lib_dir(grpc, examples), "helloworld"),
    Server = filename:join([ExampleDir, "helloworld_server.erl"]),
    {ok, _} = compile:file(Server),
    ok = grpc:compile("helloworld.proto", [{i, ExampleDir}]),
    {ok, _} = compile:file("helloworld.erl").

compile_example_2(_Config) ->
    compile_example("route_guide_server_2.erl").

compile_example_3(_Config) ->
    compile_example("route_guide_server_3.erl").

start_server_2(Config) ->
    Server = server(Config),
    Spec = #{'RouteGuide' => #{handler => route_guide_server_2}},
    {ok, _} = grpc:start_server(Server, tcp, port(Config), Spec, []).

start_server_3(Config) ->
    Server = server(Config),
    Spec = #{'RouteGuide' => #{handler => route_guide_server_3}},
    {ok, _} = grpc:start_server(Server, tcp, port(Config), Spec, []).

start_server_4(Config) ->
    Server = server(Config),
    Spec = #{'RouteGuide' => #{handler => route_guide_server_1},
             'Greeter' => #{handler => helloworld_server,
                            handler_state => "Bonjour, "}},
    {ok, _} = grpc:start_server(Server, tcp, port(Config), Spec, []).

start_server_5(Config) ->

    Server = server(Config),
    Spec = #{'RouteGuide' => #{handler => route_guide_server_1}},
    Middlewares = [route_guide_logging_middleware, cowboy_router, cowboy_handler],
    {ok, _} = grpc:start_server(Server, tcp, port(Config), Spec, [{middlewares, Middlewares}]).

metadata_from_client(Config) ->
    {ok, Connection} = grpc_client:connect(tcp, "localhost", port(Config),
                                           [{http2_client, h2_client(Config)}]),
    {ok, #{result := #{name := ?BVM_TRAIL}}} =
        feature(Connection,
                ?BVM_TRAIL_POINT,
                [{metadata, #{<<"password">> => <<"secret">>}}]).

binary_metadata_from_client(Config) ->
    {ok, Connection} = grpc_client:connect(tcp, "localhost", port(Config), [{http2_client, h2_client(Config)}]),
    {ok, #{result := #{name := ?BVM_TRAIL}}} =
        feature(Connection,
                ?BVM_TRAIL_POINT,
                [{metadata, #{<<"metadata-bin">> => <<1,2,3,4>>}}]).

binary_metadata_from_server(Config) ->
    {ok, Connection} = grpc_client:connect(tcp, "localhost", port(Config), [{http2_client, h2_client(Config)}]),
    {ok, #{result := #{name := ?BVM_TRAIL},
           headers := #{<<"response-bin">> := <<1,2,3,4>>}}} =
        feature(Connection,
                ?BVM_TRAIL_POINT,
                [{metadata, #{<<"metadata-bin-response">> => <<"true">>}}]).

header_overwrite(Config) ->
    {ok, Connection} = grpc_client:connect(tcp, "localhost", port(Config), [{http2_client, h2_client(Config)}]),
    {error, #{error_type := grpc,
              grpc_status := 3,
              status_message := <<"invalid argument">>}} =
        feature(Connection,
                ?BVM_TRAIL_POINT,
                [{metadata, #{<<"header_overwrite">> => <<"true">>,
                              <<":authority">> => <<"changed">>,
                              <<":scheme">> => <<"changed">>}}]).

metadata_from_server(Config) ->
    {ok, Connection} = grpc_client:connect(tcp, "localhost", port(Config), [{http2_client, h2_client(Config)}]),
    {ok, Stream} = grpc_client:new_stream(Connection, 'RouteGuide',
                                            'ListFeatures', route_guide),
    P1 = #{latitude => 1, longitude => 2},
    P2 = #{latitude => 3, longitude => 5},
    ok = grpc_client:send_last(Stream, #{hi => P1, lo => P2}),
    %% A little bit of time will pass before the response arrives...
    timer:sleep(500),
    {headers,_} = grpc_client:get(Stream),
    {data,#{location := #{latitude := 4,
                          longitude := 5},
            name := "Louvre"}} = grpc_client:get(Stream),
    {data, _} = grpc_client:get(Stream),
    {headers,#{<<"grpc-status">> := <<"0">>,
               <<"nr_of_points_sent">> := <<"2">>}} =
        grpc_client:get(Stream),
    eof = grpc_client:get(Stream).

error_response(Config) ->
    {ok, Connection} = grpc_client:connect(tcp, "localhost", port(Config), [{http2_client, h2_client(Config)}]),
    {error, #{error_type := grpc,
              grpc_status := 7,
              status_message := <<"permission denied">>}} =
        feature(Connection,
                ?BVM_TRAIL_POINT,
                [{metadata, #{<<"password">> => <<"sekret">>}}]).

%% NOTE: this test may fail, depending on the order of events.
%% There will be a window update from the client to the server because of this
%% test. If this arrives "late", the server wil start buffering messages. It will
%% NOT buffer the final headers, so these may arrive at the client before some of the
%% data messages.
receive_many_messages(Config) ->
    {ok, Connection} = grpc_client:connect(tcp, "localhost", port(Config), [{http2_client, h2_client(Config)}]),
    Count = 35,
    Size = 10000,
    Sleep = 0, %% time for the server to wait between sending messages. If this is
                %% too small, the test may fail due to the problem described above.
    Options = [{metadata, #{<<"nr_of_points">> => integer_to_binary(Count),
                            <<"sleep">> => integer_to_binary(Sleep),
                            <<"size">> => integer_to_binary(Size)}}],
    {ok, Stream} = grpc_client:new_stream(Connection, 'RouteGuide',
                                          'ListFeatures', route_guide, Options),
    P1 = #{latitude => 1, longitude => 2},
    P2 = #{latitude => 3, longitude => 5},
    ok = grpc_client:send_last(Stream, #{hi => P1, lo => P2}),
    %% A little bit of time will pass before the response arrives...
    {headers, _} = grpc_client:rcv(Stream, 500),
    %% Results = [grpc_client:get(Stream) || _ <- lists:seq(1, Count + 2)],
    lists:foreach(fun (_C) ->
                      {data, _} = grpc_client:rcv(Stream, 100)
                  end, lists:seq(1, Count)),
    {headers, _} = grpc_client:rcv(Stream, 100),
    eof = grpc_client:get(Stream).


start_server_secure(Config) ->
    %% This will allow the client to use SSL and to ensure that it is indeed talking to
    %% localhost.
    Server = server(Config),
    SslOptions = [{certfile, certificate("localhost.crt")},
                  {keyfile, certificate("localhost.key")},
                  {cacertfile, certificate("My_Root_CA.crt")}],
    Spec = #{'RouteGuide' => #{handler => route_guide_server_1}},
    {ok, _} = grpc:start_server(Server, ssl, port(Config), Spec,
                                [{transport_options, SslOptions}]).

secure_request(Config) ->
    Options = [{verify_server_identity, true}, {http2_client, h2_client(Config)},
               {transport_options, [{cacertfile, certificate("My_Root_CA.crt")}]}],
    {ok, Connection} = grpc_client:connect(ssl, "localhost", port(Config), Options),
    {ok, #{result := #{name := ?BVM_TRAIL}}} = feature(Connection,
                                                       ?BVM_TRAIL_POINT).
tls_connection_fails(Config) ->
    %% Fails because the client does not provide a certificate
    %%VerifyFun = fun(Certificate, Event, []) ->
                    %%ct:pal("Certificate: ~p~nEvent: ~p~n",
                           %%[Certificate, Event]),
                    %%{valid, []}
                %%end,
    Options = [{http2_client, h2_client(Config)},
               {transport_options, [{cacertfile, certificate("My_Root_CA.crt")}]}],
    {error, {tls_alert, "handshake failure"}} =
        grpc_client:connect(ssl, "localhost", port(Config), Options).

start_server_wrong_certificate(Config) ->
    %% Start the server with the certificate for "mydomain.com" rather
    %% than "localhost".
    Server = server(Config),
    TlsOptions = [{certfile, certificate("mydomain.com.crt")},
                  {keyfile, certificate("mydomain.com.key")},
                  {cacertfile, certificate("My_Root_CA.crt")}],
    Spec = #{'RouteGuide' => #{handler => route_guide_server_1}},
    {ok, _} = grpc:start_server(Server, ssl, port(Config), Spec,
                                [{transport_options, TlsOptions}]).

ssl_without_server_identification(Config) ->
    Options = [{http2_client, h2_client(Config)},
               {transport_options, [{cacertfile, certificate("My_Root_CA.crt")}]}],
    %%TlsOptions = [{verify, verify_peer},
                  %%{fail_if_no_peer_cert, true},
                  %%{cacertfile, certificate("My_Root_CA.crt")}],
    {ok, Connection} = grpc_client:connect(ssl, "localhost", port(Config), Options),
    {ok, #{result := #{name := ?BVM_TRAIL}}} = feature(Connection,
                                                       ?BVM_TRAIL_POINT).

invalid_peer_certificate(Config) ->
    %% Fails because the server uses the wrong certificate.
    Options = [{verify_server_identity, true}, {http2_client, h2_client(Config)},
               {transport_options, [{cacertfile, certificate("My_Root_CA.crt")}]}],
    {error, invalid_peer_certificate} =
        grpc_client:connect(ssl, "localhost", port(Config), Options).

start_server_authenticating(Config) ->
    Server = server(Config),
    TlsOptions = [{certfile, certificate("localhost.crt")},
                  {keyfile, certificate("localhost.key")},
                  {cacertfile, certificate("My_Root_CA.crt")},
                  {fail_if_no_peer_cert, true},
                  {verify, verify_peer}],
    Spec = #{'RouteGuide' => #{handler => route_guide_server_1}},
    {ok, _} = grpc:start_server(Server, ssl, port(Config), Spec,
                                [{client_cert_dir, client_cert_dir()},
                                 {http2_client, h2_client(Config)},
                                 {transport_options, TlsOptions}]).

authenticated_request(Config) ->
    Options = [{http2_client, h2_client(Config)},
               {transport_options, [{certfile, certificate("127.0.0.1.crt")},
                                    {keyfile, certificate("127.0.0.1.key")},
                                    {cacertfile, certificate("My_Root_CA.crt")}]}],
    {ok, Connection} = grpc_client:connect(ssl, "localhost", port(Config), Options),
    {ok, #{result := #{name := ?BVM_TRAIL}}} = feature(Connection,
                                                       ?BVM_TRAIL_POINT).
wrong_client_certificate(Config) ->
    %% Provide a certificate that is not in the list of certificates
    %% that is accepted by the server. (Reusing "localhost" for that
    %% purpose).
    Options = [{http2_client, h2_client(Config)},
               {transport_options, [{certfile, certificate("localhost.crt")},
                                    {keyfile, certificate("localhost.key")},
                                    {cacertfile, certificate("My_Root_CA.crt")}]}],
    {ok, Connection} = grpc_client:connect(ssl, "localhost", port(Config), Options),
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

server(Config) ->
    proplists:get_value(server, Config).

h2_client(Config) ->
    proplists:get_value(h2_client, Config).
