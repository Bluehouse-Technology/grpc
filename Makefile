PROJECT = grpc
PROJECT_DESCRIPTION = gRPC in Erlang
PROJECT_VERSION = 0.1.0

# Whitespace to be used when creating files from templates.
SP = 4

DEPS = gpb cowboy chatterbox
dep_cowboy = git https://github.com/willemdj/cowboy
dep_chatterbox = git https://github.com/willemdj/chatterbox
include erlang.mk
