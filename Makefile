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

LOAD_TEST_NUM_WORKERS=200
LOAD_TEST_NUM_REQS_PER_WORKER=1000

grpc_load_test: test-deps start_test_server run_grpc_load_test stop_test_server
rpc_load_test: test-deps start_test_server run_rpc_load_test stop_test_server

start_test_server:
	@echo "Starting test server..."
	@cd test && erlc run_load_test.erl && erlc statistics.erl && \
	erlc statistics_server.erl && cd ..
	@erl -sname grpc_test_server@localhost -pa $(SHELL_PATHS) -pz test -s run_load_test start_grpc_server -detached

stop_test_server:
	@echo "Stopping test server..."
	@erl -sname erpc_test_node_killer -noinput +B \
	-eval 'rpc:async_call(grpc_test_server@localhost, erlang, halt, []), timer:sleep(1000), erlang:halt().'

run_grpc_load_test:
	@echo "Starting grpc test client..."
	@cd test && erlc run_load_test.erl && erlc statistics.erl && \
	erlc statistics_client.erl && cd ..
	erl -sname grpc_test_client -pa $(SHELL_PATHS) -pz test -s run_load_test start_client -- \
	-num_workers ${LOAD_TEST_NUM_WORKERS} \
	-server localhost \
	-num_requests_per_worker ${LOAD_TEST_NUM_REQS_PER_WORKER} \
	-rpc_type grpc

run_rpc_load_test:
	@echo "Starting native rpc test client..."
	@cd test && erlc run_load_test.erl && erlc statistics.erl && \
	erlc statistics_client.erl && cd ..
	erl -sname grpc_test_client -pa $(SHELL_PATHS) -pz test -s run_load_test start_client -- \
	-num_workers ${LOAD_TEST_NUM_WORKERS} \
	-server grpc_test_server@localhost \
	-num_requests_per_worker ${LOAD_TEST_NUM_REQS_PER_WORKER} \
	-rpc_type native
