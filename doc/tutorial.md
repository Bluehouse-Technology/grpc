<p class="lead">This tutorial provides a basic Erlang programmer's introduction to working with gRPC.</p>

(This is a version for Erlang of the tutorial that is available for several
other languages on grpc.io, see for example [the C
version](http://www.grpc.io/docs/tutorials/basic/c.html))

By walking through this example you'll learn how to:

- Define a service in a .proto file.
- Generate server and client code using the protocol buffer compiler.
- Use the Erlang gRPC API to write a simple client and server for your service.

It assumes that you have read the [Overview](http://www.grpc.io/docs/index.html/) on gRPC.io and are familiar
with [protocol
buffers](https://developers.google.com/protocol-buffers/docs/overview). Note
that the example in this tutorial uses the proto3 version of the protocol
buffers language, which is currently in beta release: you can find out more in
the [proto3 language
guide](https://developers.google.com/protocol-buffers/docs/proto3) 
and see the [release notes](https://github.com/google/protobuf/releases) for the
new version in the protocol buffers Github repository.

<div id="toc"></div>

## Why use gRPC?

Our example is a simple route mapping application that lets clients get
information about features on their route, create a summary of their route, and
exchange route information such as traffic updates with the server and other
clients.

With gRPC we can define our service once in a .proto file and implement clients
and servers in any of gRPC's supported languages, which in turn can be run in
environments ranging from servers inside Google to your own tablet - all the
complexity of communication between different languages and environments is
handled for you by gRPC. We also get all the advantages of working with protocol
buffers, including efficient serialization, a simple IDL, and easy interface
updating.

## Example code and setup

The example code for our tutorial is in
[/examples/route_guide](/examples/route_guide). 

To try the examples it is easiest to start an erlang shell using:

```
$ make shell
```

And then in this shell cd to the examples/routeguide directory:

```
1> cd("examples/route_guide").
```


## Defining the service

Our first step is to
define the gRPC *service* and the method *request* and *response* types using
[protocol buffers](https://developers.google.com/protocol-buffers/docs/overview). 
You can see the complete .proto file in
[`examples/route_guide/route_guide.proto`](/examples/route_guide/route_guide.proto).

To define a service, you specify a named `service` in your .proto file:

```
service RouteGuide {
   ...
}
```

Then you define `rpc` methods inside your service definition, specifying their
request and response types. gRPC lets you define four kinds of service method,
all of which are used in the `RouteGuide` service:

- A *simple RPC* where the client sends a request to the server using the stub
  and waits for a response to come back, just like a normal function call.

```
// Obtains the feature at a given position.
rpc GetFeature(Point) returns (Feature) {}
```

- A *server-side streaming RPC* where the client sends a request to the server
  and gets a stream to read a sequence of messages back. The client reads from
  the returned stream until there are no more messages. As you can see in our
  example, you specify a server-side streaming method by placing the `stream`
  keyword before the *response* type.

```
// Obtains the Features available within the given Rectangle.  Results are
// streamed rather than returned at once (e.g. in a response message with a
// repeated field), as the rectangle may cover a large area and contain a
// huge number of features.
rpc ListFeatures(Rectangle) returns (stream Feature) {}
```

- A *client-side streaming RPC* where the client writes a sequence of messages
  and sends them to the server, again using a provided stream. Once the client
  has finished writing the messages, it waits for the server to read them all
  and return its response. You specify a client-side streaming method by placing
  the `stream` keyword before the *request* type.

```
// Accepts a stream of Points on a route being traversed, returning a
// RouteSummary when traversal is completed.
rpc RecordRoute(stream Point) returns (RouteSummary) {}
```

- A *bidirectional streaming RPC* where both sides send a sequence of messages
  using a read-write stream. The two streams operate independently, so clients
  and servers can read and write in whatever order they like: for example, the
  server could wait to receive all the client messages before writing its
  responses, or it could alternately read a message then write a message, or
  some other combination of reads and writes. The order of messages in each
  stream is preserved. You specify this type of method by placing the `stream`
  keyword before both the request and the response.

```
// Accepts a stream of RouteNotes sent while a route is being traversed,
// while receiving other RouteNotes (e.g. from other users).
rpc RouteChat(stream RouteNote) returns (stream RouteNote) {}
```

Our .proto file also contains protocol buffer message type definitions for all
the request and response types used in our service methods - for example, here's
the `Point` message type:

```
// Points are represented as latitude-longitude pairs in the E7 representation
// (degrees multiplied by 10**7 and rounded to the nearest integer).
// Latitudes should be in the range +/- 90 degrees and longitude should be in
// the range +/- 180 degrees (inclusive).
message Point {
  int32 latitude = 1;
  int32 longitude = 2;
}
```


## Generating client and server code

Next we need to generate the gRPC client and server interfaces from our .proto
service definition. A large part of the work is done by the exellent
Erlang protobuf implementation
[gpb](https://github.com/tomas-abrahamsson/gpb). Some additional code is
generated to deal with the gRPC specifics.

Generating all required files can easily be done from the Erlang shell:

```
1> grpc:compile("route_guide.proto").
```

Running this command generates the following files in your current directory:

-  `route_guide.erl`, the code to encode and decode the protobuf messages
-  `route_guide_server.erl`, which contains skeleton functions for a server
-  `route_guide_client.erl`, which contains stubs to be used on the server
   side. 

These contain:

- All the protocol buffer code to populate, serialize, and retrieve our request
  and response message types
- a set of functions (or *stubs*) for clients to call to invoke the methods
  defined in the `RouteGuide` service.
- a set of ("empty") functions (or *skeleton functions*) in which you have
  to provide your implementation of the server side of the methods 
  defined in the `RouteGuide` service.


<a name="server"></a>

## Creating the server

First let's look at how we create a `RouteGuide` server. If you're only
interested in creating gRPC clients, you can skip this section and go straight
to [Creating the client](#client) (though you might find it interesting
anyway!).

There are two parts to making our `RouteGuide` service do its job:

- Providing the required code to make the generated skeleton functions 
  do the actual "work" of our service.
- Running a gRPC server to listen for requests from clients and return the
  service responses.

You can find our example `RouteGuide` server in
[examples/route_guide/server/route_guide_server.erl](/examples/route_guide/server/route_guide_server.erl).
Let's take a closer look at how it works.

### Implementing RouteGuide

As you can see, our example is a copy of the generated
`route_guide_server.erl` module with bits added to do the actual work.

In this case we're implementing a *synchronous* version of `RouteGuide`.
This means that the flow of control is determined by the client. The server
waits for a request by the client, does its processing, possibly sends back
one or more reply messages, and then waits for the next request. In general
this fits well for *simple RPC* requests, but perhaps less so for
*server-side streaming RPCs* or *bidirectional streaming RPCs*. Using
standard Erlang concepts it is not difficult to implement an *a-synchonous*
version of the service, but we won't consider that in this tutorial.

`route_guide_server.erl` contains a set of type specifications for the
messages (they will be translated to and from Erlang maps), and functions
for all our service methods. Let's look at the simplest
type first, `GetFeature`, which just gets a `Point` from the client and returns
the corresponding feature information from its database in a `Feature`.

The "empty" function that is in the generated module looks like this:

```erlang
-spec 'GetFeature'(Message::'Point'(), Stream::grpc:stream(), State::any()) ->
    {'Feature'(), grpc:stream()} | grpc:error_response().
%% This is a unary RPC
'GetFeature'(_Message, Stream, _State) ->
    {#{}, Stream}.
```

In our example implementation, the completed function looks like this:

```erlang
-spec 'GetFeature'(Message::'Point'(), Stream::grpc:stream(), State::any()) ->
    {'Feature'(), grpc:stream()} | grpc:error_response().
%% This is a unary RPC
'GetFeature'(Message, Stream, _State) ->
    Feature = #{name => find_point(Message, data()),
                location => Message}, 
    {Feature, Stream}.
```

The function is passed the client's `Point` protocol
buffer request (decoded to a map), a data structure that contains context
information about the request (or "Stream"), and some State information.

In this simple example we don't use the Stream and State information, so
we'll ignore it for now. The Stream must be passed back in the response,
because it is possible to modify it (for example by adding headers).

As the function spec indicates, the function must return a `Feature`, which
is again a map. The fields that are expected in the map can be found in the
type specification for `Feature()`, which can be found in the generated module.

Now let's look at something a bit more complicated - a streaming RPC.
`ListFeatures` is a server-side streaming RPC, so we need to send back multiple
`Features` to our client.

```erlang
-spec 'ListFeatures'(Message::'Rectangle'(), Stream::grpc:stream(), State::any()) ->    
    {['Feature'()], grpc:stream()} | grpc:error_response().
%% This is a server-to-client streaming RPC
'ListFeatures'(_Message, Stream, _State) ->
    Stream2 = grpc:send(Stream, 
                          #{name => "Louvre",
                            location => #{latitude => 4,
                                          longitude => 5}}),
    {[#{name => "Tour Eiffel",
        location => #{latitude => 3,
                      longitude => 5}}], Stream2}.
```

As you can see, this is not a "proper" implementation. It does not consider
the input at all, but it always returns the same result, which consists of
two `Features`. Note that it uses two different ways to do this: The first
`Feature` is sent to the client explictly, using `grpc:send/2`, and the
second point is passed in the return value of the function. Which way you
want to use is up to you, it would also have been possible to send all
responses using `grpc:send/2` or in the return value (but that would not
be very logical for a streaming RPC, since the response messages will then
be sent all together when all the work is done).

Note that the new `Stream` value that is returned by `grpc:send/2` must
be used from that moment on, and the final `Stream` value must be passed back
in the return value of the function.

If you look at the client-side streaming method `RecordRoute` you may
recognise that this follows a kind of 'folding' pattern, as known from
`lists:foldl/3` or `maps:fold/3`. The `RecordRoute` function will be called
for each `Point` that is received. With it you receive the result of the
previous invocation (the accumulator). You return the new value for the
accumulator. 

Regarding the input parameters there are three cases to consider:
- the first invocation receives a starting state that is specified when 
  the server is started. In this case that value is `undefined`. For more
  information on how to specify this value, see
  [starting the server](#starting).

- All following invocations receive the result of the previous invocation
  as the value for the last parameter.

- to signal that the last message was received from the client, the special
  value `eof` is passed (in stead of a message).

Regarding the return value there are two cases to consider:

- If the server considers that the answer must be sent to the client, it
  returns a tuple `{ResponseValue, Stream}`. Typically this should happen
  after receiving the `eof` input value, see above.

- If the server expects more values, it returns `{continue,
  AccumulatorValue, Stream}`.

```erlang
-spec 'RecordRoute'(Message::'Point'() | eof, Stream::grpc:stream(), State::any()) ->
    {continue, grpc:stream(), any()} |
    {'RouteSummary'(), grpc:stream()} |
    grpc:error_response().
%% This is a client-to-server streaming RPC. After the client has sent the last message,
%% this function will be called a final time with 'eof' as the first argument. This last 
%% invocation must return the response message.
'RecordRoute'(FirstPoint, Stream, undefined) ->
    %% The fact that State == undefined tells us that this is the 
    %% first point. Set the starting state, and return 'continue' to 
    %% indicate that we are not done yet.
    {continue, Stream, #{t_start => erlang:system_time(1),
                         acc => [FirstPoint]}};
'RecordRoute'(eof, Stream, #{start_time := T0, acc := Points}) ->
    %% receiving 'eof' tells us that we need to return a result.
    {#{elapsed_time => erlang:system_time(1) - T0,
       point_count => length(Points),
       feature_count => count_features(Points),
       distance => distance(Points)}, Stream};
'RecordRoute'(Point, Stream, #{acc := Acc} = State) ->
    {continue, Stream, State#{acc => [Point | Acc]}}.
```

Finally, let's look at our bidirectional streaming RPC `RouteChat()`.

```erlang
-spec 'RouteChat'(Message::'RouteNote'() | eof, Stream::grpc:stream(), State::any()) ->
    {['RouteNote'()], grpc:stream(), any()} |
    {['RouteNote'()], grpc:stream()} |
    grpc:error_response().
%% This is a bidirectional streaming RPC. If the client terminates the stream
%% this function will be called a final time with 'eof' as the first argument. 
'RouteChat'(In, Stream, undefined) ->
    'RouteChat'(In, Stream, []);
'RouteChat'(eof, Stream, _) ->
    {[], Stream};
'RouteChat'(#{location := Location} = P, Stream, Data) ->
    Messages = proplists:get_all_values(Location, Data),
    {Messages, Stream, [{Location, P} | Data]}.
```

The conventions for the invocation are exactly the same as for the
client-side streaming case, see above. 

For the return value the situation is different, because we can now send
zero or more return values after every invocation.

This time we include a list of zero or more response messages in the return
value, rather than `continue`. If we want the stream to continue we return
a 3-tuple `{[Value], Stream, NewState}` (`NewState` will be included as the
new value for the third parameter at the next invocation). If we want it to
end, we send a 2-tuple `{[Value], Stream}`.

<a name="starting"></a>

### Starting the server

Once we've implemented all our methods, we also need to start up a gRPC server
so that clients can actually use our service. The following snippet shows how we
do this for our `RouteGuide` service. Note that it will only work if both
the `route_guide_server` module and the generated encoder/decoder module
`route_guide` are on the code path.

```erlang
grpc:start_server(grpc, route_guide_server, [{port, 10000}]).
```

The first argument is the name of the server (strictly speaking: the Cowboy
listener). It can be any term. The second argument specifies the name of
the handler module. In this case we also need to specify the port, because
the `RouteGuide` service does not run on the default port. There are more
options, for example to enable compression or authentication, see *TODO*
for the details.

<a name="client"></a>

## Creating the client

In this section, we'll look at creating an Erlang client for our `RouteGuide`
service. 

### Creating a connection

The module `route_guide_client.erl` that was created when we compiled
`route_guide.proto` contains the types for the messages that are exchanged
between client and server. It also contains a number of *stubs*: functions
that can be called locally by the server, which will result in a remote
call to the server. Especially in the case of simple RPCs it may be
convenient to use these stubs. As we will see below it may be more
convenient (or even necessary) for streaming RPCs to use more general
functions to send and receive messages.

First we need to create a gRPC *connection*, specifying the server
address and port we want to connect to and optionally some additional data 
for the connection, such as TLS related options. In 
our case we'll use the simple form without TLS or other options.

```erlang
1> {ok, Connection} = grpc_client:connect(http, "localhost", 10000).
```

Now we can use the connection to create a "stream". The stream is specific
for the RPC that we are calling. Each invocation needs its own stream,
which may be used to exchange many messages between the client and the
server (if it is a streaming service). Like the server, also the client
needs to have the encoder/decoder module `route_guide` on the code path.

```erlang
2> {ok, Stream} = grpc_client:new_stream(Connection, 'RouteGuide', 'ListFeatures', route_guide).
```

### Calling service methods

Now let's look at how we call our service methods. 

#### Simple RPC

Simple RPCs follow a fixed pattern of messages that are exchanged
between the client and the server: essentially the client sends a request and the
server sends back a response (on the wire you would also see some
headers being exchanged). Since this is such simple pattern, the whole
exchange of messages can be handled by one function call:
`grpc_client:unary/6`. We don't even
have to bother about establishing a stream, this will all be handled by
`unary`.

```erlang
3> Point = #{latitude => 409146138, longitude => -746188906}.
4> grpc_client:unary(Connection, Point, 'RouteGuide', 'GetFeature', route_guide, []).
{ok,#{grpc_status => 0,
      headers => #{<<":status">> => <<"200">>},
      http_status => 200,
      result =>
          #{location =>
                #{latitude => 409146138,longitude => -746188906},
            name =>
                "Berkshire Valley Management Area Trail, Jefferson, NJ, USA"},
      status_message => <<>>,
      trailers => #{<<"grpc-status">> => <<"0">>}}}
```

As you can see, we call the function with an argument of type `Point()`,
that is: a map, and the main result is `Feature()`: another map. The
translation of these maps to and from protobufs is handled for us.

Note that in this example the function that we are calling is 
*blocking/synchronous*: this means
that the RPC call waits for the server to respond (you can specify an
optional timeout). Below we will see a more general approach
to exchange messages over a stream. This gives a lot of control, and it can
also be used to implement simple RPCs, for example if you want to have an
a-synchronous implementation or if you want have control over the processing of
headers.

To simplify things even more for simple RPCs the compilation step
generates stubs for these functions. The generated file
"route_guide_client.erl" contains a function `'GetFeature'/3` that can be
called as follows:

```erlang
5> route_guide_client:'GetFeature'(Connection, Point, []).
```

#### Streaming RPCs

Now let's look at our streaming methods. The interaction between client and
server is more complex in these cases: we cannot simply send one request
and receive an answer, but we need to establish a "Stream" to exchange
messages in both ways.

The process that we will use is not specific for any of the different types
of streaming RPCs (client-streaming, server-streaming, bidirectional
streaming). In fact, you can also use this method for simple RPCs, if you
want to call a simple RPC in an a-synchronous way.

In all cases we start by initiating a connection, and on that connection a stream. 
Let's start one for the 'RouteChat' RPC, which is a bidirectional streaming RPC.

```erlang
{ok, Connection} = grpc_client:connect(http, "localhost", 10000),
{ok, Stream} = grpc_client:new_stream(Connection, 'RouteGuide', 'RouteChat', route_guide).
```

This stream can now be used to send and receive messages. It always has to
start with a message from the client (in fact, the stream wil only be
created 'on the wire' when that happens). Let's send 2 Points.

```erlang
P1 = #{latitude => 1, longitude => 2}, 
P2 = #{latitude => 3, longitude => 5},
grpc_client:send(Stream, #{location => P1, message => "something about P1"}),
grpc_client:send(Stream, #{location => P2, message => "something about P2"}).
```

Now we can see whether we have already received and responses:

```erlang
grpc_client:get(Stream).
```

This returns `empty` - we did not yet receive anything. This is not
surprising, because the server should only send a message if it receives
information about a point that it nows something about.

We can also check using the blocking `rcv` function. Let's specify a
timeout to avoid getting stuck.

```erlang
grpc_client:rcv(Stream, 1000).
```

This returns `{error,timeout}` after one second - still no messages.

When we send some additional information for P1, we should get a response
message with the information that we sent earlier.

```erlang
grpc_client:send(Stream, #{location => P1, message => "more about P1"}),
```

Now try to get a message:

```erlang
grpc_client:get(Stream).
```

Now we get: 

```erlang
{headers,[{<<":status">>,<<"200">>}]}`. 
```

Calling it again gives: 

```erlang
{data,#{location => #{latitude => 1,longitude => 2}, 
        message => "something about P1"}}
```

So we do not only get the messages this way, but also the headers.

Bi-directional streaming RPCs such as `RouteChat` have no specific end,
they can go on forever and there is no particular way to stop them. This is
different for the other RPC types: there the client has to signal that it
has sent its last message, and the server may send a trailer which may
contain additional metadata. 

To show how this works let's look at an example for our server-streaming
RPC `ListFeatures`. We'll reuse P1 and P2 as the corner points for the area
for which we would like to know the features. This is shown below as a sequence
of commands and return values in an Erlang shell.

```erlang
2> {ok, S} = grpc_client:new_stream(Connection, 'RouteGuide', 'ListFeatures', route_guide).  
{ok,<0.155.0>}
3> grpc_client:get(S).                                                        
empty        
4> grpc_client:send_last(S, #{hi => P1, lo => P2}).                           
ok           
5> grpc_client:get(S).
{headers,[{<<":status">>,<<"200">>}]}
6> grpc_client:rcv(S).
{data,#{location => #{latitude => 4,longitude => 5},name => "Louvre"}}
7> grpc_client:rcv(S).
{data,#{location => #{latitude => 3,longitude => 5},name => "Tour Eiffel"}}
8> grpc_client:rcv(S).
{headers,[{<<"grpc-status">>,<<"0">>}]}
9> grpc_client:get(S).
eof
10> grpc_client:get(S).
eof
11> grpc_client:rcv(S).
eof
```

You will notice a few things:
-  `sent_last/2` is used to indicate that this message is the last one. For
   the `ListFeatures` we now expect to receive a number of response
   messages.
-  As long as no anwer has been received, `get/1` returns `empty`. (Using
   `rcv/1` would block).
-  Once messages have arrived, `get/1` and `rcv/1` can be used to retrieve
   information that was sent by the server.
-  `get/1` and `rcv/1` do not only return messages, but also headers. In
   this example they do not contain anything special, but they may contain
   metadata that may be relevant.
-  The server sends headers before the first message and after the last
   message. Thes headers are returned by `get/1` and `rcv/1` in the same
   way, that is, separately and in the right order.
-  After the last set of headers has been received the stream is considered 
   closed, and both `get/1` and `rcv/1` return `eof`.

## Security
gRPC has SSL/TLS integration and promotes the use of SSL/TLS to
authenticate the server, and to encrypt all the data exchanged between the
client and the server. Optional mechanisms are available for clients to
provide certificates for mutual authentication.

### Using client-side SSL/TLS

This is the simplest authentication scenario, where a client just wants to
authenticate the server and encrypt all data. 

The server has to be started so that it expects to use TLS. In this example
we want it to authenticate itself as "localhost", so it needs certificates for that
domain. Note that you must ensure that the required modules
(`route_guide_server` and also `route_guide`, the decoding module) are on
the erlang code path, and the location of the certificate files must also
be correct. The example certificates can be found in
examples/route_guide/server/certificates.

```erlang
grpc:start_server(grpc, route_guide_server, 
    [{port, 10000},
     {tls_options, [{certfile, "certificates/localhost.crt"},
                    {keyfile, "certificates/localhost.key"},
                    {cacertfile, "certificates/My_Root_CA.crt"}]}]).
```

On the client side we must now also use TLS:

```erlang
1> {ok, Connection} = grpc_client:connect(tls, "localhost", 10000).
2> {ok, S} = grpc_client:new_stream(Connection, 'RouteGuide', 'ListFeatures', route_guide).
3> grpc_client:send_last(S, #{hi => P1, lo => P2}).
ok
4> grpc_client:get(S).
{headers,[{<<":status">>,<<"200">>}]}
5> grpc_client:rcv(S).
{data,#{location => #{latitude => 4,longitude => 5},name => "Louvre"}}
...
```

To tell the server that it must authenticate the client, provide an extra
option 'client_cert_dir' which will indicate where the required
certificates are, and we must pass a few extra tls_options to ensure that
the auhtentication is enforced:

```erlang
grpc:start_server(grpc, route_guide_server, 
    [{port, 10000},
     {client_cert_dir, "certificates"},
     {tls_options, [{certfile, "certificates/localhost.crt"},
                    {keyfile, "certificates/localhost.key"},
                    {cacertfile, "certificates/My_Root_CA.crt"},
                    {fail_if_no_peer_cert, true},
                    {verify, verify_peer}]}]).
```

The client must now pass its certificate:

```erlang
1> TlsOptions = [{certfile, "certificates/127.0.0.1.crt"},
                 {keyfile, "certificates/127.0.0.1.key"},
                 {cacertfile, "certificates/My_Root_CA.crt"}].
2> {ok, Connection} = grpc_client:connect(tls, "localhost", 10000, TlsOptions).
3> {ok, S} = grpc_client:new_stream(Connection, 'RouteGuide', 'ListFeatures', route_guide).
4> grpc_client:send_last(S, #{hi => P1, lo => P2}).
...
```

## Metadata
Metadata is information about a particular RPC call (such as authentication
details) in the form of a list of key-value pairs, where the keys are
strings and the values are typically strings (but can be binary data).
Metadata is opaque to gRPC itself - it lets the client provide information
associated with the call to the server and vice versa.

### Adding metadata to a request
To add metadata to a request (from the client to the server), specify the
key-value pairs when creating the stream:

```erlang
Metadata = #{"password" => "secret"},
{ok, Stream} = grpc_client:new_stream(Connection, 'RouteGuide',
'RouteChat', route_guide, Metadata).
```

On the server side, the metadata that was sent by the client can be
retrieved from the `Stream` parameter that is passed to every service
implementation. In order to limit access to the 'GetFeature' service 
to clients that provide the password "secret" in the metadata, we could do
this:

```erlang
-spec 'GetFeature'(Message::'Point'(), Stream::grpc:stream(), State::any()) ->
    {'Feature'(), grpc:stream()} | grpc::error_response().
%% This shows how to access metadata that was sent by the client,
%% and how to send an error response.
'GetFeature'(Message, Stream, _State) ->
    case grpc:metadata(Stream) of
        #{<<"password">> := <<"secret">>} ->
            Feature = #{name => find_point(Message, data()),
                        location => Message}, 
            {Feature, Stream};
        _ -> 
            {error, 7, <<"permission denied">>, Stream}
    end.
```

### Adding metatdata to a response
The server can add metadata to the initial header that is sent to the 
client, and/or to the final trailer using `grpc:set_headers/2` or
`grpc:set_trailers/2`. A simplistic example that uses both 
variants:

```erlang
-spec 'ListFeatures'(Message::'Rectangle'(), Stream::grpc:stream(), State::any()) ->
    {['Feature'()], grpc:stream()} | grpc::error_response().
%% This adds metadata to the header and to the trailer that are sent to the client.
'ListFeatures'(_Message, Stream, _State) ->
    Stream2 = grpc:send(grpc:set_headers(Stream, 
                                             #{<<"info">> => <<"this is a test-implementation">>}), 
                          #{name => "Louvre",
                            location => #{latitude => 4,
                                          longitude => 5}}),
    Stream3 = grpc:set_trailers(Stream2, #{<<"nr_of_points_sent">> => <<"2">>}),
    {[#{name => "Tour Eiffel",
        location => #{latitude => 3,
                      longitude => 5}}], Stream3}.
```

The values will be accessible for the client in the header and trailer
messages that it will receive (also the "standard" HTTP/2 and grpc headers such as
":status" and "grpc-status" are available in this way).

```erlang
1> {ok, C} = grpc_client:connect(http, "localhost", 10000).
...
2> {ok, Stream} = grpc_client:new_stream(C, 'RouteGuide', 'ListFeatures', route_guide),
...
3> P1 = #{latitude => 1, longitude => 2}, P2 = #{latitude => 3, longitude => 5}.
...
4> grpc_client:send_last(Stream, #{hi => P1, lo => P2}).
...
5> grpc_client:rcv(Stream).
{headers,#{<<":status">> => <<"200">>,
           <<"info">> => <<"this is a test-implementation">>}}
6> grpc_client:rcv(Stream).
{data,#{location => #{latitude => 4,longitude => 5},name => "Louvre"}}
7> grpc_client:rcv(Stream).
{data,#{location => #{latitude => 3,longitude => 5},name => "Tour Eiffel"}}
8> grpc_client:rcv(Stream).
{headers,#{<<"grpc-status">> => <<"0">>,
           <<"nr_of_points_sent">> => <<"2">>}}
8> grpc_client:rcv(Stream).
eof
```

## Compression

gRPC supports compression of messages. The standard specifies several
poossible methods: gzip, deflate or snappy, and it also allows the use of
custom methods. This implementation currently only supports gzip.

On the client side, a message that is sent to the server can be compressed 
by specifying the option `{compression, gzip}` when creating the stream (or
as an option to a simple rpc in a generated client module).

```erlang
2>  {ok, Stream} = grpc_client:new_stream(C, 'RouteGuide', 'ListFeatures',
                                          route_guide,
                                          [{compression, gzip}]).
```

Or:

```erlang
3> route_guide_client:'GetFeature'(Connection, Point, [{compression, gzip}]).
```

On the server side, a message that is sent to the client can be compressed
by applying `grpc:set_compression/2` on the stream, similar to the way
metadata can be added using `grpc:set_headers/2` or `grpc:set_trailers/2`.

TODO: 
-  Timeout.
-  Description and improvement of the actual implementation of error
   handling.
