PROJECT = grpc
PROJECT_DESCRIPTION = gRPC in Erlang
PROJECT_VERSION = 0.1.0

# Whitespace to be used when creating files from templates.
SP = 4

DEPS = cowboy grpc_lib
dep_cowboy = git https://github.com/willemdj/cowboy
dep_grpc_lib = git https://github.com/Bluehouse-Technology/grpc_lib

TEST_DEPS = grpc_client
dep_grpc_client = git https://github.com/Bluehouse-Technology/grpc_client

include erlang.mk
