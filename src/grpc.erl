%%%-------------------------------------------------------------------
%%% Licensed to the Apache Software Foundation (ASF) under one
%%% or more contributor license agreements.  See the NOTICE file
%%% distributed with this work for additional information
%%% regarding copyright ownership.  The ASF licenses this file
%%% to you under the Apache License, Version 2.0 (the
%%% "License"); you may not use this file except in compliance
%%% with the License.  You may obtain a copy of the License at
%%%
%%%   http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing,
%%% software distributed under the License is distributed on an
%%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%%% KIND, either express or implied.  See the License for the
%%% specific language governing permissions and limitations
%%% under the License.
%%%

%%
%% @doc This is the interface for grpc.
%%
%% This module contains the functions to start and stop an Erlang gRPC server, as well 
%% as the functions that can be used by the programmer who implements the services
%% that are provided by that server.
%%
%% See the Readme in the root folder of the repository for a more general (tutorial-style)
%% introduction.
%%
-module(grpc).

%% APIs
-export([ compile/1
        , compile/2
        ]).

-export([ start_server/4
        , start_server/5
        , stop_server/1
        ]).

-export([ send/2
        , set_headers/2
        , set_trailers/2
        , send_headers/1
        , send_headers/2
        , metadata/1
        , authority/1, scheme/1, method/1, path/1
        , set_compression/2
        ]).

-type service_spec() :: #{handler := module(),
                          decoder => module(),
                          handler_state => handler_state()}.
%% The 'handler' module must export a function for each of the RPCs. Typically
%% this module is generated from the .proto file using grpc:compile/1. The
%% generated module contains skeleton functions for the RPCs, these must be
%% extended with the actual implementation of the service. 
%%
%% Optionally a start state ('handler_state') can be specified.
%%
%% The 'decoder' is also optional: by default the result of the 'decoder/0'
%% function in the handler module will be used.

-type services() :: #{ServiceName :: atom() := service_spec()}.
%% Links each gRPC service to a 'service_spec()'. The 'service_spec()' contains 
%% the information that the server needs to execute the service.

-type option() :: {transport_options, [ranch_ssl:ssl_opt()]} |
                  {num_acceptors, integer()}.
-type metadata_key() :: binary().
-type metadata_value() :: binary().
-type metadata() :: #{metadata_key() => metadata_value()}.
-type compression_method() :: none | gzip.
-type error_code() :: integer().
-type error_message() :: binary().
-type error_response() :: {error, error_code(), error_message(), stream()}.
-type handler_state() :: any().
%% This term is passed to the handler module. It will show up as the value of
%% the 'State' parameter that is passed to the first invocation (per stream) of
%% the generated RPC skeleton functions. The default value is 'undefined'. See
%% the implementation of 'RecordRoute' in the tutorial for an example.
-opaque stream() :: map().

-export_type([option/0,
              services/0,
              error_response/0,
              compression_method/0,
              stream/0,
              metadata_key/0, metadata_value/0,
              metadata/0]).

-spec compile(FileName::string()) -> ok.
%% @equiv compile(FileName, [])
compile(FileName) ->
    grpc:compile(FileName, []).

-spec compile(FileName::string(), Options::gbp_compile:opts()) -> ok.
%% @doc Compile a .proto file to generate server 
%% side skeleton code and a module to encode and decode the 
%% protobuf messages.
%%
%% Refer to gbp for the options. gRPC will always use the options
%% 'maps' (so that the protobuf messages are translated to and 
%% from maps) and the option '{i, "."}' (so that .proto files in the 
%% current working directory will be found).
compile(FileName, Options) ->
    grpc_lib_compile:file(FileName, Options).

-spec start_server(Name::term(), 
                   Transport::ssl|tcp,
                   Port::integer(),
                   Services::services()) -> {ok, CowboyListenerPid::pid()} |
                                            {error, any()}.
%% @equiv start_server(Name, Transport, Port, Services, [])
start_server(Name, Transport, Port, Services) when is_map(Services) ->
    start_server(Name, Transport, Port, Services, []).

-spec start_server(Name::term(),
                   Transport::ssl|tcp,
                   Port::integer(),
                   Services::services(), 
                   Options::[option()]) -> 
  {ok, CowboyListenerPid::pid()} | {error, any()}.
%% @doc Start a gRPC server. 
%%
%% The Name is used to identify this server in future calls, in particular when stopping
%% the server.
%%
%% 'Services' is a map that links each gRPC service to the module that implements
%% it (with some optional additional information).
start_server(Name, Transport, Port, Services, Options) when is_map(Services),
                                                           is_list(Options) ->
    grpc_server:start(Name, Transport, Port, Services, Options).

-spec stop_server(Name::term()) -> ok | {error, not_found}.
%% @doc Stop a gRPC server. 
stop_server(Name) ->
    grpc_server:stop(Name).

-spec send(stream(), map() | [map()]) -> stream().
%% @doc Send one or more messages from the server to the client.
%%
%% This function can be used in the service implementation to send 
%% one or more messages to the client via a stream.
send(Stream, MsgList) when is_map(Stream),
                           is_list(MsgList)->
    lists:foldl(fun (M, S) -> send(S, M) end, Stream, MsgList);
send(#{headers_sent := false} = Stream, Msg) when is_map(Stream),
                                                  is_map(Msg)->
    send(send_headers(Stream), Msg);
send(#{cowboy_req := CowboyReq,
       service := Service,
       rpc := Rpc,
       decoder := Decoder,
       compression := Compression,
       headers_sent := true} = Stream, Msg) when is_map(Msg) ->
    %% TODO: check on max length
    try grpc_lib:encode_output(Service, Rpc, Decoder, Msg) of
        Encoded ->
            {Data, Compressed} = case Compression of
                                     none ->
                                         {Encoded, 0};
                                     gzip ->
                                         {zlib:gzip(Encoded), 1}
                                 end,
            Length = byte_size(Data),
            OutFrame = <<Compressed, Length:32, Data/binary>>,
            cowboy_req:stream_body(OutFrame, nofin, CowboyReq),
            Stream
    catch
        _:_Error ->
            throw({error, <<"2">>, <<"Error encoding response">>, Stream})
    end.

-spec set_headers(stream(), metadata()) -> stream().
%% @doc Set metadata to be sent in headers.
%% Fails if headers have already been sent.
%%
%% This function can be used in the service implementation to add 
%% metadata to a stream. The metadata will be sent to the client (as HTTP/2 headers)
%% before the response message(s) is/are sent.
set_headers(#{headers := Metadata} = Stream, Headers) ->
    Stream#{headers => maps:merge(Metadata, Headers)}.

-spec set_trailers(stream(), metadata()) -> stream().
%% @doc Set metadata to be sent in trailers.
%%
%% This function can be used in the service implementation to add 
%% metadata to a stream. The metadata will be sent to the client (as HTTP/2 end headers)
%% after the response message(s) has/have been sent.
set_trailers(#{trailers := Metadata} = Stream, Trailers) ->
    Stream#{trailers => maps:merge(Metadata, Trailers)}.

-spec send_headers(stream()) -> stream().
%% Send headers. Silently ignored if headers were already sent.
send_headers(#{headers_sent := true} = Stream) ->
    Stream;
send_headers(Stream) ->
    send_headers(Stream, #{}).

-spec send_headers(stream(), metadata()) -> stream().
send_headers(#{cowboy_req := Req,
               headers := Metadata,
               compression := Compression,
               headers_sent := false} = Stream, Headers) ->
    MergedHeaders = grpc_lib:maybe_encode_headers(maps:merge(Metadata, Headers)),
    AllHeaders = case Compression of 
                     none -> MergedHeaders;
                     gzip -> 
                         MergedHeaders#{<<"grpc-encoding">> => <<"gzip">>}
                 end,
    Stream#{cowboy_req => cowboy_req:stream_reply(200, AllHeaders, Req),
            headers_sent => true}.

-spec metadata(Stream::stream()) -> metadata().
%% @doc Get the metadata that was sent by the client.
%%
%% Note that this will in fact provide all the headers (so not just the
%% metadata), except for :method, :authority, :scheme and :path (there are
%% separate functions to get access to those). But if there is for example a
%% grpc-timeout header this will also be returned as metadata.
metadata(#{metadata := Metadata}) ->
    Metadata.

-spec authority(Stream::stream()) -> binary().
%% @doc Get the value for the :authority header.
authority(#{authority := Value}) ->
    Value.

-spec scheme(Stream::stream()) -> binary().
%% @doc Get the value for the :scheme header.
scheme(#{scheme := Value}) ->
    Value.

-spec path(Stream::stream()) -> binary().
%% @doc Get the value for the :path header.
path(#{path := Value}) ->
    Value.

-spec method(Stream::stream()) -> binary().
%% @doc Get the value for the :method header.
method(#{method := Value}) ->
    Value.

-spec set_compression(stream(), compression_method()) -> stream().
%% @doc Enable compression of response messages. Currently only gzip or
%% none (no compression, the default) are supported.
set_compression(Stream, Method) when Method =:= none; Method =:= gzip ->
    Stream#{compression => Method}.
