-module(grpc_client_lib).

-export([
         connect/4,
         send/2,
         send_last/2,
         decode/2,
         new_stream/6,
         stop_connection/1,
         call_rpc/3
        ]).

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

connect(Transport, Host, Port, Options) ->
    {ok, _} = application:ensure_all_started(chatterbox),
    H2Settings = chatterbox:settings(client),
    SslOptions = ssl_options(Options),
    ConnectResult = h2_connection:start_client_link(h2_transport(Transport), 
                                                    Host, Port,
                                                    SslOptions, H2Settings),
    case ConnectResult of
        {ok, Pid} ->
            verify_server(#{pid => Pid,
                            host => list_to_binary(Host),
                            scheme => scheme(Transport)},
                          Options);
        _ ->
            ConnectResult
    end.

verify_server(#{scheme := <<"http">>} = Connection, _) ->
    {ok, Connection};
verify_server(Connection, Options) ->
    case proplists:get_value(verify_server_identity, Options, false) of
        true ->
            verify_server_identity(Connection, Options);
        false ->
            {ok, Connection}
    end.

verify_server_identity(#{pid := Pid} = Connection, Options) ->
    case h2_connection:get_peercert(Pid) of
        {ok, Certificate} ->
            validate_peercert(Connection, Certificate, Options);
        _ ->
            h2_connection:stop(Pid),
            {error, no_peer_certificate}
    end.

validate_peercert(#{pid := Pid, host := Host} = Connection,
                  Certificate, Options) ->
    Server = proplists:get_value(server_host_override,
                                 Options, Host),
    case public_key:pkix_verify_hostname(Certificate,
                                         [{dns_id, Server}]) of
        true ->
            {ok, Connection};
        false ->
            h2_connection:stop(Pid),
            {error, invalid_peer_certificate}
    end.

h2_transport(tls) -> ssl;
h2_transport(http) -> gen_tcp.

scheme(tls) -> <<"https">>;
scheme(http) -> <<"http">>.

%% If there are no options at all, SSL will not be used.  If there are any
%% options, SSL will be used, and the ssl_options {verify, verify_peer} and
%% {fail_if_no_peer_cert, true} are implied.
%%
%% verify_server_identity and server_host_override should not be passed to the
%% connection.
ssl_options([]) ->
    [];
ssl_options(Options) ->
    Ignore = [verify_server_identity, server_host_override, 
              verify, fail_if_no_peer_cert],
    Default = [{verify, verify_peer},
               {fail_if_no_peer_cert, true}],
    {_Ignore, SslOptions} = proplists:split(Options, Ignore),
    Default ++ SslOptions.

new_stream(#{pid := Pid} = Connection, Service, Rpc, Encoder, Options, HandlerState) ->
    Compression = proplists:get_value(compression, Options, none),
    Metadata = proplists:get_value(metadata, Options, #{}),
    StreamId = h2_connection:new_stream(Pid),
    Package = Encoder:get_package_name(),
    RpcDef = Encoder:find_rpc_def(Service, Rpc),
    %% the gpb rpc def has 'input', 'output' etc.
    RpcDef#{stream_id => StreamId,
            package => [atom_to_list(Package),$.],
            service => Service,
            rpc => Rpc,
            encoder => Encoder,
            connection => Connection,
            headers_sent => false,
            handler_state => HandlerState,
            metadata => Metadata,
            compression => Compression}.

send_last(Stream, Message) ->
    send(Stream, Message, [{send_end_stream, true}]).

send(Stream, Message) ->
    send(Stream, Message, [{send_end_stream, false}]).

send(#{stream_id := StreamId,
       connection := #{pid := Connection},
       headers_sent := HeadersSent,
       metadata := Metadata
      } = Stream, Message, Opts) ->
    Encoded = encode(Stream, Message),
    case HeadersSent of
        false ->
            DefaultHeaders = default_headers(Stream),
            AllHeaders = add_metadata(DefaultHeaders, Metadata),
            h2_connection:send_headers(Connection, StreamId, AllHeaders);
        true ->
            ok
    end,
    h2_connection:send_body(Connection, StreamId, Encoded, Opts),
    Stream#{headers_sent => true}.

stop_connection(StreamId) ->
    h2_connection:stop(StreamId).

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

-spec call_rpc(Stream::grpc_client:stream(),
               Message::map(),
               Timeout::timeout()) ->
    grpc_client:unary_response().
%% @doc Call a unary rpc and process the response.
call_rpc(Stream, Message, Timeout) ->
    try grpc_client:send_last(Stream, Message) of
        ok ->
            process_response(Stream, Timeout)
    catch
        _:_ ->
            {error, #{error_type => client,
                      status_message => <<"failed to encode and send message">>}}
    end.

process_response(Stream, Timeout) ->
    case grpc_client:rcv(Stream, Timeout) of
        {headers, #{<<":status">> := <<"200">>,
                    <<"grpc-status">> := GrpcStatus} = Trailers}
          when GrpcStatus /= <<"0">> ->
            %% "trailers only" response.
            grpc_response(#{}, #{}, Trailers);
        {headers, #{<<":status">> := <<"200">>} = Headers} ->
            get_message(Headers, Stream, Timeout);
        {headers, #{<<":status">> := HttpStatus} = Headers} ->
            {error, #{error_type => http,
                      status => {http, HttpStatus},
                      headers => Headers}};
        {error, timeout} ->
            {error, #{error_type => timeout}}
    end.

get_message(Headers, Stream, Timeout) ->
    case grpc_client:rcv(Stream, Timeout) of
        {data, Response} ->
            get_trailer(Response, Headers, Stream, Timeout);
        {headers, Trailers} ->
            grpc_response(Headers, #{}, Trailers);
        {error, timeout} ->
            {error, #{error_type => timeout,
                      headers => Headers}}
    end.

get_trailer(Response, Headers, Stream, Timeout) ->
    case grpc_client:rcv(Stream, Timeout) of
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
