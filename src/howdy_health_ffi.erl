%% Health checks for `howdy/health`.
%%
%% Every check runs in a process of its own, all at once, and the caller
%% waits at most the timeout for them. A check still running then is killed
%% and reported as `{error, nil}`; one that crashed is `{ok, {error, Why}}`.
%%
%% The caller is a connection process, so a check that finishes late must
%% not leave a message in its mailbox. Replies come through an alias, which
%% is deactivated before returning: later sends to it are dropped, and any
%% that arrived in the meantime are flushed.

-module(howdy_health_ffi).
-export([run_all/2]).

run_all(Checks, TimeoutMs) ->
    Alias = erlang:alias(),
    Indexed = lists:zip(lists:seq(1, length(Checks)), Checks),
    Pids = [spawn(fun() -> Alias ! {Alias, I, run(Check)} end)
            || {I, Check} <- Indexed],
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    Done = collect(Alias, length(Checks), Deadline, #{}),
    erlang:unalias(Alias),
    [exit(Pid, kill) || Pid <- Pids],
    flush(Alias),
    [maps:get(I, Done, {error, nil}) || {I, _} <- Indexed].

run(Check) ->
    try
        {ok, Check()}
    catch
        Class:Reason ->
            {ok, {error, unicode:characters_to_binary(
                           io_lib:format("crashed: ~p:~0tP", [Class, Reason, 8]))}}
    end.

collect(_Alias, 0, _Deadline, Done) ->
    Done;
collect(Alias, Left, Deadline, Done) ->
    Wait = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Alias, I, Outcome} -> collect(Alias, Left - 1, Deadline, Done#{I => Outcome})
    after Wait ->
        Done
    end.

flush(Alias) ->
    receive
        {Alias, _, _} -> flush(Alias)
    after 0 ->
        ok
    end.
