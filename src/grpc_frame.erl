%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(grpc_frame).

-include("grpc.hrl").

-export([ encode/2
        , split/2
        ]).

-type encoding() :: none | gzip.

-define(GRPC_ERROR(Status, Message), {grpc_error, {Status, Message}}).
-define(THROW(Status, Message), throw(?GRPC_ERROR(Status, Message))).

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

-spec encode(encoding(), binary()) -> binary().

encode(Encoding, Bin) when is_binary(Encoding) ->
    encode(binary_to_existing_atom(Encoding, utf8), Bin);
encode(gzip, Bin) ->
    CompressedBin = zlib:gzip(Bin),
    Length = byte_size(CompressedBin),
    <<1, Length:32, CompressedBin/binary>>;
encode(none, Bin) ->
    Length = byte_size(Bin),
    <<0, Length:32, Bin/binary>>;
encode(Encoding, _) ->
    throw({error, {unknown_encoding, Encoding}}).

-spec split(binary(), encoding()) ->
    {Remaining :: binary(), Frames :: [binary()]}.

split(Frame, Encoding) when is_binary(Encoding) ->
    split(Frame, binary_to_existing_atom(Encoding, utf8));
split(Frame, Encoding) ->
    split(Frame, Encoding, []).

split(<<>>, _Encoding, Acc) ->
    {<<>>, lists:reverse(Acc)};
split(<<0, Length:32, Encoded:Length/binary, Rest/binary>>, Encoding, Acc) ->
    split(Rest, Encoding, [Encoded | Acc]);
split(<<1, Length:32, Compressed:Length/binary, Rest/binary>>, Encoding, Acc) ->
    Encoded = case Encoding of
                  gzip ->
                      try zlib:gunzip(Compressed)
                      catch
                          error:data_error ->
                              ?THROW(?GRPC_STATUS_INTERNAL,
                                     <<"Could not decompress but compression algorithm ",
                                       (atom_to_binary(Encoding, utf8))/binary, " is supported">>)
                      end;
                  _ ->
                      ?THROW(?GRPC_STATUS_UNIMPLEMENTED,
                             <<"Compression mechanism ", (atom_to_binary(Encoding, utf8))/binary,
                               " used for received frame not supported">>)
              end,
    split(Rest, Encoding, [Encoded | Acc]);
split(Bin, _Encoding, Acc) ->
    {Bin, lists:reverse(Acc)}.
