-module(howdy_database_test_ffi).
-export([lock_serializes/0, lock_reentrant/0, lock_holder_exit/0,
         lock_server_restart/0, children/1, putenv/2, unsetenv/1,
         crashes/1]).

%% The pids of a supervisor's running children.
children(Supervisor) ->
    [Pid || {_, Pid, _, _} <- supervisor:which_children(Supervisor), is_pid(Pid)].

lock_serializes() ->
    Lock = make_ref(),
    Parent = self(),
    Counter = atomics:new(1, []),
    Workers = [spawn_monitor(fun() ->
        lists:foreach(fun(_) ->
            howdy_database_ffi:with_lock(Lock, fun() ->
                1 = atomics:add_get(Counter, 1, 1),
                timer:sleep(1),
                0 = atomics:sub_get(Counter, 1, 1)
            end)
        end, lists:seq(1, 10)),
        Parent ! {done, self()}
    end) || _ <- lists:seq(1, 8)],
    lists:foreach(fun({Pid, Monitor}) ->
        receive {done, Pid} -> ok after 5000 -> error(lock_timeout) end,
        receive {'DOWN', Monitor, process, Pid, normal} -> ok
        after 1000 -> error(worker_failed) end
    end, Workers),
    atomics:get(Counter, 1) =:= 0.

lock_reentrant() ->
    Lock = make_ref(),
    howdy_database_ffi:with_lock(Lock, fun() ->
        howdy_database_ffi:with_lock(Lock, fun() -> true end)
    end).

lock_holder_exit() ->
    Lock = make_ref(),
    Parent = self(),
    {Holder, Monitor} = spawn_monitor(fun() ->
        howdy_database_ffi:with_lock(Lock, fun() ->
            Parent ! {holding, self()},
            receive stop -> ok end
        end)
    end),
    receive {holding, Holder} -> ok after 1000 -> error(lock_timeout) end,
    exit(Holder, kill),
    receive {'DOWN', Monitor, process, Holder, killed} -> ok
    after 1000 -> error(holder_did_not_exit) end,
    howdy_database_ffi:with_lock(Lock, fun() -> true end).

%% Killing the server while a lock is held must not leave a waiter blocked
%% forever: it exits with the lost-server reason, the supervisor restarts the
%% server, and the lock is usable again.
lock_server_restart() ->
    Lock = make_ref(),
    Parent = self(),
    {Holder, HolderMonitor} = spawn_monitor(fun() ->
        howdy_database_ffi:with_lock(Lock, fun() ->
            Parent ! {holding, self()},
            receive stop -> ok end
        end)
    end),
    receive {holding, Holder} -> ok after 1000 -> error(lock_timeout) end,
    {Waiter, WaiterMonitor} = spawn_monitor(fun() ->
        howdy_database_ffi:with_lock(Lock, fun() -> ok end)
    end),
    wait_until(fun() ->
        case sys:get_state(howdy_database_locks) of
            #{Lock := {Holder, _, Waiters}} -> queue:len(Waiters) =:= 1;
            _ -> false
        end
    end, waiter_not_queued),
    Old = whereis(howdy_database_locks),
    exit(Old, kill),
    receive
        {'DOWN', WaiterMonitor, process, Waiter, {howdy_database_locks_lost, Lock, killed}} -> ok
    after 1000 -> error(waiter_deadlocked)
    end,
    Holder ! stop,
    receive {'DOWN', HolderMonitor, process, Holder, normal} -> ok
    after 1000 -> error(holder_failed) end,
    wait_until(fun() ->
        case whereis(howdy_database_locks) of
            undefined -> false;
            New -> New =/= Old
        end
    end, server_not_restarted),
    howdy_database_ffi:with_lock(Lock, fun() -> true end).

wait_until(Check, Failure) -> wait_until(Check, Failure, 100).

wait_until(_Check, Failure, 0) -> error(Failure);
wait_until(Check, Failure, Tries) ->
    case Check() of
        true -> ok;
        false -> timer:sleep(10), wait_until(Check, Failure, Tries - 1)
    end.

putenv(Name, Value) ->
    true = os:putenv(unicode:characters_to_list(Name), unicode:characters_to_list(Value)),
    nil.

unsetenv(Name) ->
    true = os:unsetenv(unicode:characters_to_list(Name)),
    nil.

%% Run Fun, turning any exception it raises into {error, nil}.
crashes(Fun) ->
    try {ok, Fun()}
    catch _:_ -> {error, nil}
    end.
