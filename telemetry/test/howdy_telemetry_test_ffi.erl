-module(howdy_telemetry_test_ffi).
-export([rescue/1, websocket_roundtrip/3, crash_process/1, putenv/2, unsetenv/1,
         recorder_owners/0, hold_recorder/1, release/1, default_formatter/0,
         handler_formats/2]).

rescue(Run) ->
    try {ok, Run()} catch _:_ -> {error, nil} end.

%% Open a websocket to 127.0.0.1:Port at Path, send one masked text frame,
%% wait for the echo, and close.
websocket_roundtrip(Port, Path, Text) ->
    {ok, Socket} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}]),
    Key = base64:encode(crypto:strong_rand_bytes(16)),
    ok = gen_tcp:send(Socket, [<<"GET ">>, Path, <<" HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                                "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                                "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ">>, Key,
                               <<"\r\n\r\n">>]),
    {ok, <<"HTTP/1.1 101", _/binary>>} = gen_tcp:recv(Socket, 0, 2000),
    Mask = crypto:strong_rand_bytes(4),
    Masked = mask(Text, Mask),
    ok = gen_tcp:send(Socket, <<1:1, 0:3, 1:4, 1:1, (byte_size(Text)):7, Mask/binary, Masked/binary>>),
    {ok, Reply} = gen_tcp:recv(Socket, 0, 2000),
    gen_tcp:close(Socket),
    Reply.

mask(Data, <<M:4/binary>>) ->
    << <<(B bxor binary:at(M, I rem 4))>> || {B, I} <- lists:zip(binary_to_list(Data), lists:seq(0, byte_size(Data) - 1)) >>.

%% A proc_lib process that crashes outside any span, as a worker would,
%% with `Secret` everywhere a crash report looks: its dictionary, its
%% mailbox and the arguments of the call that fails.
crash_process(Secret) ->
    Pid = proc_lib:spawn(fun() ->
        put(password, Secret),
        self() ! {login, Secret},
        _ = binary_to_integer(Secret),
        error(worker_gave_up)
    end),
    Ref = erlang:monitor(process, Pid),
    receive {'DOWN', Ref, process, Pid, _} -> ok end,
    nil.

%% How many recorder owners the package's supervisor holds.
recorder_owners() ->
    length(supervisor:which_children(howdy_telemetry_recorder_sup)).

%% A process that makes a recorder and keeps it until `release`.
hold_recorder(Keep) ->
    Parent = self(),
    Pid = spawn(fun() ->
        _ = howdy_telemetry_recorder:new(Keep),
        Parent ! {ready, self()},
        receive release -> ok end
    end),
    receive {ready, Pid} -> Pid end.

release(Pid) ->
    Ref = erlang:monitor(process, Pid),
    Pid ! release,
    receive {'DOWN', Ref, process, Pid, _} -> ok end,
    nil.

putenv(Name, Value) ->
    os:putenv(binary_to_list(Name), binary_to_list(Value)),
    nil.

unsetenv(Name) ->
    os:unsetenv(binary_to_list(Name)),
    nil.

%% Does the log handler format a line at `Level` when it has `Recorders`?
%% The handler runs in the calling process, so a report whose callback
%% tells this process when it runs settles that before `log` returns.
handler_formats(Level, Recorders) ->
    Self = self(),
    Ref = make_ref(),
    Event = #{level => binary_to_existing_atom(Level),
              msg => {report, #{what => probe}},
              meta => #{time => erlang:system_time(microsecond),
                        report_cb => fun(_) -> Self ! {formatted, Ref}, {"probe", []} end}},
    ok = howdy_telemetry_logs:log(Event, #{config => #{recorders => Recorders}}),
    receive {formatted, Ref} -> true after 0 -> false end.

%% The module formatting the default handler's output.
default_formatter() ->
    {ok, #{formatter := {Module, _}}} = logger:get_handler_config(default),
    atom_to_binary(Module).
