-module(live_socket_test_ffi).
-export([open_websocket/2, receive_text/1, close_socket/1]).

%% Open a WebSocket at Path on a local port. Returns the raw socket with any
%% bytes that arrived in the same segment as the handshake response, so the
%% connection can be read from and dropped from the client side.
open_websocket(Port, Path) ->
    {ok, S} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    ok = gen_tcp:send(S, [<<"GET ">>, Path, <<" HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                           "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                           "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
                           "Sec-WebSocket-Version: 13\r\n\r\n">>]),
    Response = read_handshake(S, <<>>),
    <<"HTTP/1.1 101", _/binary>> = Response,
    [_, Rest] = binary:split(Response, <<"\r\n\r\n">>),
    {S, Rest}.

read_handshake(S, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        nomatch ->
            {ok, Data} = gen_tcp:recv(S, 0, 5000),
            read_handshake(S, <<Acc/binary, Data/binary>>);
        _ ->
            Acc
    end.

%% The next bytes from the server after the handshake: enough to see that
%% the runtime's first render reached this connection.
receive_text({S, <<>>}) ->
    case gen_tcp:recv(S, 0, 5000) of
        {ok, Data} -> {ok, Data};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end;
receive_text({_, Rest}) ->
    {ok, Rest}.

close_socket({S, _}) ->
    gen_tcp:close(S),
    nil.
