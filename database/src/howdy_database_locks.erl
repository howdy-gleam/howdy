-module(howdy_database_locks).
-behaviour(gen_server).
-export([start_link/0, acquire/1, release/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% A fair mutex per key, normally a Repo. One small server hands each key's
%% lock to waiters in arrival order, so contention costs a message round trip
%% rather than the randomised sleeps of global:trans. A lock is released when
%% its holder asks or dies; a waiter that dies leaves the queue.
%%
%% The server is a permanent child of the howdy_database supervisor, so it is
%% up before any caller needs it and comes back if it crashes. What a restart
%% guarantees: the new server starts with no locks, every waiter blocked in
%% acquire/1 exits (howdy_database_ffi:with_lock turns that into
%% {howdy_database_locks_lost, Lock, Reason}) rather than being granted a lock
%% an old holder still runs under, and the stop is logged with the number of
%% locks it abandoned. What it cannot guarantee: holders that were already
%% running keep running, unlocked, until they finish; the first acquirer of
%% each key on the new server runs beside them. A caller that must not
%% overlap retries under its own supervision, not by catching the exit.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Blocks until the calling process holds Lock. Not reentrant: with_lock
%% tracks that in the caller's process dictionary.
acquire(Lock) ->
    gen_server:call(?MODULE, {acquire, Lock}, infinity).

release(Lock) ->
    gen_server:cast(?MODULE, {release, self(), Lock}).

%% State maps Lock => {Holder, HolderMonitor, Waiters}, where Waiters is a
%% queue of {From, Monitor}.
init([]) ->
    %% Run terminate/2 on a supervisor shutdown, so an abandoned lock is logged.
    process_flag(trap_exit, true),
    {ok, #{}}.

handle_call({acquire, Lock}, {Pid, _} = From, Locks) ->
    Monitor = erlang:monitor(process, Pid),
    case Locks of
        #{Lock := {Holder, HolderMonitor, Waiters}} ->
            Waiting = queue:in({From, Monitor}, Waiters),
            {noreply, Locks#{Lock := {Holder, HolderMonitor, Waiting}}};
        _ ->
            {reply, ok, Locks#{Lock => {Pid, Monitor, queue:new()}}}
    end;
handle_call(_Request, _From, Locks) ->
    {reply, {error, unsupported_request}, Locks}.

handle_cast({release, Pid, Lock}, Locks) ->
    case Locks of
        #{Lock := {Pid, Monitor, Waiters}} ->
            erlang:demonitor(Monitor, [flush]),
            {noreply, grant_next(Lock, Waiters, Locks)};
        _ ->
            {noreply, Locks}
    end;
handle_cast(_Message, Locks) ->
    {noreply, Locks}.

handle_info({'DOWN', Monitor, process, _Pid, _}, Locks) ->
    {noreply, maps:fold(
        fun(Lock, {Holder, HolderMonitor, Waiters}, Acc) ->
            case HolderMonitor of
                Monitor ->
                    grant_next(Lock, Waiters, Acc);
                _ ->
                    Alive = queue:filter(fun({_, M}) -> M =/= Monitor end, Waiters),
                    Acc#{Lock := {Holder, HolderMonitor, Alive}}
            end
        end,
        Locks,
        Locks
    )};
handle_info(_Message, Locks) ->
    {noreply, Locks}.

terminate(Reason, Locks) when map_size(Locks) > 0 ->
    logger:warning(
        "howdy_database_locks stopping (~p) with ~p lock(s) held: holders keep "
        "running unlocked and waiters exit",
        [Reason, map_size(Locks)]
    );
terminate(_Reason, _Locks) ->
    ok.

grant_next(Lock, Waiters, Locks) ->
    case queue:out(Waiters) of
        {{value, {{Pid, _} = From, Monitor}}, Rest} ->
            gen_server:reply(From, ok),
            Locks#{Lock := {Pid, Monitor, Rest}};
        {empty, _} ->
            maps:remove(Lock, Locks)
    end.
