# gRPC

An implementation of a gRPC server and client in Erlang. HTTP/2 based RPC.

NOTE: The prototypes for this repository are from [Bluehouse-Technology/grpc](https://github.com/Bluehouse-Technology/grpc)
and [tsloughter/grpcbox](https://github.com/tsloughter/grpcbox)
Many thanks to these two repositories for helping me with the implementation :)

## TODOs

- [x] Unary RPC
- [x] Input streaming/ Output streaming/ Bidirectional streaming
- [x] Custom metadata
- [x] Https
- [ ] Encoding: identity, gzip, deflate, snappy
- [ ] Timeout, Error Handling
- [ ] Benchmark


## Installation

The application is built from rebar3, so you can introduce it in your
rebar.config.

In addition, you need to introduce `grpc_plugin` plugin to generate client-side
and server-side code from the `.proto` file.

So a regular rebar.config would look something like the following:

```erl
{plugins,
 [{grpc_plugin, {git, "https://github.com/HJianBo/grpc_plugin", {tag, "v0.10.1"}}}
]}.

{deps,
 [{grpc, {git, "https://github.com/emqx/grpc", {branch, "master"}}}
 ]}.

%% Configurations for grpc_plugin
{grpc,
 [ {type, all}
 , {protos, ["priv/"]}
 , {out_dir, "src/"}
 , {gpb_opts, []}  %% The gpb compile options, see: https://github.com/tomas-abrahamsson/gpb/blob/master/src/gpb_compile.erl#L120
 ]}.

%% Integrate grpc_plugin generation/clean into rebar3's complie/clean
{provider_hooks,
 [{pre, [{compile, {grpc, gen}},
         {clean, {grpc, clean}}]}
 ]}.
```

For more detailed examples, you can see the examples/route_guide project.

## Dependencies

- [cowboy](https://github.com/emqx/cowboy) is used for the server.
- [gun](https://github.com/emqx/gun) is used for the client.
- [gpb](https://github.com/tomas-abrahamsson/gpb) is used to encode and
  decode the protobuf messages. This is a 'build' dependency: gpb is
  required to create some modules from the .proto files, but the modules
  are self contained and don't have a runtime depedency on gpb.

## License

Apache 2.0

