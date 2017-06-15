%% Can be used to test the Erlang server implementation against the 
%% go client
%%
%% The go example client can be found here:
%% https://github.com/grpc/grpc-go/blob/master/examples/route_guide/client/client.go
%%
%% To run the test:
%%
%% Start the Erlang server (without tls):
%%
%% $> make shell
%% 1> cd(test).
%% 2> c(test_grpc_server).
%% 3> test_grpc_server(http).
%%
%% Run the go client:
%%
%% $> $GO_BIN/client
%%
%% To test with ssl:
%%
%% 4> test_grpc_server(tls).
%%
%% Tun the go client with ssl:
%% $> $GO_BIN/client -tls -ca_file $GRPC_ROOT/test/certificates/My_Root_CA.crt -server_host_override localhost

-module(test_grpc_server).

-export([run/1, stop/0]).

-spec run(http|tls|authenticated) -> ok.
run(How) ->
    compile(),
    {ok, _} = compile:file(filename:join(test_dir(),
                                         "test_route_guide_server.erl")),
    {ok, _} = e_grpc:start_server(grpc, test_route_guide_server, options(How)). 

stop() ->
    e_grpc:stop_server(grpc).

options(How) ->
    [{port, 10000} | tls_options(How)].

tls_options(http) ->
    [];
tls_options(tls) ->
    [{tls_options, 
      [{certfile, certificate("localhost.crt")},
       {keyfile, certificate("localhost.key")},
       {cacertfile, certificate("My_Root_CA.crt")}]}].

compile() ->
    ok = e_grpc:compile("route_guide.proto", [{i, example_dir()}]),
    {ok, _} = compile:file("route_guide.erl").

example_dir() ->
    filename:join(code:lib_dir(e_grpc, examples), "route_guide").

test_dir() ->
    code:lib_dir(e_grpc, test).

certificate(FileName) ->
    R = filename:join([test_dir(), "certificates", FileName]),
    true = filelib:is_file(R),
    R.
