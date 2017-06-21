-module(grpc_client_lib).

-export([
         connect/4,
         send/3,
         send_last/3,
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

connect(Transport, Host, Port, SslOptions) ->
    {ok, _} = application:ensure_all_started(chatterbox),
    H2Transport = case Transport of
                    http -> gen_tcp;
                    tls -> ssl
                  end,
    H2Settings = chatterbox:settings(client),
    {H2Options, VerifyServerId, ServerId} = process_options(SslOptions, Host),
    ConnectResult = h2_connection:start_client_link(H2Transport, Host, Port,
                                                    H2Options, H2Settings),
    case ConnectResult of
        {ok, Pid} ->
            case Transport == tls andalso VerifyServerId of
                true ->
                    {ok, PeerCertificate} = h2_connection:get_peercert(Pid),
                    case validate_peercert(PeerCertificate, ServerId) of
                        true ->
                            ConnectResult;
                        false ->
                            {error, invalid_peer_certificate}
                    end;
                false ->
                    ConnectResult
            end;
        _ ->
            ConnectResult
    end.

process_options([], Host) ->
    {[], false, Host};
%% See if we need to verify the identity of the server, using the identity from
%% the certificate provided by the server. If that is the case, check whether
%% it should be checked against the host name, or against something else
%% (server_host_override).
process_options(SslOptions, Host) ->
    Default = [{verify, verify_peer},
               {fail_if_no_peer_cert, true}],
    case grpc_lib:keytake(verify_server_identity, SslOptions, false) of
        {true, Options2} ->
            {Override, Options3} = grpc_lib:keytake(server_host_override,
                                                    Options2, Host),
            {Default ++ Options3, true, Override};
        {false, Options2} ->
           {Options2, false, Host}
    end.

validate_peercert(Certificate, Host) ->
    public_key:pkix_verify_hostname(Certificate, [{dns_id, Host}]).

new_stream(Connection, Service, Rpc, Encoder, Options, HandlerState) ->
    Compression = proplists:get_value(compression, Options, none),
    Metadata = proplists:get_value(metadata, Options, #{}),
    StreamId = h2_connection:new_stream(Connection),
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

send_last(Stream, Message, Headers) ->
    send(Stream, Message, Headers, [{send_end_stream, true}]).

send(Stream, Message, Headers) ->
    send(Stream, Message, Headers, [{send_end_stream, false}]).

send(#{stream_id := StreamId,
       connection := Connection,
       headers_sent := HeadersSent,
       metadata := Metadata
      } = Stream, Message, Headers, Opts) ->
    Encoded = encode(Stream, Message),
    case HeadersSent of
        false ->
            %% TODO: Currently there are 2 ways to send metadata/headers. Keep only the
            %% way where they are specified with the creation of the stream.
            DefaultHeaders = client_headers(Stream, Headers),
            AllHeaders = maps:to_list(maps:merge(DefaultHeaders, Metadata)),
            h2_connection:send_headers(Connection, StreamId, AllHeaders);
        true ->
            ok
    end,
    h2_connection:send_body(Connection, StreamId, Encoded, Opts),
    Stream#{headers_sent => true}.

stop_connection(StreamId) ->
    h2_connection:stop(StreamId).

client_headers(#{service := Service,
                 rpc := Rpc,
                 package := Package,
                 compression := Compression
                }, Headers) ->
    Headers1 = case Compression of
                   none ->
                       Headers;
                   _ ->
                       [{<<"grpc-encoding">>,
                         atom_to_binary(Compression, unicode)} | Headers]
               end,
    EncodedHeaders = lists:foldl(fun(H, Acc) ->
                                     {K, V} = grpc_lib:maybe_encode_header(H),
                                     maps:put(K, V, Acc)
                                 end, #{}, Headers1),
    Path = iolist_to_binary(["/", Package, atom_to_list(Service),
                             "/", atom_to_list(Rpc)]),
    EncodedHeaders#{<<":method">>      => <<"POST">>,
                    <<":scheme">>      => <<"http">>,
                    <<":path">>        => Path,
                    <<":authority">>   => <<"localhost">>,
                    <<"content-type">> => <<"application/grpc">>,
                    <<"user-agent">>   => <<"chatterbox-client/0.0.1">>,
                    <<"te">>           => <<"trailers">>}.

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
