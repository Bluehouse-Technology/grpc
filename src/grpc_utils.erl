%%--------------------------------------------------------------------
%% Copyright (c) 2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(grpc_utils).

-include("grpc.hrl").

-export([ codename/1
        ]).

-spec codename(grpc_status()) -> grpc_status_name().
codename(?GRPC_STATUS_OK) -> ok;
codename(?GRPC_STATUS_CANCELLED) -> cancelled;
codename(?GRPC_STATUS_UNKNOWN) -> unknown;
codename(?GRPC_STATUS_INVALID_ARGUMENT) -> invalid_argument;
codename(?GRPC_STATUS_DEADLINE_EXCEEDED) -> deadline_exceeded;
codename(?GRPC_STATUS_NOT_FOUND) -> not_found;
codename(?GRPC_STATUS_ALREADY_EXISTS) -> already_exists;
codename(?GRPC_STATUS_PERMISSION_DENIED) -> permission_denied;
codename(?GRPC_STATUS_RESOURCE_EXHAUSTED) -> resource_exhausted;
codename(?GRPC_STATUS_FAILED_PRECONDITION) -> failed_precondition;
codename(?GRPC_STATUS_ABORTED) -> aborted;
codename(?GRPC_STATUS_OUT_OF_RANGE) -> out_of_range;
codename(?GRPC_STATUS_UNIMPLEMENTED) -> unimplemented;
codename(?GRPC_STATUS_INTERNAL) -> internal;
codename(?GRPC_STATUS_UNAVAILABLE) -> unavailable;
codename(?GRPC_STATUS_DATA_LOSS) -> data_loss;
codename(?GRPC_STATUS_UNAUTHENTICATED) -> unauthenticated.
