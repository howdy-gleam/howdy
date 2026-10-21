-module(howdy_database_ffi).
-export([with_lock/2, around_runs/2, run_hooks/0, around_transactions/2, outermost_transaction/1,
         in_transaction/0, monotonic_ms/0]).

%% Run with the fair, reentrant lock for Lock held. The lock server is
%% howdy_database_locks; Run executes in the calling process, which keeps
%% Gloo's transaction and the caller's mailbox where they belong. Reentrancy
%% is tracked here, in the caller's process dictionary, so the server only
%% ever sees one acquire per holder. If the server stops while this process
%% waits, the wait exits with {howdy_database_locks_lost, Lock, Reason}; see
%% howdy_database_locks for what a restart does and does not guarantee.
with_lock(Lock, Run) ->
    Key = {howdy_database_lock, Lock},
    case get(Key) of
        true ->
            Run();
        _ ->
            acquire(Lock),
            put(Key, true),
            try
                Run()
            after
                erase(Key),
                howdy_database_locks:release(Lock)
            end
    end.

acquire(Lock) ->
    ensure_started(),
    try
        howdy_database_locks:acquire(Lock)
    catch
        exit:{Reason, {gen_server, call, _}} ->
            exit({howdy_database_locks_lost, Lock, Reason})
    end.

%% Normal Gleam startup starts the howdy_database application and its
%% supervised lock server before anything locks. Preserve lazy use from a
%% caller outside a release boot by delegating startup to OTP, which
%% serialises concurrent starts and reports failures.
ensure_started() ->
    case whereis(howdy_database_locks) of
        undefined ->
            case application:ensure_all_started(howdy_database) of
                {ok, _} -> ok;
                {error, Reason} -> erlang:error({howdy_database_start_failed, Reason})
            end;
        _ ->
            ok
    end.

%% Hooks bracketing migration runs on this node, in name order. Registration
%% is rare and idempotent, so persistent_term's update cost is not paid twice.
around_runs(Name, Hook) -> register_hook(howdy_database_run_hooks, Name, Hook).

run_hooks() -> hooks(howdy_database_run_hooks).

%% Hooks bracketing the outermost Howdy transaction in a process. Nested
%% transactions, whichever Repo or pog connection they use, run bare.
around_transactions(Name, Hook) ->
    register_hook(howdy_database_transaction_hooks, Name, Hook).

outermost_transaction(Run) ->
    Key = howdy_database_transaction_depth,
    case get(Key) of
        undefined ->
            put(Key, 1),
            Wrapped = lists:foldr(
                fun(Hook, Inner) -> fun() -> Hook(Inner) end end,
                Run,
                hooks(howdy_database_transaction_hooks)
            ),
            try Wrapped() after erase(Key) end;
        _ ->
            Run()
    end.

in_transaction() ->
    get(howdy_database_transaction_depth) =/= undefined.

register_hook(Registry, Name, Hook) ->
    with_lock(Registry, fun() ->
        case persistent_term:get(Registry, #{}) of
            #{Name := Hook} -> nil;
            Hooks -> persistent_term:put(Registry, Hooks#{Name => Hook}), nil
        end
    end).

hooks(Registry) ->
    [Hook || {_, Hook} <- lists:sort(maps:to_list(persistent_term:get(Registry, #{})))].

monotonic_ms() ->
    erlang:monotonic_time(millisecond).
