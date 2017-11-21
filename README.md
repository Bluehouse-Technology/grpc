# gRPC

An implementation of a gRPC server in Erlang. 

An implementation of the client side is also available: [grpc_client](https://github.com/Bluehouse-Technology/grpc_client).

## A quick "Hello world" example

The file "helloworld.proto" contains the specification for a simple "hello
world" service:

```
syntax = "proto3";

package helloworld;

// The greeting service definition.
service Greeter {
  // Sends a greeting
  rpc SayHello (HelloRequest) returns (HelloReply) {}
}

// The request message containing the user's name.
message HelloRequest {
  string name = 1;
}

// The response message containing the greetings
message HelloReply {
  string message = 1;
}
```

Compile this file (from the Erlang shell):
```
1> grpc:compile("helloworld.proto").
```
This creates two files: `helloworld.erl`  and `helloworld_server.erl`. The
first file contains code to encode and decode the gRPC messages (in
protocol buffer format). The second file contains type specifications for
the messages and a 'skeleton' for the RPC:

```erlang
-spec 'SayHello'(Message::'HelloRequest'(), Stream::grpc:stream(), State::any()) ->
    {'HelloReply'(), grpc:stream()} | grpc:error_response().
%% This is a unary RPC
'SayHello'(_Message, Stream, _State) ->
    {#{}, Stream}.
```

Some code must be added to the skeleton to make it work:

```erlang
'SayHello'(#{name := Name}, Stream, _State) ->
    {#{message => "Hello, " ++ Name}, Stream}.
```
 
Now compile the modules and start the server (it will listen to port 10000):

```erlang
2> c(helloworld).
3> c(helloworld_server).
4> grpc:start_server(hello, tcp, 10000, helloworld_server, []).
``` 

To see if it actually works you will need a grpc client. These exist in
many languages (see [grpc.io](https://grpc.io)), but here we will use the
erlang client
([grpc_client](https://github.com/Bluehouse-Technology/grpc_client)):

```erlang
1> grpc_client:compile("helloworld.proto").
2> c(helloworld).
3> c(helloword_client).
4> {ok, Connection} = grpc_client:connect(tcp, "localhost", 10000).
4> helloworld_client:'SayHello'(Connection, #{name => "World"}, []).
{ok,#{grpc_status => 0,
      headers => #{<<":status">> => <<"200">>},
      http_status => 200,
      result => #{message => "Hello, World"},
      status_message => <<>>,
      trailers => #{<<"grpc-status">> => <<"0">>}}}
```

## Documentation 
There are many more things you can do beyond what is shown in the simple
example above - streaming from client to server,
from server to client, both ways, adding metadata, compression,
authentication ... - see the
[tutorial](/doc/tutorial.md) for more examples and further details, or the
[reference
documentation](https://github.com/Bluehouse-Technology/grpc/wiki/gRPC-reference-documentation)
for the details of the
individual modules and functions.

## Build
gRPC uses [erlang.mk](https://erlang.mk/) as build tool. On Unix systems it can be built
with: 

```
make
```

`make doc` can be used to generate documentation for the individual
modules from edoc comments in those modules.

See the [erlang.mk documentation](https://erlang.mk/guide/installation.html#_on_windows) for
an explanation on how the tool can be used in a Windows environment.

## Testing
`make ct` can be used to run a number of tests. 

In the test directory there is an explanation how the software can be
tested against the go gRPC implementation.

## Dependencies

- [cowboy](https://github.com/ninenines/cowboy) is used for the server.

- [gpb](https://github.com/tomas-abrahamsson/gpb) is used to encode and
  decode the protobuf messages. This is a 'build' dependency: gpb is
  required to create some modules from the .proto files, but the modules
  are self contained and don't have a runtime depedency on gpb.


## Acknowledgements

The development of this application was championed by [Holger Winkelmann](https://github.com/hwinkel) of [Travelping](https://github.com/travelping). [Travelping](https://github.com/travelping) also kindly provided sponsorship for the initial development. The development was primarily done by [Willem de Jong](https://github.com/willemdj) with design input from [Chandru Mullaparthi](https://github.com/cmullaparthi).

## License

Apache 2.0

