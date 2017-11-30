%% Middleware example that logs to disk
-module(route_guide_middleware).
-behaviour(cowboy_middleware).

-export([execute/2]).

execute(Req, Env) ->
    LoggingData = "here are some logs",
    ok = file:write_file("route_guide_middleware_log", LoggingData),
	{ok, Req, Env}.
