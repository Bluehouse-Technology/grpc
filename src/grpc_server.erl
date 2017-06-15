%%% Implementation of the interface between the gRPC framework and the
%%% Cowboy HTTP server.
%%%
%%% Starts and stops the server, and acts as the 
%%% entry point for each request (the 'init' function).
%%%
-module(grpc_server).

-export([start/3]).
-export([stop/1]).
-export([init/2]).

%% status codes as defined here: http://www.grpc.io/grpc/csharp/html/T_Grpc_Core_StatusCode.htm
-define(GRPC_STATUS_OK, <<"0">>).
-define(GRPC_STATUS_UNKNOWN, <<"2">>).
-define(GRPC_STATUS_UNIMPLEMENTED, <<"12">>).
-define(GRPC_STATUS_INTERNAL, <<"13">>).
-define(GRPC_STATUS_INTERNAL_INT, 13).
-define(GRPC_STATUS_UNAUTHENTICATED, <<"16">>).

-spec start(Name::term(),
            Handler::module(),
            Options::[grpc:server_option()]) ->
    {ok, CowboyListenerPid::pid()} | {error, any()}.
start(Name, Handler, Options) ->
    {ok, _Started} = application:ensure_all_started(grpc),
    {module, _} = code:ensure_loaded(Handler),
    HandlerState = proplists:get_value(handler_state, Options),
    Decoder = Handler:decoder(),
    {module, _} = code:ensure_loaded(Decoder),
    Acceptors = proplists:get_value(nr_acceptors, Options, 100),
    {UseTls, TlsOptions, HandlerOptions} = 
        case proplists:get_value(tls_options, Options, undefined) of
            undefined ->
                {false, [], #{}};
            V -> 
                case proplists:get_value(client_cert_dir, Options, undefined) of
                    undefined ->
                        {true, V, #{}};
                    Dir ->
                        {true, V, #{auth_fun => grpc_lib:auth_fun(Dir)}}
                end
        end,
    %% All requests are dispatched to this same module (?MODULE),
    %% which means that `init/2` below will be called for each
    %% request.
    Dispatch = cowboy_router:compile([
	{'_', [{"/:service/:method", 
                ?MODULE, 
                HandlerOptions#{handler_state => HandlerState,
                                handler => Handler,
                                decoder => Decoder}}]}]),
    TransportOpts = case proplists:get_value(port, Options) of
                        undefined ->
                            [];
                        Port -> 
                            [{port, Port}]
                    end,
    ProtocolOpts = #{env => #{dispatch => Dispatch},
                     http2_recv_timeout => infinity},
    case UseTls of
        false ->
            {ok, _} = cowboy:start_clear(Name, Acceptors, TransportOpts, 
                                         ProtocolOpts);
        true ->
            {ok, _} = cowboy:start_tls(Name, Acceptors, 
                                       TlsOptions ++ TransportOpts, 
                                       ProtocolOpts)
    end.

-spec stop(Name::term()) -> ok.
stop(Name) ->
    cowboy:stop_listener(Name).

%% This is called by cowboy for each request. 
%% It needs to differentiate between the different types of RPC (Simple RPC,
%% Client-side streaming RPC etc.)
init(Req, Options) ->
    Stream = make_stream(Req),
    case authenticate(Req, Options) of 
        false ->
            finalize(Stream, ?GRPC_STATUS_UNAUTHENTICATED, <<"">>);
        {true, ClientInfo} ->
            try 
                authenticated(Stream#{client_info => ClientInfo}, Options)
            catch
                throw:{Code, Reason} ->
                    finalize(Stream, Code, Reason)
            end
    end.
        
make_stream(#{headers := Headers} = Req) ->
    maps:fold(fun process_header/3, 
              #{cowboy_req => Req,
                headers => #{},
                trailers => #{},
                metadata => #{}, %% metadata received from client
                %% headers can be sent explicitly from the user code, for 
                %% example to do it quickly or to add metadata. If not, they 
                %% will be sent by the framework before the first data frame.
                headers_sent => false,
                encoding => plain,
                compression => none, %% compression of the response messages
                start_time => erlang:system_time(1),
                content_type => undefined,
                user_agent => undefined,
                timeout => infinity}, Headers).

process_header(<<"grpc-timeout">>, Value, Acc) ->
    Acc#{timeout => Value};
%% TODO: not clear what should be done with this header
process_header(<<"te">>, _Value, Acc) ->
    Acc;
process_header(<<"user-agent">>, Value, Acc) ->
    Acc#{user_agent => Value};
process_header(<<"grpc-encoding">>, Value, Acc) ->
    Acc#{encoding => Value};
process_header(<<"content-type">>, Value, Acc) ->
    Acc#{content_type => Value};
process_header(Key, Value, #{metadata := Metadata} = Acc) ->
    {_, DecodedValue} = grpc_lib:maybe_decode_header({Key, Value}),
    Acc#{metadata => Metadata#{Key => DecodedValue}}.

authenticate(Req, #{auth_fun := AuthFun}) ->
    case cowboy_req:peercert(Req) of
        {ok, Cert} ->
            AuthFun(Cert);
        {error, no_peercert} ->
            false
    end;
authenticate(_Req, _Options) ->
    {true, undefined}.

authenticated(#{cowboy_req := Req} = Stream, Options) ->
    %% invoke the rpc (= function) for the service (= module).
    try
        get_function(Req, Options, Stream)
    of
        NewStream ->
            %% TODO: determine how to deal with the body and decoding. 
            %% At the very least it should be able to deal with chunks, but probably
            %% the decoding (and encoding of the result) should be 'automatic'.
            read_frames(NewStream)
    catch
        _:_ -> throw({?GRPC_STATUS_UNIMPLEMENTED,
                      <<"Operation not implemented">>})
    end.

get_function(Req, #{handler := HandlerModule,
                    decoder := DecoderModule,
                    handler_state := HandlerState} = _Options, Stream) ->
    QualifiedService = cowboy_req:binding(service, Req), 
    Rpc = binary_to_existing_atom(cowboy_req:binding(method, Req)),
    Service = binary_to_existing_atom(lists:last(binary:split(QualifiedService, 
                                                              <<".">>, [global]))),
    Stream#{decoder => DecoderModule,
            service => Service,
            handler => HandlerModule,
            handler_state => HandlerState,
            rpc => Rpc}.

binary_to_existing_atom(B) ->
    list_to_existing_atom(binary_to_list(B)).

read_frames(#{cowboy_req := Req,
              encoding := Encoding} = Stream) ->
    %% This assumes that using option 'length' = 1 will avoid situations 
    %% where cowboy is waiting for a buffer to fill up, but on the other hand 
    %% it will also not be busy waiting (it looks like that happens when 
    %% 'length' = 0)
    %% TODO: Verify this...
    {More, InFrame, Req2} = cowboy_req:read_body(Req, #{length => 1}),
    %% TODO: Messages do not have to be aligned with frames. 
    Messages = split_frame(InFrame, Encoding),
    process_messages(Messages, Stream#{cowboy_req => Req2}, More).

process_messages([Message | T], Stream, More) ->
    case execute(Message, Stream) of
        {Response, NewStream, NewState} ->
            respond_and_continue(T, Response, NewStream, NewState, More);
        {_Response, _NewStream} = FinalResponse ->
            respond_and_finalize(FinalResponse);
        {error, Code, ErrorMessage, NewStream} when is_integer(Code), 
                                                    is_binary(ErrorMessage) ->
            finalize(NewStream, integer_to_binary(Code), ErrorMessage);
         _Other ->
            finalize(Stream, ?GRPC_STATUS_INTERNAL,
                     <<"Internal error - unexpected response value">>)
    end;
process_messages([], Stream, More) -> 
    case More of 
        ok ->
            respond_and_finalize(execute(eof, Stream));
        more ->
            read_frames(Stream)
    end.

respond_and_finalize({Response, NewStream}) ->
    try grpc:send(NewStream, Response) of
        SentStream ->
            finalize(SentStream)
    catch 
        throw:{error, Status, Message} ->
            finalize(NewStream, Status, Message);
        throw:{error, Status, Message, CurrentStream} ->
            finalize(CurrentStream, Status, Message)
    end.

respond_and_continue(T, continue, NewStream, NewState, More) ->
   process_messages(T, NewStream#{handler_state => NewState}, More);
respond_and_continue(T, Response, NewStream, NewState, More) ->
    try grpc:send(NewStream#{handler_state => NewState}, Response) of
        SentStream ->
            process_messages(T, SentStream, More)
    catch 
        throw:{error, _, Message} ->
            finalize(NewStream, ?GRPC_STATUS_UNKNOWN, Message)
    end.

execute(Msg, #{handler := Module,
               service := Service,
               rpc := Function,
               decoder := Decoder,
               handler_state := State} = Stream) ->
    try grpc_lib:decode_input(Service, Function, Decoder, Msg) of
        Decoded ->
            try 
                Module:Function(Decoded, Stream, State) 
            catch
                throw:{Code, ErrorMsg} ->
                    {error, Code, ErrorMsg};
                _:_ ->
                    %%io:format("error in handler function, ~p~n", [erlang:get_stacktrace()]),
                    {error, ?GRPC_STATUS_INTERNAL_INT, 
                     <<"Internal server error">>, Stream}
            end
    catch
        _:_ ->
            %%io:format("error decoding message, ~p~n", [erlang:get_stacktrace()]),
            {error, ?GRPC_STATUS_INTERNAL_INT, 
             <<"Error parsing request protocol buffer">>, Stream}
    end.

finalize(Stream) ->
    finalize(Stream, ?GRPC_STATUS_OK, <<"">>).

finalize(#{headers_sent := false} = Stream, Status, Message) ->
    %% (In theory this could be a "trailers-only" response, but
    %% in fact headers are sent separately).
    finalize(grpc:send_headers(Stream), Status, Message);
finalize(#{cowboy_req := Req, trailers := Trailers}, Status, <<"">>) ->
    _R = cowboy_req:stream_trailers(Trailers#{<<"grpc-status">> => Status}, Req),
    {ok, Req, []};
finalize(#{trailers := Trailers} = Stream, Status, Message) ->
    finalize(Stream#{trailers => Trailers#{<<"grpc-message">> => Message}}, Status, <<"">>).

split_frame(Frame, Encoding) ->
    split_frame(Frame, Encoding, []).
split_frame(<<>>, _Encoding, Acc) ->
    lists:reverse(Acc);
split_frame(<<0, Length:32, Encoded:Length/binary, Rest/binary>>, Encoding, Acc) ->
    split_frame(Rest, Encoding, [Encoded | Acc]);
split_frame(<<1, Length:32, Compressed:Length/binary, Rest/binary>>, 
            Encoding, Acc) ->
    Encoded = case Encoding of
                  <<"gzip">> ->
                      zlib:gunzip(Compressed);
                  _ ->
                      throw({?GRPC_STATUS_UNIMPLEMENTED, 
                             <<"compression mechanism not supported">>})
              end,
    split_frame(Rest, Encoding, [Encoded | Acc]).
