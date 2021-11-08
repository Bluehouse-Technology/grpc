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

%% The client supervisor
-module(grpc_client_sup).

-behaviour(supervisor).

-export([ create_channel_pool/3
        , stop_channel_pool/1
        ]).

-export([ start_link/3
        , init/1
        ]).

-define(APP_SUP, grpc_sup).

-type options() :: grpc_client:client_opts()
                 | #{pool_size => non_neg_integer()}.

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

-spec create_channel_pool(term(), uri_string:uri_string(), options())
    -> supervisor:startchild_ret().
create_channel_pool(Name, URL, Opts) ->
    _ = application:ensure_all_started(gproc),
    case uri_string:parse(URL) of
        #{scheme := Scheme, host := Host, port := Port} ->
            Server = {Scheme, Host, Port},
            Spec = #{id       => Name,
                     start    => {?MODULE, start_link, [Name, Server, Opts]},
                     restart  => transient,
                     shutdown => infinity,
                     type     => supervisor,
                     modules  => [?MODULE]},
            supervisor:start_child(?APP_SUP, Spec);
        {error, Reason, _} -> {error, Reason}
    end.

-spec stop_channel_pool(term()) -> ok.

stop_channel_pool(Name) ->
    case supervisor:terminate_child(?APP_SUP, Name) of
        ok ->
            ok = supervisor:delete_child(?APP_SUP, Name);
        R -> R
    end.

%%--------------------------------------------------------------------
%% Callbacks
%%--------------------------------------------------------------------

start_link(Name, Server, Opts) ->
    supervisor:start_link(?MODULE, [Name, Server, Opts]).

init([Name, Server, Opts]) ->
    Size = pool_size(Opts),
    ok = ensure_pool(Name, hash, [{size, Size}]),
    {ok, {{one_for_one, 10, 3600}, [
        begin
            ensure_pool_worker(Name, {Name, I}, I),
            #{id => {Name, I},
              start => {grpc_client, start_link, [Name, I, Server, Opts]},
              restart => transient,
              shutdown => 5000,
              type => worker,
              modules => [grpc_client]}
        end || I <- lists:seq(1, Size)]}}.

%% @private
ensure_pool(Name, Type, Opts) ->
    try gproc_pool:new(Name, Type, Opts)
    catch
        error:exists -> ok
    end.

%% @private
ensure_pool_worker(Name, WorkName, Slot) ->
    try gproc_pool:add_worker(Name, WorkName, Slot)
    catch
        error:exists -> ok
    end.

pool_size(Opts) ->
    maps:get(pool_size, Opts, erlang:system_info(schedulers)).
