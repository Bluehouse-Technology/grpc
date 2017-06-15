-module(grpc_stream).

%% An a-synchronous client with a queue-like interface.
%% A gen_server is started for each stream, this keeps track
%% of the status of the connection and it buffers responses in a queue.

-behaviour(gen_server).

-export([new/5, 
         send/2, send/3, 
         send_last/2, send_last/3,
         get/1, rcv/1, rcv/2, stop/1]).

%% gen_server behaviors
-export([code_change/3, handle_call/3, handle_cast/2, handle_info/2, init/1, terminate/2]).

-spec new(Connection::pid(),
          Service::atom(),
          Rpc::atom(),
          Encoder::module(),
          Options::list()) -> {ok, Pid::pid()} | {error, Reason::term()}.
new(Connection, Service, Rpc, Encoder, Options) ->
    gen_server:start_link(?MODULE, 
                          {Connection, Service, Rpc, Encoder, Options}, []).

send(Pid, Message) ->
    send(Pid, Message, []).

send(Pid, Message, Headers) ->
    gen_server:call(Pid, {send, Message, Headers}).

send_last(Pid, Message) ->
    send_last(Pid, Message, []).

send_last(Pid, Message, Headers) ->
    gen_server:call(Pid, {send_last, Message, Headers}).

get(Pid) ->
    gen_server:call(Pid, get).

rcv(Pid) ->
    rcv(Pid, infinity).

rcv(Pid, Timeout) ->
    gen_server:call(Pid, {rcv, Timeout}, infinity).

-spec stop(Stream::pid()) -> ok.
%% @doc Close (stop/clean up) the stream.
stop(Pid) ->
    gen_server:stop(Pid).

%% gen_server implementation
init({Connection, Service, Rpc, Encoder, Options}) ->
    {ok,
     #{stream => grpc_client_lib:new_stream(Connection, Service, Rpc, Encoder, Options, []),
       queue => queue:new(),
       response_pending => false,
       state => open}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_call({send_last, Message, Headers}, _From, #{stream := Stream} = State) ->
    NewStream = grpc_client_lib:send_last(Stream, Message, Headers),
    {reply, ok, State#{stream => NewStream}};
handle_call({send, Message, Headers}, _From, #{stream := Stream} = State) ->
    NewStream = grpc_client_lib:send(Stream, Message, Headers),
    {reply, ok, State#{stream => NewStream}};
handle_call(get, _From, #{queue := Queue,
                          state := StreamState} = State) ->
    {Value, NewQueue} = queue:out(Queue),
    Response = case {Value, StreamState} of
                   {{value, V}, _} ->
                       V;
                   {empty, closed} ->
                       eof;
                   {empty, open} ->
                       empty
               end,
    {reply, Response, State#{queue => NewQueue}};
handle_call({rcv, Timeout}, From, #{queue := Queue,
                                    state := StreamState} = State) ->
    {Value, NewQueue} = queue:out(Queue),
    NewState = State#{queue => NewQueue},
    case {Value, StreamState} of
        {{value, V}, _} ->
            {reply, V, NewState};
        {empty, closed} ->
            {reply, eof, NewState};
        {empty, open} ->
            {noreply, NewState#{client => From,
                                response_pending => true}, Timeout}
    end.

handle_cast(_, State) ->
    {noreply, State}.

handle_info({'RECV_DATA', StreamId, Bin}, 
            #{stream := #{stream_id := StreamId} = Stream} = State) ->
    Response = try 
                   {data, grpc_client_lib:decode(Stream, Bin)}
               catch
                  throw:{error, Message} ->
                       {error, Message};
                   _Error:_Message ->
                       {error, <<"failed to decode message">>}
               end,
    info_response(Response, State);
handle_info({'RECV_HEADERS', StreamId, Headers},
            #{stream := #{stream_id := StreamId} = Stream} = State) ->
    HeadersMap = maps:from_list([grpc_lib:maybe_decode_header(H) 
                                 || H <- Headers]),
    Encoding = maps:get(<<"grpc-encoding">>, HeadersMap, none),
    info_response({headers, HeadersMap}, 
                  State#{stream => Stream#{response_encoding => Encoding}});
handle_info({'END_STREAM', StreamId},
            #{stream := #{stream_id := StreamId}} = State) ->
    info_response(eof, State#{state => closed});
handle_info(timeout, #{response_pending := true,
                       client := Client} = State) ->
    gen_server:reply(Client, {error, timeout}),
    {noreply, State#{response_pending => false}};
handle_info(_InfoMessage, State) ->
    {noreply, State}.

terminate(_Reason, #{stream := Stream,
                     state := open}) ->
    grpc_client_lib:stop(Stream);
terminate(_Reason, #{state := closed}) ->
    ok.

%% private methods
info_response(Response, #{response_pending := true,
                          client := Client} = State) ->
    gen_server:reply(Client, Response),
    {noreply, State#{response_pending => false}};
info_response(Response, #{queue := Queue} = State) ->
    NewQueue = queue:in(Response, Queue),
    {noreply, State#{queue => NewQueue}}.
