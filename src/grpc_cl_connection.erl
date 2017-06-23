-module(grpc_cl_connection).

-export([
         new/4,
         stop/1,
         new_stream/1,
         stop_stream/2,
         send_headers/3,
         send_body/4
        ]).

-opaque connection() :: #{http_connection := pid(),  %% h2_connection
                          host := binary(),
                          scheme := binary()}.

-export_type([connection/0]).

-type tls_option()   :: grpc_client:tls_option().

-spec new(Transport::http | tls,
          Host::string(),
          Port::integer(),
          Options::[tls_option()]) -> {ok, connection()}.
%% @doc Open a new http/2 connection and check authorisation.
new(Transport, Host, Port, Options) ->
    {ok, _} = application:ensure_all_started(chatterbox),
    H2Settings = chatterbox:settings(client),
    SslOptions = ssl_options(Options),
    ConnectResult = h2_connection:start_client_link(h2_transport(Transport), 
                                                    Host, Port,
                                                    SslOptions, H2Settings),
    case ConnectResult of
        {ok, Pid} ->
            verify_server(#{http_connection => Pid,
                            host => list_to_binary(Host),
                            scheme => scheme(Transport)},
                          Options);
        _ ->
            ConnectResult
    end.

new_stream(#{http_connection := Pid}) ->
    h2_connection:new_stream(Pid).

stop_stream(_Connection, _Stream) ->
    %% apparently this is not required, chatterbox doesn't have it.
    ok.

send_headers(#{http_connection := Pid}, StreamId, Headers) ->
    h2_connection:send_headers(Pid, StreamId, Headers).

send_body(#{http_connection := Pid}, StreamId, Body, Opts) ->
    h2_connection:send_body(Pid, StreamId, Body, Opts).

-spec stop(Connection::connection()) -> ok.
%% @doc Stop an http/2 connection.
stop(#{http_connection := Pid}) ->
    h2_connection:stop(Pid).

%%% ---------------------------------------------------------------------------
%%% Internal functions
%%% ---------------------------------------------------------------------------

verify_server(#{scheme := <<"http">>} = Connection, _) ->
    {ok, Connection};
verify_server(Connection, Options) ->
    case proplists:get_value(verify_server_identity, Options, false) of
        true ->
            verify_server_identity(Connection, Options);
        false ->
            {ok, Connection}
    end.

verify_server_identity(#{http_connection := Pid} = Connection, Options) ->
    case h2_connection:get_peercert(Pid) of
        {ok, Certificate} ->
            validate_peercert(Connection, Certificate, Options);
        _ ->
            h2_connection:stop(Pid),
            {error, no_peer_certificate}
    end.

validate_peercert(#{http_connection := Pid, host := Host} = Connection,
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

