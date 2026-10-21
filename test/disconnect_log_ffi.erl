-module(disconnect_log_ffi).
-export([with_captured_reports/2, drop_mid_close/1, exit_with/2]).
-export([log/2]).

%% Run `Run`, collecting the supervisor and crash reports that reach logger
%% handlers meanwhile, after primary filters have had their say.
with_captured_reports(Server, Run) ->
    Id = howdy_test_capture,
    Self = self(),
    ok = logger:add_handler(Id, ?MODULE, #{config => Self}),
    try
        Run(),
        %% Reports are written by the connection as it exits and by its
        %% supervisor as it handles that exit, so once no connection is
        %% left and the supervisor has answered, every report is in.
        howdy_test_ffi:await_no_connections(Server),
        collect([])
    after
        logger:remove_handler(Id)
    end.

log(#{msg := {report, #{label := Label}}}, #{config := Pid})
  when Label =:= {supervisor, child_terminated}; Label =:= {proc_lib, crash} ->
    Pid ! {captured_report, Label};
log(_Event, _Config) ->
    ok.

collect(Reports) ->
    receive
        {captured_report, Label} -> collect([Label | Reports])
    after 0 ->
        length(Reports)
    end.

%% Open a WebSocket, send a close frame and hang up without waiting for the
%% reply, as a closing browser tab does. Repeated so the race is hit.
drop_mid_close(Port) ->
    lists:foreach(fun(_) ->
        {ok, S} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
        ok = gen_tcp:send(S, <<"GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                               "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                               "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
                               "Sec-WebSocket-Version: 13\r\n\r\n">>),
        {ok, <<"HTTP/1.1 101", _/binary>>} = gen_tcp:recv(S, 0, 2000),
        inet:setopts(S, [{linger, {true, 0}}]),
        gen_tcp:send(S, <<16#88, 16#82, 1, 2, 3, 4, 2, 234>>),
        gen_tcp:close(S)
    end, lists:seq(1, 10)),
    nil.

%% Kill `Pid` with a binary `Reason`, as a crashed connection exits.
exit_with(Pid, Reason) ->
    exit(Pid, Reason),
    nil.
