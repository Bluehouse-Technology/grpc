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

-ifndef(GRPC_HRL).
-define(GRPC_HRL, true).

-define(GRPC_STATUS_OK, <<"0">>).
-define(GRPC_STATUS_CANCELLED, <<"1">>).
-define(GRPC_STATUS_UNKNOWN, <<"2">>).
-define(GRPC_STATUS_INVALID_ARGUMENT, <<"3">>).
-define(GRPC_STATUS_DEADLINE_EXCEEDED, <<"4">>).
-define(GRPC_STATUS_NOT_FOUND, <<"5">>).
-define(GRPC_STATUS_ALREADY_EXISTS , <<"6">>).
-define(GRPC_STATUS_PERMISSION_DENIED, <<"7">>).
-define(GRPC_STATUS_RESOURCE_EXHAUSTED, <<"8">>).
-define(GRPC_STATUS_FAILED_PRECONDITION, <<"9">>).
-define(GRPC_STATUS_ABORTED, <<"10">>).
-define(GRPC_STATUS_OUT_OF_RANGE, <<"11">>).
-define(GRPC_STATUS_UNIMPLEMENTED, <<"12">>).
-define(GRPC_STATUS_INTERNAL, <<"13">>).
-define(GRPC_STATUS_UNAVAILABLE, <<"14">>).
-define(GRPC_STATUS_DATA_LOSS, <<"15">>).
-define(GRPC_STATUS_UNAUTHENTICATED, <<"16">>).

-type grpc_status() :: binary(). %% GRPC_STATUS_OK...GRPC_STATUS_UNAUTHENTICATED

-type grpc_message() :: binary().

-endif.
