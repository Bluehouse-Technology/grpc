# gRPC

An implementation of gRPC in Erlang.

## Build
gRPC uses [erlang.mk](https://erlang.mk/) as build tool. On Unix systems it can be built
with: 

```
make
```

`make doc` can be used to generate documentation for the individual
modules from edoc comments in thos modules.

See the [erlang.mk documentation](https://erlang.mk/guide/installation.html#_on_windows) for
an explanation on how the tool can be used in a Windows environment.

## Testing
`make ct` can be used to run a number of tests. 

In the test directory there is an explanation how the software can be
tested against the go grpc implementation.

## Dependencies

- [gpb](https://github.com/tomas-abrahamsson/gpb) is used to encode and
  decode the protobuf messages.

- [cowboy](https://github.com/willemdj/cowboy) is used for the server.
  This is a fork with some changes to the support for HTTP/2.

- [chatterbox](https://github.com/willemdj/chatterbox) is used for the
  client. This is also a fork with a couple of modifications related to missing
  HTTP/2 features.

## gRPC functionality

[tutorial](/doc/tutorial.md)

## Acknowledgements

The development of this application was championed by [Holger Winkelmann](https://github.com/hwinkel) of [Travelping](https://github.com/travelping). [Travelping](https://github.com/travelping) also kindly provided sponsorship for the initial development. The development was primarily done by [Willem de Jong](https://github.com/willemdj) with design input from [Chandru Mullaparthi](https://github.com/cmullaparthi).

## License

Apache 2.0

