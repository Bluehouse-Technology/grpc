%%
%% @doc This is the interface for grpc client side functions.
%%
-module(grpc_client).

-export([connect/3, connect/4,
         new_stream/4, new_stream/5,
         send/2, send_last/2,
         unary/6,
         rcv/1, rcv/2,
         get/1,
         stop_stream/1,
         stop_connection/1]).

-type tls_option()     :: ranch_ssl:ssl_opt() | 
                          {verify_server_identity, boolean()} |
                          {server_host_override, string()}.
-type connection()     :: grpc_cl_connection:connection().
-type stream_option()  :: {metadata, grpc:metadata()} |
                          {compression, grpc:compression_method()}.
-type client_stream()  :: pid().
-type rcv_response()   :: {data, map()} | 
                          {headers, gprc:metadata()} |
                          eof | {error, term()}.
-type get_response()   :: rcv_response() | empty.

-type unary_response(Type) :: 
                          {ok, #{result := Type,
                                 status_message := binary(),
                                 http_status := 200,
                                 grpc_status := 0,
                                 headers := grpc:metadata(),
                                 trailers := grpc:metadata()}} |
                          {error, #{error_type := client | timeout | 
                                                  http | grpc,
                                    http_status => integer(),
                                    grpc_status => integer(),
                                    status_message => binary(),
                                    headers => grpc:metadata(),
                                    result => Type,
                                    trailers => grpc:metadata()}}.

-export_type([connection/0,
              stream_option/0,
              client_stream/0,
              unary_response/1,
              tls_option/0]).

-spec connect(Transport::http | tls,
              Host::string(),
              Port::integer()) -> {ok, connection()} | {error, term()}.
%% @equiv connect(Transport, Host, Port, []).
connect(Transport, Host, Port) ->
    connect(Transport, Host, Port, []).

-spec connect(Transport::http | tls,
              Host::string(),
              Port::integer(),
              Options::[tls_option()]) -> {ok, connection()}.
%% @doc Start a connection to a gRPC server.
%%
%% If 'verify_server_identity' is true, the client will check that the
%% subject of the certificate received from the server is identical to Host.
%%
%% If it is known that the server returns a certificate with another subject
%% than the host name, the 'server_host_override' option can be used to 
%% specify that other subject.
connect(Transport, Host, Port, Options) ->
    grpc_cl_connection:new(Transport, Host, Port, Options).

-spec new_stream(Connection::connection(), 
                 Service::atom(), 
                 Rpc::atom(), 
                 DecoderModule::module()) -> {ok, client_stream()}.
%% @equiv new_stream(Connection, Service, Rpc, DecoderModule, []) 
new_stream(Connection, Service, Rpc, DecoderModule) ->
    new_stream(Connection, Service, Rpc, DecoderModule, []).

-spec new_stream(Connection::connection(), 
                 Service::atom(), 
                 Rpc::atom(), 
                 DecoderModule::module(),
                 Options::[stream_option()]) -> {ok, client_stream()}.
%% @doc Create a new stream to start a new RPC.
new_stream(Connection, Service, Rpc, DecoderModule, Options) ->
    grpc_cl_stream:new(Connection, Service, Rpc, DecoderModule, Options).

-spec send(Stream::client_stream(), Msg::map()) -> ok.
%% @doc Send a message from the client to the server.
send(Stream, Msg) when is_pid(Stream),
                       is_map(Msg) ->
    grpc_cl_stream:send(Stream, Msg).

-spec send_last(Stream::client_stream(), Msg::map()) -> ok.
%% @doc Send a message to server and mark it as the last message 
%% on the stream. For simple RPC and client-streaming RPCs that 
%% should trigger the response from the server.
send_last(Stream, Msg) when is_pid(Stream),
                            is_map(Msg) ->
    grpc_cl_stream:send_last(Stream, Msg).

-spec rcv(Stream::client_stream()) -> rcv_response().
%% @equiv rcv(Stream, infinity)
rcv(Stream) ->
    grpc_cl_stream:rcv(Stream).
   
-spec rcv(Stream::client_stream(), Timeout::timeout()) -> rcv_response().
%% @doc Receive a message from the server. This is a blocking 
%% call, it returns when a message has been received or after Timeout.
%% Timeout is in milliseconds.
%%
%% Returns 'eof' after the last message from the server has been read.
rcv(Stream, Timeout) ->
    grpc_cl_stream:rcv(Stream, Timeout).
     
-spec get(Stream::client_stream()) -> get_response().
%% @doc Get a message from the stream, if there is one in the queue. If not return 
%% `empty`. This is a non-blocking call.
%%
%% Returns 'eof' after the last message from the server has been read.
get(Stream) ->
    grpc_cl_stream:get(Stream).

-spec stop_stream(Stream::client_stream()) -> ok.
%% @doc Stop a stream and clean up.
stop_stream(Stream) ->
    grpc_cl_stream:stop(Stream).

-spec stop_connection(Connection::connection()) -> ok.
%% @doc Stop a connection and clean up.
stop_connection(Connection) ->
    grpc_cl_connection:stop(Connection).

-spec unary(Connection::connection(),
            Message::map(), Service::atom(), Rpc::atom(),
            Decoder::module(),
            Options::[stream_option() |
                      {timeout, timeout()}]) -> unary_response(map()).
%% @doc Call a unary rpc in one go.
%%
%% Set up a stream, receive headers, message and trailers, stop
%% the stream and assemble a response. This is a blocking function.
unary(Connection, Message, Service, Rpc, Decoder, Options) ->
    {Timeout, StreamOptions} = grpc_lib:keytake(timeout, Options, infinity),
    try
        {ok, Stream} = new_stream(Connection, Service,
                                  Rpc, Decoder, StreamOptions),
        Response = grpc_cl_stream:call_rpc(Stream, Message, Timeout),
        stop_stream(Stream),
        Response
    catch
        _:_Error ->
            {error, #{error_type => client,
                      status_message => <<"error creating stream">>}}
    end.
