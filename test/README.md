# Testing 

The examples below assume that $GRPC_ROOT is set to the directory that
contains the grpc repository, and $GO_BIN is the directory that contains
the go client and server executables. (`$> export GO_BIN=...`).

## Common test

The test suite `grpc_SUITE.erl` can be executed using erlang.mk:

```
make ct
```

## Testing against the GO implementation

To test the Erlang implementation against the reference implementation in
go, install the go examples:

```
go install google.golang.org\grpc\examples\route_guide\client
go install google.golang.org\grpc\examples\route_guide\server
```

### Testing the Erlang client against the go server

- start the go server without any arguments: `$GO_BIN/server`.
- run the "test_grpc_client":

```
$> make shell
1> cd("test").
2> c(test_grpc_client).
3> test_grpc_client:run(tcp). %% run a test without ssl
```

_To test with tls:_
- stop the go server (^C)
- start the go server again, this time with tls: 

```
$> $GO_BIN/server -tls -cert_file $GRPC_ROOT/test/certificates/server1.pem -key_file $GRPC_ROOT/test/certificates/server1.key -json_db_file $GRPC_ROOT/test/testdata/route_guide_db.json
```

Run the test client with the tls option:

```
4> test_grpc_client:run(tls).
```

### Testing the Erlang server against the go client

Start the Erlang server (without tls):

```
$> make shell
1> cd(test).
2> c(test_grpc_server).
3> test_grpc_server:run(tcp).
```

Run the go client:

```
$> $GO_BIN/client
```

To test with ssl:

```
4> test_grpc_server:stop().
5> test_grpc_server:run(ssl).
```

Tun the go client with ssl:
$> $GO_BIN/client -tls -ca_file $GRPC_ROOT/test/certificates/My_Root_CA.crt -server_host_override localhost
