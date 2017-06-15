-module(grpc_client_lib).

-export([
         connect/4,
         send/3,
         send_last/3,
         decode/2,
         unary/2, unary/3,
         new_stream/6,
         stop_connection/1
        ]).

%% TODO: 
%% - binary headers,
%% - compression
%% - keep track of headers/trailers
%% - security
%% - bidirectional streaming


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

get_messages(#{handler_state := S,
               stream_id := StreamId} = Stream, Handler) ->
    receive 
        {'RECV_DATA', StreamId, Bin} ->
            Decoded = decode(Stream, Bin),
            S2 = Handler({data, Decoded}, S),
            get_messages(Stream#{handler_state => S2}, Handler);
        {'RECV_HEADERS', StreamId, Headers} ->
            S2 = Handler({headers, maps:from_list(Headers)}, S),
            get_messages(Stream#{handler_state => S2}, Handler);
        {'END_STREAM', StreamId} ->
            {ok, Handler(eof, S)}
    after 5000 ->
        {error, timeout}
    end.

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
    case lists:keytake(verify_server_identity, 1, SslOptions) of
       {value, {_, true}, Options2}  ->
           case lists:keytake(server_host_override, 1, Options2) of
               false ->
                   {Default ++ Options2, true, Host};
               {value, {_, Override}, Options3} ->
                   {Default ++ Options3, true, Override}
           end;
       {value, {_, false}, Options2}  ->
           {Options2, false, Host};
       false ->
           {SslOptions, false, Host}
   end.
                
validate_peercert(Certificate, Host) ->
    public_key:pkix_verify_hostname(Certificate, [{dns_id, Host}]).

%% TODO: This is currently not used, either use or remove.
unary(Stream, Message) ->
    unary(Stream, Message, []).

unary(Stream, Message, Headers) ->
    Stream2 = send_last(Stream, Message, Headers),
    get_messages(Stream2, fun ({data, Msg}, _) -> Msg;
                              (_, S) -> S 
                          end).

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
            AllHeaders = client_headers(Stream,
                                        maps:to_list(Metadata) ++ Headers),
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
                 compression := CompressionMethod
                }, Headers) ->
    EncodedHeaders = [grpc_lib:maybe_encode_header(H) || H <- Headers],
    Path = iolist_to_binary(["/", Package, atom_to_list(Service), 
                             "/", atom_to_list(Rpc)]),
    lists:flatten([{<<":method">>, <<"POST">>},
                   {<<":scheme">>, <<"http">>},
                   {<<":path">>, Path},
                   {<<":authority">>, <<"localhost">>},
                   {<<"content-type">>, <<"application/grpc">>},
                   case CompressionMethod of
                       none ->
                           [];
                       _ ->
                           {<<"grpc-encoding">>,
                            atom_to_binary(CompressionMethod, unicode)}
                   end,
                   {<<"user-agent">>, <<"chatterbox-client/0.0.1">>},
                   {<<"te">>, <<"trailers">>} | EncodedHeaders]).
