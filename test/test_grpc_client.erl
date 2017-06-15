%% Can be used to test the Erlang client implementation against the 
%% go example.
%%
%% The go example can be found here:
%% https://github.com/grpc/grpc-go/blob/master/examples/route_guide/server/server.go
%%
%% To test without tls:
%% - start the go server without any arguments: `server`.
%% - run the "test_grpc_client":
%% 
%% $> make shell
%% 1> cd("test").
%% 2> c(test_grpc_client).
%% 3> test_grpc_client:run(http). %% run a test without ssl
%% 
%% To test with tls:
%% - stop the go server (^C)
%% - start the go server again, this time with tls: 
%% 
%% $> server -tls -cert_file $GRPC_ROOT/test/certificates/server1.pem -key_file $GRPC_ROOT/test/certificates/server1.key -json_db_file $GRPC_ROOT/test/testdata/route_guide_db.json
%% 
%% Run the test client with the tls option:
%% 
%% 4> test_grpc_client:run(tls).

-module(test_grpc_client).

-define(TIMEOUT, 500).
-define(NAME, "Patriots Path, Mendham, NJ 07945, USA").

-export([run/1]).

-spec run(http|tls|authenticated) -> ok.
run(How) ->
    compile(),
    SslOptions = ssl_options(How),
    %% Simplest case
    get_feature(transport(How), SslOptions, []).
%    %% Compressed message
%    get_feature([SslOptions], [{compression, gzip}]).

transport(P) ->
    P.

ssl_options(http) ->
    [];
ssl_options(tls) ->
    [{verify_server_identity, true},
     {cacertfile, certificate("ca.pem")},
     {server_host_override, "waterzooi.test.google.be"}].

get_feature(Transport, SslOptions, StreamOptions) ->
    {ok, Connection} = grpc_client:connect(Transport, "localhost", 
                                             10000, SslOptions),
    {ok, Stream} = grpc_client:new_stream(Connection, 'RouteGuide',
                                            'GetFeature', route_guide,
                                            StreamOptions),
    Point = #{latitude => 407838351, longitude => -746143763},
    ok = grpc_client:send_last(Stream, Point),
    {headers, #{<<":status">> := <<"200">>}} = grpc_client:rcv(Stream, ?TIMEOUT),
    {data, #{name := ?NAME}} = grpc_client:rcv(Stream, ?TIMEOUT),
    {headers, #{<<"grpc-status">> := <<"0">>}} = grpc_client:rcv(Stream, ?TIMEOUT),
    ok = grpc_client:stop_stream(Stream),
    ok = grpc_client:stop_connection(Connection).

compile() ->
    ok = grpc:compile("route_guide.proto", [{i, example_dir()}]),
    {ok, _} = compile:file("route_guide.erl").

example_dir() ->
    filename:join(code:lib_dir(grpc, examples), "route_guide").

test_dir() ->
    code:lib_dir(grpc, test).

certificate(FileName) ->
    R = filename:join([test_dir(), "certificates", FileName]),
    true = filelib:is_file(R),
    R.
