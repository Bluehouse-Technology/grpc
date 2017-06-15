-module(grpc_lib).

-export([auth_fun/1,
         decode_input/4,
         encode_output/4,
         maybe_encode_header/1,
         maybe_encode_headers/1,
         maybe_decode_header/1]).

-type cert() :: term().

-spec auth_fun(Directory::string()) -> fun((cert()) -> {true, string()} | false).
%% @doc returns a function that can be used to authenticate against the 
%% keys that are stored in a certain directory.
%% The base name of the key file is used as the identity.
auth_fun(Directory) ->
    Ids = issuer_ids_from_directory(Directory),
    fun(Cert) -> 
            {ok, IssuerID} = public_key:pkix_issuer_id(Cert, self),
            case maps:find(IssuerID, Ids) of 
                {ok, Identity} ->
                    {true, Identity};
                error ->
                    false
            end
    end.

-spec decode_input(ServiceName::atom(), RpcName::atom(), 
                   DecoderModule::module(), Message::binary() | eof)
    -> map() | eof.
%% @doc Decode input protobuf message to map.
decode_input(_, _, _, eof) ->
    eof;
decode_input(ServiceName, RpcName, DecoderModule, Msg) ->
    #{input := MsgName} = DecoderModule:fetch_rpc_def(ServiceName, RpcName),
    DecoderModule:decode_msg(Msg, MsgName).

-spec encode_output(ServiceName::atom(), RpcName::atom(), 
                    DecoderModule::module(), Message::map()) -> binary().
%% @doc Encode response message (map) to binary protobuf message.
encode_output(ServiceName, RpcName, DecoderModule, Msg) ->
    #{output := MsgName} = DecoderModule:fetch_rpc_def(ServiceName, RpcName),
    DecoderModule:encode_msg(Msg, MsgName).

-spec maybe_encode_header(Header::{grpc:metadata_key(),
                                   grpc:metadata_value()}) -> 
    {grpc:metadata_key(), grpc:metadata_value()}.
%% @doc Encode header using Base64 if the header name ends with "-bin".
maybe_encode_header({Key, Value} = Header) ->
    case is_bin_header(Key) of
        true ->
            {Key, base64:encode(Value)};
        false ->
            Header
    end.

-spec maybe_decode_header(Header::{grpc:metadata_key(),
                                   grpc:metadata_value()}) -> 
    {grpc:metadata_key(), grpc:metadata_value()}.
%% @doc Decode header from Base64 if the header name ends with "-bin".
maybe_decode_header({Key, Value} = Header) ->
    case is_bin_header(Key) of
        true ->
            {Key, base64:decode(Value)};
        false ->
            Header
    end.

-spec maybe_encode_headers(grpc:meta_data()) -> grpc:meta_data().
%% @doc Encode the header values to Base64 for those headers that have the name 
%% ending with "-bin".
maybe_encode_headers(Headers) ->
    maps:map(fun(K, V) -> 
                     case is_bin_header(K) of
                         true ->
                             base64:encode(V);
                         false -> 
                             V
                     end
             end, Headers).

%%% ---------------------------------------------------------------------------
%%% Internal functions
%%% ---------------------------------------------------------------------------

is_bin_header(Key) ->
    binary:longest_common_suffix([Key, <<"-bin">>]) == 4.

issuer_ids_from_directory(Dir) ->
    {ok, Filenames} = file:list_dir(Dir),
    Keyfiles = lists:filter(fun(N) -> 
                                case filename:extension(N) of
                                    ".pem" -> true;
                                    ".crt" -> true;
                                    _ -> false
                                end
                            end, Filenames),
    maps:from_list([issuer_id_from_file(filename:join([Dir, F])) 
                    || F <- Keyfiles]).

issuer_id_from_file(Filename) ->
    {certfile_to_issuer_id(Filename),
     filename:rootname(filename:basename(Filename))}.

certfile_to_issuer_id(Filename) ->
    {ok, Data} = file:read_file(Filename),
    [{'Certificate', Cert, not_encrypted}] = public_key:pem_decode(Data),
    {ok, IssuerID} = public_key:pkix_issuer_id(Cert, self),
    IssuerID.
