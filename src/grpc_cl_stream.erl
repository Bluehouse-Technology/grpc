%% @doc An a-synchronous client with a queue-like interface.
%% A gen_server is started for each stream, this keeps track
%% of the status of the connection and it buffers responses in a queue.
-module(grpc_cl_stream).

-behaviour(gen_server).

-export([new/5, 
         send/2, send_last/2,
         get/1, rcv/1, rcv/2, 
         call_rpc/3,
         stop/1]).

%% gen_server behaviors
-export([code_change/3, handle_call/3, handle_cast/2, handle_info/2, init/1, terminate/2]).

-spec new(Connection::pid(),
          Service::atom(),
          Rpc::atom(),
          Encoder::module(),
          Options::list()) -> {ok, Pid::pid()} | {error, Reason::term()}.
new(Connection, Service, Rpc, Encoder, Options) ->
    gen_server:start_link(?MODULE, 
                          {Connection, Service, Rpc, Encoder, Options}, []).

send(Pid, Message) ->
    gen_server:call(Pid, {send, Message}).

send_last(Pid, Message) ->
    gen_server:call(Pid, {send_last, Message}).

get(Pid) ->
    gen_server:call(Pid, get).

rcv(Pid) ->
    rcv(Pid, infinity).

rcv(Pid, Timeout) ->
    gen_server:call(Pid, {rcv, Timeout}, infinity).

-spec stop(Stream::pid()) -> ok.
%% @doc Close (stop/clean up) the stream.
stop(Pid) ->
    gen_server:stop(Pid).

%% @doc Call a unary rpc and process the response.
call_rpc(Pid, Message, Timeout) ->
    try send_last(Pid, Message) of
        ok ->
            process_response(Pid, Timeout)
    catch
        _:_ ->
            {error, #{error_type => client,
                      status_message => <<"failed to encode and send message">>}}
    end.

%% gen_server implementation
init({Connection, Service, Rpc, Encoder, Options}) ->
    try 
        {ok, new_stream(Connection, Service, Rpc, Encoder, Options, [])}
    catch
        _:_ ->
            {stop, <<"failed to create stream">>}
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_call({send_last, Message}, _From, Stream) ->
    {reply, ok, send_msg(Stream, Message, [{send_end_stream, true}])};
handle_call({send, Message}, _From, Stream) ->
    {reply, ok, send_msg(Stream, Message, [{send_end_stream, false}])};
handle_call(get, _From, #{queue := Queue,
                          state := StreamState} = Stream) ->
    {Value, NewQueue} = queue:out(Queue),
    Response = case {Value, StreamState} of
                   {{value, V}, _} ->
                       V;
                   {empty, closed} ->
                       eof;
                   {empty, open} ->
                       empty
               end,
    {reply, Response, Stream#{queue => NewQueue}};
handle_call({rcv, Timeout}, From, #{queue := Queue,
                                    state := StreamState} = Stream) ->
    {Value, NewQueue} = queue:out(Queue),
    NewStream = Stream#{queue => NewQueue},
    case {Value, StreamState} of
        {{value, V}, _} ->
            {reply, V, NewStream};
        {empty, closed} ->
            {reply, eof, NewStream};
        {empty, open} ->
            {noreply, NewStream#{client => From,
                                 response_pending => true}, Timeout}
    end.

handle_cast(_, State) ->
    {noreply, State}.

handle_info({'RECV_DATA', StreamId, Bin}, 
            #{stream_id := StreamId} = Stream) ->
    Response = try 
                   {data, decode(Stream, Bin)}
               catch
                  throw:{error, Message} ->
                       {error, Message};
                   _Error:_Message ->
                       {error, <<"failed to decode message">>}
               end,
    info_response(Response, Stream);
handle_info({'RECV_HEADERS', StreamId, Headers},
            #{stream_id := StreamId} = Stream) ->
    HeadersMap = maps:from_list([grpc_lib:maybe_decode_header(H) 
                                 || H <- Headers]),
    Encoding = maps:get(<<"grpc-encoding">>, HeadersMap, none),
    info_response({headers, HeadersMap}, 
                  Stream#{response_encoding => Encoding});
handle_info({'END_STREAM', StreamId},
            #{stream_id := StreamId} = Stream) ->
    info_response(eof, Stream#{state => closed});
handle_info(timeout, #{response_pending := true,
                       client := Client} = Stream) ->
    gen_server:reply(Client, {error, timeout}),
    {noreply, Stream#{response_pending => false}};
handle_info(_InfoMessage, Stream) ->
    {noreply, Stream}.

terminate(_Reason, #{connection := Connection,
                     stream_id := StreamId}) ->
    grpc_cl_connection:stop_stream(Connection, StreamId).

%% private methods
new_stream(Connection, Service, Rpc, Encoder, Options, HandlerState) ->
    Compression = proplists:get_value(compression, Options, none),
    Metadata = proplists:get_value(metadata, Options, #{}),
    StreamId = grpc_cl_connection:new_stream(Connection),
    Package = Encoder:get_package_name(),
    RpcDef = Encoder:find_rpc_def(Service, Rpc),
    %% the gpb rpc def has 'input', 'output' etc.
    %% All the information is combined in 1 map, 
    %% which is is the state of the gen_server.
    RpcDef#{stream_id => StreamId,
            package => [atom_to_list(Package),$.],
            service => Service,
            rpc => Rpc,
            queue => queue:new(),
            response_pending => false,
            state => open,
            encoder => Encoder,
            connection => Connection,
            headers_sent => false,
            handler_state => HandlerState,
            metadata => Metadata,
            compression => Compression}.

send_msg(#{stream_id := StreamId,
           connection := Connection,
           headers_sent := HeadersSent,
           metadata := Metadata
          } = Stream, Message, Opts) ->
    Encoded = encode(Stream, Message),
    case HeadersSent of
        false ->
            DefaultHeaders = default_headers(Stream),
            AllHeaders = add_metadata(DefaultHeaders, Metadata),
            grpc_cl_connection:send_headers(Connection, StreamId, AllHeaders);
        true ->
            ok
    end,
    grpc_cl_connection:send_body(Connection, StreamId, Encoded, Opts),
    Stream#{headers_sent => true}.

default_headers(#{service := Service,
                  rpc := Rpc,
                  package := Package,
                  compression := Compression,
                  connection := #{host := Host,
                                  scheme := Scheme}
                 }) ->
    Path = iolist_to_binary(["/", Package, atom_to_list(Service),
                             "/", atom_to_list(Rpc)]),
    Headers1 = case Compression of
                   none ->
                       [];
                   _ ->
                       [{<<"grpc-encoding">>,
                         atom_to_binary(Compression, unicode)}]
               end,
    [{<<":method">>, <<"POST">>},
     {<<":scheme">>, Scheme},
     {<<":path">>, Path},
     {<<":authority">>, Host},
     {<<"content-type">>, <<"application/grpc+proto">>},
     {<<"user-agent">>, <<"chatterbox-client/0.0.1">>},
     {<<"te">>, <<"trailers">>} | Headers1].

add_metadata(Headers, Metadata) ->
    lists:foldl(fun(H, Acc) -> 
                        {K, V} = grpc_lib:maybe_encode_header(H),
                        %% if the key exists, replace it.
                        lists:keystore(K, 1, Acc, {K,V})
                end, Headers, maps:to_list(Metadata)).

info_response(Response, #{response_pending := true,
                          client := Client} = Stream) ->
    gen_server:reply(Client, Response),
    {noreply, Stream#{response_pending => false}};
info_response(Response, #{queue := Queue} = Stream) ->
    NewQueue = queue:in(Response, Queue),
    {noreply, Stream#{queue => NewQueue}}.

%% TODO: fix the error handling, currently it is very hard to understand the
%% error that results from a bad message (Map).
encode(#{encoder := Encoder,
         input := MsgType,
         compression := CompressionMethod}, Map) ->
    %% RequestData = Encoder:encode_msg(Map, MsgType),
    try Encoder:encode_msg(Map, MsgType) of
        RequestData ->
            maybe_compress(RequestData, CompressionMethod)
    catch
        error:function_clause ->
          throw({error, {failed_to_encode, MsgType, Map}});
        Error:Reason ->
          throw({error, {Error, Reason}})
    end.

maybe_compress(Encoded, none) ->
    Length = byte_size(Encoded),
    <<0, Length:32, Encoded/binary>>;
maybe_compress(Encoded, gzip) ->
    Compressed = zlib:gzip(Encoded),
    Length = byte_size(Compressed),
    <<1, Length:32, Compressed/binary>>;
maybe_compress(_Encoded, Other) ->
    throw({error, {compression_method_not_supported, Other}}).

decode(#{response_encoding := Method,
         encoder := Encoder,
         output := MsgType}, Binary) ->
    Message = maybe_decompress(Binary, Method),
    Encoder:decode_msg(Message, MsgType).

maybe_decompress(<<0, _Size:32, Message/binary>>, none) ->
    Message;
maybe_decompress(<<1, _Size:32, Message/binary>>, <<"gzip">>) ->
    zlib:gunzip(Message);
maybe_decompress(<<1, _Size:32, _Message/binary>>, Other) ->
    throw({error, {decompression_method_not_supported, Other}}).

process_response(Pid, Timeout) ->
    case rcv(Pid, Timeout) of
        {headers, #{<<":status">> := <<"200">>,
                    <<"grpc-status">> := GrpcStatus} = Trailers}
          when GrpcStatus /= <<"0">> ->
            %% "trailers only" response.
            grpc_response(#{}, #{}, Trailers);
        {headers, #{<<":status">> := <<"200">>} = Headers} ->
            get_message(Headers, Pid, Timeout);
        {headers, #{<<":status">> := HttpStatus} = Headers} ->
            {error, #{error_type => http,
                      status => {http, HttpStatus},
                      headers => Headers}};
        {error, timeout} ->
            {error, #{error_type => timeout}}
    end.

get_message(Headers, Pid, Timeout) ->
    case rcv(Pid, Timeout) of
        {data, Response} ->
            get_trailer(Response, Headers, Pid, Timeout);
        {headers, Trailers} ->
            grpc_response(Headers, #{}, Trailers);
        {error, timeout} ->
            {error, #{error_type => timeout,
                      headers => Headers}}
    end.

get_trailer(Response, Headers, Pid, Timeout) ->
    case rcv(Pid, Timeout) of
        {headers, Trailers} ->
            grpc_response(Headers, Response, Trailers);
        {error, timeout} ->
            {error, #{error_type => timeout,
                      headers => Headers,
                      result => Response}}
    end.

grpc_response(Headers, Response, #{<<"grpc-status">> := <<"0">>} = Trailers) ->
    StatusMessage = maps:get(<<"grpc-message">>, Trailers, <<"">>),
    {ok, #{status_message => StatusMessage,
           http_status => 200,
           grpc_status => 0,
           headers => Headers,
           result => Response,
           trailers => Trailers}};
grpc_response(Headers, Response, #{<<"grpc-status">> := ErrorStatus} = Trailers) ->
    StatusMessage = maps:get(<<"grpc-message">>, Trailers, <<"">>),
    {error, #{error_type => grpc,
              http_status => 200,
              grpc_status => binary_to_integer(ErrorStatus),
              status_message => StatusMessage,
              headers => Headers,
              result => Response,
              trailers => Trailers}}.
