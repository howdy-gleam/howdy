%% Raw HTTP/1.1 clients for the event stream and chunked body tests, so the
%% bytes on the wire can be checked exactly.
-module(howdy_sse_test_ffi).
-export([open_get/3, recv_until/3, recv_all/1, close/1, elapsed/1]).

%% Send a GET with extra headers; returns the socket.
open_get(Port, Path, Headers) ->
    {ok, S} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}], 2000),
    Extra = [[Name, ": ", Value, "\r\n"] || {Name, Value} <- Headers],
    ok = gen_tcp:send(S, ["GET ", Path, " HTTP/1.1\r\nHost: localhost\r\n",
                          Extra, "\r\n"]),
    S.

%% Read until the bytes so far contain Needle; returns all of them.
recv_until(S, Needle, Timeout) ->
    recv_until(S, Needle, Timeout, <<>>).
recv_until(S, Needle, Timeout, Acc) ->
    case binary:match(Acc, Needle) of
        {_, _} -> {ok, Acc};
        nomatch ->
            case gen_tcp:recv(S, 0, Timeout) of
                {ok, More} -> recv_until(S, Needle, Timeout, <<Acc/binary, More/binary>>);
                {error, _} -> {error, Acc}
            end
    end.

%% Read until the server closes the socket.
recv_all(S) -> recv_all(S, <<>>).
recv_all(S, Acc) ->
    case gen_tcp:recv(S, 0, 5000) of
        {ok, More} -> recv_all(S, <<Acc/binary, More/binary>>);
        {error, closed} -> Acc;
        {error, timeout} -> error({still_open, Acc})
    end.

close(S) -> gen_tcp:close(S), nil.

%% How long Fun takes, in milliseconds.
elapsed(Fun) ->
    Start = erlang:monotonic_time(millisecond),
    Fun(),
    erlang:monotonic_time(millisecond) - Start.
