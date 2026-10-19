-module(howdy_jobs_ffi).
-export([now_ms/0, node_name/0, rescue/1, unique/0, raw_json/1]).
-export([join/2, wake/1, wake_after_commit/1, flush_wakes/0, ensure_wake_hook/0, wake_hook/1]).
-export([exit_reason/1, normal/0, stop_supervisor/2]).
-export([arguments/0, halt/1, getenv/1]).

now_ms() ->
    erlang:system_time(millisecond).

node_name() ->
    atom_to_binary(node()).

%% gleam_json's Json is iodata on Erlang, so JSON text that is known to be
%% valid can stand for itself.
raw_json(Text) ->
    Text.

unique() ->
    erlang:unique_integer([positive]).

%% Run F, turning a crash into an error with a description, so one job
%% that crashes is retried rather than taking anything else down.
rescue(F) ->
    try F() of
        Value -> {ok, Value}
    catch
        Class:Reason:Stacktrace ->
            {error, unicode:characters_to_binary(
                io_lib:format("~p: ~P~n~P", [Class, Reason, 30, Stacktrace, 30]))}
    end.

%% -- Waking producers ------------------------------------------------------
%%
%% Each producer joins the `pg` group of its queue in howdy's channel scope,
%% so a job inserted on any connected node wakes the producers of its queue
%% everywhere. A producer receives `{howdy_jobs_wake, Queue}`.

group(Queue) -> {howdy_jobs, Queue}.

join(Queue, Pid) ->
    howdy_channel_ffi:channel_join(group(Queue), Pid).

wake(Queue) ->
    howdy_channel_ffi:channel_broadcast(group(Queue), howdy_jobs_wake, Queue).

%% Inside a transaction a producer woken now would look before the job is
%% committed and find nothing, so the queues are noted and woken when the
%% outermost transaction ends (see `flush_wakes`).
-define(PENDING, howdy_jobs_pending_wakes).

wake_after_commit(Queue) ->
    Pending = case get(?PENDING) of
        undefined -> [];
        Queues -> Queues
    end,
    case lists:member(Queue, Pending) of
        true -> ok;
        false -> put(?PENDING, [Queue | Pending])
    end,
    nil.

flush_wakes() ->
    case erase(?PENDING) of
        undefined -> ok;
        Queues -> lists:foreach(fun wake/1, Queues)
    end,
    nil.

%% The hook howdy/database runs around each outermost transaction. It wakes
%% whatever the transaction queued once it has ended; after a rollback the
%% wake finds nothing, which is harmless. Registered once per node.
ensure_wake_hook() ->
    case persistent_term:get(howdy_jobs_wake_hook, false) of
        true ->
            nil;
        false ->
            howdy_database_ffi:around_transactions(<<"howdy_jobs">>, fun ?MODULE:wake_hook/1),
            persistent_term:put(howdy_jobs_wake_hook, true),
            nil
    end.

wake_hook(Run) ->
    try Run() after flush_wakes() end.

%% -- Stopping -----------------------------------------------------------------

exit_reason(normal) -> normal;
exit_reason(killed) -> killed;
exit_reason({abnormal, Reason}) -> Reason.

normal() -> normal.

%% Stop a supervisor the caller started and linked to, waiting for its
%% children to stop in turn.
stop_supervisor(Pid, Timeout) ->
    unlink(Pid),
    Ref = monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, process, Pid, _} -> nil
    after Timeout ->
        exit(Pid, kill),
        receive {'DOWN', Ref, process, Pid, _} -> nil end
    end.

%% -- Command line -----------------------------------------------------------------

arguments() ->
    [unicode:characters_to_binary(A) || A <- init:get_plain_arguments()].

halt(Code) -> erlang:halt(Code).

getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.
