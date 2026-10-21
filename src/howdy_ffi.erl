%% Node-wide odds and ends for the howdy package: the console registry, the
%% disconnect log filter, a server's shared handler, stopping a server,
%% rescuing a crashed handler, throttled warnings and the environment. Query
%% parsing, rate limiting and WebSocket channels each have their own module.
-module(howdy_ffi).
-export([console_put/2, console_get/1]).
-export([share_handler/1, call_shared/2, forget_when_down/2, forget_handler/1,
         shared_handlers/0]).
-export([quiet_disconnects/0, log_disconnects/0, stop_server/2]).
-export([rescue/1, warn_at_most_every/2, getenv/1]).
-export([cleanup/2]).

%% -- Console ---------------------------------------------------------------------

console_put(Name, Value) ->
    persistent_term:put({howdy_console, Name}, Value),
    nil.

console_get(Name) ->
    Missing = make_ref(),
    case persistent_term:get({howdy_console, Name}, Missing) of
        Missing -> {error, nil};
        Value -> {ok, Value}
    end.

%% -- A server's handler ------------------------------------------------------------
%%
%% A server's handler closes over the app's every route, and the routes over
%% whatever the app gave them, such as its services. Within one term all of
%% that is shared, but a term sent to another process is copied flat: each
%% shared part once for every place it is referred to. The web server hands
%% its handler to each acceptor and connection process, so an app whose
%% routes share large values took tens of megabytes a process, gigabytes in
%% all. Instead the handler is kept as a persistent term, which every
%% process reads in place, and the server is given a closure holding only
%% its key.

share_handler(Handler) ->
    Key = {howdy_handler, make_ref()},
    persistent_term:put(Key, Handler),
    Key.

call_shared(Key, Request) ->
    (persistent_term:get(Key))(Request).

%% Forget the handler once the server has gone, however it went: stopped,
%% killed, or ended by its supervisor, which may start another.
forget_when_down(Key, Server) ->
    spawn(fun() ->
        Ref = monitor(process, Server),
        receive {'DOWN', Ref, process, Server, _} -> forget_handler(Key) end
    end),
    nil.

forget_handler(Key) ->
    _ = persistent_term:erase(Key),
    nil.

%% How many handlers are kept, for tests.
shared_handlers() ->
    length([K || {{howdy_handler, _} = K, _} <- persistent_term:get()]).

%% -- Quiet disconnects -----------------------------------------------------------
%%
%% A client that goes away while ewe is writing to it, such as a browser tab
%% closing mid WebSocket close handshake, ends its connection process with a
%% plain socket error. OTP reports each one as a crash: a supervisor report
%% from the connection pool and a crash report from the process. Nothing went
%% wrong on the server, so this primary logger filter drops exactly those
%% reports: an exit whose reason is one of the socket errors below, from a
%% temporary child of a factory supervisor. Every other report passes.

-define(DISCONNECT_FILTER, howdy_quiet_disconnects).

quiet_disconnects() ->
    case logger:add_primary_filter(?DISCONNECT_FILTER,
                                   {fun drop_disconnect/2, nil}) of
        ok -> nil;
        {error, {already_exist, _}} -> nil
    end.

log_disconnects() ->
    _ = logger:remove_primary_filter(?DISCONNECT_FILTER),
    nil.

%% -- Stopping ------------------------------------------------------------------
%%
%% The server is a supervisor that traps exits, so a `shutdown` exit makes it
%% stop its children in order: the listener first, then each connection with
%% the shutdown timeout to finish. Waiting for its DOWN means the caller sees
%% the port free once this returns.

%% A server that has not finished a minute after its drain timeout is
%% wedged, and killed rather than waited on forever.
stop_server(Pid, DrainMs) ->
    unlink(Pid),
    Ref = monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, process, Pid, _} -> nil
    after DrainMs + 60000 ->
        exit(Pid, kill),
        receive {'DOWN', Ref, process, Pid, _} -> nil end
    end.

drop_disconnect(#{msg := {report, #{label := {supervisor, child_terminated},
                                    report := Report}}} = Event, _) ->
    Reason = proplists:get_value(reason, Report),
    Offender = proplists:get_value(offender, Report, []),
    case disconnect_reason(Reason) andalso pooled_connection(Offender) of
        true -> stop;
        false -> Event
    end;
drop_disconnect(#{msg := {report, #{label := {proc_lib, crash},
                                    report := [Crash | _]}}} = Event, _) ->
    case proplists:get_value(error_info, Crash) of
        {exit, Reason, Stack} ->
            case disconnect_reason(Reason) andalso tup_exit(Stack) of
                true -> stop;
                false -> Event
            end;
        _ -> Event
    end;
drop_disconnect(Event, _) ->
    Event.

%% The exit must have been raised by tup itself, so a handler that happens to
%% exit with the same words is still reported.
tup_exit([{tup_ffi, exit_with, _, _} | _]) -> true;
tup_exit(_) -> false.

pooled_connection(Offender) ->
    case {proplists:get_value(mfargs, Offender),
          proplists:get_value(restart_type, Offender)} of
        {{gleam@otp@factory_supervisor, _, _}, temporary} -> true;
        _ -> false
    end.

%% How tup, ewe's connection pool, words the socket errors that mean the
%% client has gone.
disconnect_reason(<<"the socket is closed">>) -> true;
disconnect_reason(<<"the peer reset the connection">>) -> true;
disconnect_reason(<<"an argument was invalid">>) -> true;
disconnect_reason(<<"the connection was reset by the network">>) -> true;
disconnect_reason(<<"the socket is not connected">>) -> true;
disconnect_reason(<<"the write end is closed">>) -> true;
disconnect_reason(<<"the connection timed out">>) -> true;
disconnect_reason(_) -> false.

%% -- Rescue --------------------------------------------------------------------
%%
%% Run a handler and turn a crash into `{error, Description}` after logging
%% it with its stack trace, so the request can still be answered.

rescue(Fun) ->
    try
        {ok, Fun()}
    catch
        Class:Reason:Stack ->
            logger:error(#{msg => "howdy: handler crashed",
                           class => Class, reason => Reason, stacktrace => Stack}),
            {error, unicode:characters_to_binary(io_lib:format("~p:~0tP", [Class, Reason, 8]))}
    end.

%% -- Cleanup -------------------------------------------------------------------
%%
%% Run a test, then its cleanup whether the test returned or crashed; a
%% crash carries on after the cleanup, so the test still fails.

cleanup(After, Run) ->
    try
        Run()
    after
        After()
    end.

%% -- Throttled warnings ----------------------------------------------------------
%%
%% True at most once per `IntervalMs` for a `Key`, so a store outage logs once
%% per window rather than once per request. The last time is a persistent_term
%% written only when the interval has passed, which is rare.

warn_at_most_every(Key, IntervalMs) ->
    Now = erlang:monotonic_time(millisecond),
    Term = {howdy_warned, Key},
    case persistent_term:get(Term, undefined) of
        Last when is_integer(Last), Now - Last < IntervalMs -> false;
        _ -> persistent_term:put(Term, Now), true
    end.

%% -- Environment -------------------------------------------------------------------

getenv(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.
