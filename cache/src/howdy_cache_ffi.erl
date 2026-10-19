%% Transaction deferral and the in-memory store for howdy/cache.
-module(howdy_cache_ffi).
-export([in_transaction/1, inside_transaction/0, defer/1, digest/1,
         system_ms/0, start_sweeper/2, flights_new/0, flight/4]).
-export([memory_new/2, memory_read/2, memory_versions/2, memory_write/5,
         memory_delete/2, memory_invalidate/2, memory_clear/1]).

%% -- Transactions --------------------------------------------------------------
%%
%% howdy/database runs this hook around the outermost transaction of each
%% process. Work deferred while it runs is kept in the process dictionary
%% and done once the transaction has ended, however it ended. The list is
%% taken out of the dictionary before any of it runs, so work that opens a
%% transaction of its own is not deferred again.
-define(PENDING, howdy_cache_pending).

in_transaction(Run) ->
    put(?PENDING, []),
    try Run()
    after finish()
    end.

finish() ->
    Pending = case erase(?PENDING) of
        undefined -> [];
        List -> lists:reverse(List)
    end,
    lists:foreach(
        fun(Fun) ->
            try Fun()
            catch Class:Reason:Stack ->
                logger:warning(#{msg => "howdy_cache: deferred work crashed",
                                 class => Class, reason => Reason,
                                 stacktrace => Stack})
            end
        end,
        Pending).

inside_transaction() ->
    get(?PENDING) =/= undefined.

defer(Fun) ->
    case get(?PENDING) of
        undefined ->
            false;
        Pending ->
            put(?PENDING, [Fun | Pending]),
            true
    end.

digest(Bin) ->
    crypto:hash(sha256, Bin).

system_ms() ->
    erlang:system_time(millisecond).

%% -- Single flight -------------------------------------------------------------
%%
%% Concurrent misses for one key on this node share one computation. The
%% first caller inserts {Key, Pid, Ref} into the flights table and computes.
%% Later callers register {Ref, Pid} in the waiters table under that
%% flight's Ref, check the flight is still there, and wait for the leader's
%% answer: its result, errors included, or `retry` if the computation
%% raised. The leader deletes its flight before it takes its waiters, so a
%% waiter that registers too late finds the flight gone, removes its own
%% registration and starts over, and one that registers in time is always
%% answered. Waiters monitor the leader; if it dies they remove the flight
%% it left behind and start over. A process already leading a flight never
%% waits for another, so two leaders cannot wait for each other.
%%
%% Callers sharing a flight may read the key with different codecs, so a
%% waiter is never handed the leader's value itself, only what Share makes
%% of it (the JSON text, or the error), for the caller to decode with its
%% own codec. The result is {led, Result} or {joined, Shared}.
flights_new() ->
    Owner = self(),
    Ready = make_ref(),
    Keeper = spawn(fun() ->
        Flights = ets:new(howdy_cache_flights, [set, public, {write_concurrency, true}]),
        Waiters = ets:new(howdy_cache_waiters, [bag, public, {write_concurrency, true}]),
        Ref = monitor(process, Owner),
        Owner ! {Ready, {Flights, Waiters}},
        receive {'DOWN', Ref, process, _, _} -> ok end
    end),
    receive
        {Ready, Tables} -> Tables
    after 5000 ->
        exit(Keeper, kill),
        error({howdy_cache, flights_did_not_start})
    end.

-define(LEADING, howdy_cache_leading).

flight(Flights, Key, Compute, Share) ->
    flight(Flights, Key, {Compute, Share}).

flight(Tables = {Flights, _}, Key, Job = {Compute, _}) ->
    Ref = make_ref(),
    case ets:insert_new(Flights, {Key, self(), Ref}) of
        true ->
            lead(Tables, Key, Ref, Job);
        false ->
            case ets:lookup(Flights, Key) of
                [] ->
                    flight(Tables, Key, Job);
                [{_, Leader, LeaderRef}] ->
                    %% A leader never waits, not even for another key: two
                    %% leaders each waiting for the other's key would wait
                    %% forever. It computes this one itself.
                    case Leader =:= self() orelse get(?LEADING) =/= undefined of
                        true -> {led, Compute()};
                        false -> join(Tables, Key, Job, Leader, LeaderRef)
                    end
            end
    end.

lead({Flights, Waiters}, Key, Ref, {Compute, Share}) ->
    Depth = case get(?LEADING) of undefined -> 0; D -> D end,
    put(?LEADING, Depth + 1),
    Outcome = try {ok, Compute()}
              catch Class:Reason:Stack -> {raised, Class, Reason, Stack}
              end,
    case Depth of
        0 -> erase(?LEADING);
        _ -> put(?LEADING, Depth)
    end,
    ets:delete_object(Flights, {Key, self(), Ref}),
    case ets:take(Waiters, Ref) of
        [] ->
            ok;
        Waiting ->
            Answer = case Outcome of
                {ok, Result} ->
                    try {ok, Share(Result)} catch _:_ -> retry end;
                _ ->
                    retry
            end,
            [Pid ! {howdy_cache_flight, Ref, Answer} || {_, Pid} <- Waiting]
    end,
    case Outcome of
        {ok, Value} -> {led, Value};
        {raised, C, R, S} -> erlang:raise(C, R, S)
    end.

join(Tables = {Flights, Waiters}, Key, Job, Leader, LeaderRef) ->
    Monitor = monitor(process, Leader),
    ets:insert(Waiters, {LeaderRef, self()}),
    case ets:lookup(Flights, Key) of
        [{_, Leader, LeaderRef}] ->
            await(Tables, Key, Job, Leader, LeaderRef, Monitor);
        _ ->
            %% Finished meanwhile. If the leader took the registration it
            %% is about to answer; otherwise no answer is coming.
            case unregister(Waiters, LeaderRef) of
                true ->
                    demonitor(Monitor, [flush]),
                    flight(Tables, Key, Job);
                false ->
                    await(Tables, Key, Job, Leader, LeaderRef, Monitor)
            end
    end.

await(Tables = {Flights, Waiters}, Key, Job, Leader, LeaderRef, Monitor) ->
    receive
        {howdy_cache_flight, LeaderRef, {ok, Shared}} ->
            demonitor(Monitor, [flush]),
            {joined, Shared};
        {howdy_cache_flight, LeaderRef, retry} ->
            demonitor(Monitor, [flush]),
            flight(Tables, Key, Job);
        {'DOWN', Monitor, process, _, _} ->
            %% Killed while computing: its flight is still in the table,
            %% and would turn every later caller away for good.
            ets:delete_object(Flights, {Key, Leader, LeaderRef}),
            unregister(Waiters, LeaderRef),
            flight(Tables, Key, Job)
    end.

%% Whether this process's registration was still there to remove.
unregister(Waiters, LeaderRef) ->
    Self = self(),
    ets:select_delete(Waiters, [{{LeaderRef, Self}, [], [true]}]) > 0.

%% -- Memory store --------------------------------------------------------------
%%
%% Two tables, owned by a janitor process that monitors the store's creator
%% and deletes them when it exits, like howdy/rate_limit's:
%%   entries: {Key, Value, ExpiresAt, [{Tag, Version}]}
%%   tags:    {Tag, Version}
%% The janitor removes expired entries every SweepMs, and trims back to the
%% limit. A write that finds the table at its limit first removes expired
%% entries and then, if it is still full, the entries closest to expiring
%% until a tenth of the room is free. Concurrent writers can overshoot the
%% limit by one entry each, until the next write or sweep.
-record(store, {entries, tags, max}).

memory_new(MaxEntries, SweepMs) ->
    Owner = self(),
    Ready = make_ref(),
    Janitor = spawn(fun() ->
        Entries = ets:new(howdy_cache_entries,
                          [set, public, {read_concurrency, true},
                           {write_concurrency, true}]),
        Tags = ets:new(howdy_cache_tags,
                       [set, public, {read_concurrency, true},
                        {write_concurrency, true}]),
        Ref = monitor(process, Owner),
        Owner ! {Ready, Entries, Tags},
        janitor(Entries, MaxEntries, Ref, SweepMs)
    end),
    receive
        {Ready, Entries, Tags} -> #store{entries = Entries, tags = Tags, max = MaxEntries}
    after 5000 ->
        exit(Janitor, kill),
        error({howdy_cache, janitor_did_not_start})
    end.

janitor(Entries, Max, Ref, SweepMs) ->
    receive
        {'DOWN', Ref, process, _, _} ->
            ok
    after SweepMs ->
        try
            sweep(Entries, system_ms()),
            trim(Entries, Max)
        catch Class:Reason:Stack ->
            logger:warning(#{msg => "howdy_cache: memory sweep failed",
                             class => Class, reason => Reason,
                             stacktrace => Stack})
        end,
        janitor(Entries, Max, Ref, SweepMs)
    end.

sweep(Entries, Now) ->
    ets:select_delete(Entries, [{{'_', '_', '$1', '_'}, [{'=<', '$1', Now}], [true]}]).

memory_read(#store{entries = Entries, tags = Tags}, Key) ->
    case ets:lookup(Entries, Key) of
        [{_, Value, ExpiresAt, Versions}] ->
            Current = lists:all(fun({Tag, Version}) -> version(Tags, Tag) =:= Version end,
                                Versions),
            {some, {stored, Value, ExpiresAt, Current}};
        [] ->
            none
    end.

version(Tags, Tag) ->
    case ets:lookup(Tags, Tag) of
        [{_, Version}] -> Version;
        [] -> 0
    end.

memory_versions(#store{tags = Tags}, TagList) ->
    [{Tag, version(Tags, Tag)} || Tag <- TagList].

memory_write(#store{entries = Entries, max = Max}, Key, Value, ExpiresAt, Versions) ->
    case ets:member(Entries, Key) orelse ets:info(Entries, size) < Max of
        true -> ok;
        false -> make_room(Entries, Max)
    end,
    replace(Entries, {Key, Value, ExpiresAt, Versions}),
    nil.

%% Replace the entry unless it was written with a newer version of a tag
%% both share: then this value was computed before an invalidation the
%% stored one already reflects. A compare-and-swap, so a concurrent write
%% between the read and the replacement is never lost.
replace(Entries, New = {Key, _, _, Versions}) ->
    case ets:lookup(Entries, Key) of
        [] ->
            case ets:insert_new(Entries, New) of
                true -> ok;
                false -> replace(Entries, New)
            end;
        [Old = {_, _, _, OldVersions}] ->
            case newer(OldVersions, Versions) of
                true ->
                    ok;
                false ->
                    case ets:select_replace(Entries, [{Old, [], [{const, New}]}]) of
                        1 -> ok;
                        0 -> replace(Entries, New)
                    end
            end
    end.

newer(Stored, Writing) ->
    lists:any(fun({Tag, Version}) ->
                  case lists:keyfind(Tag, 1, Writing) of
                      {_, Mine} -> Version > Mine;
                      false -> false
                  end
              end,
              Stored).

make_room(Entries, Max) ->
    sweep(Entries, system_ms()),
    trim(Entries, Max - max(1, Max div 10)).

%% Remove the entries closest to expiring until at most Target are left.
%% How many go is worked out from the size now, not a fixed share, so
%% writers that race to evict the same entries still bring the table back
%% down: each insert can overshoot by one at most, and the next write or
%% sweep removes the excess.
trim(Entries, Target) ->
    case ets:info(Entries, size) - Target of
        Excess when Excess > 0 ->
            Expiries = lists:sort(ets:select(Entries, [{{'$1', '_', '$2', '_'}, [], [{{'$2', '$1'}}]}])),
            lists:foreach(fun({_, Key}) -> ets:delete(Entries, Key) end,
                          lists:sublist(Expiries, Excess));
        _ ->
            ok
    end.

memory_delete(#store{entries = Entries}, Key) ->
    ets:delete(Entries, Key),
    nil.

memory_invalidate(#store{tags = Tags}, TagList) ->
    lists:foreach(fun(Tag) -> ets:update_counter(Tags, Tag, {2, 1}, {Tag, 0}) end,
                  TagList),
    nil.

memory_clear(#store{entries = Entries}) ->
    ets:delete_all_objects(Entries),
    nil.

%% -- Database sweeper ----------------------------------------------------------
%%
%% Runs Sweep every EveryMs until the process that started it exits. Not
%% linked, so a failing sweep never takes that process down; failures are
%% logged and the next tick tries again.
start_sweeper(Sweep, EveryMs) ->
    Owner = self(),
    spawn(fun() ->
        Ref = monitor(process, Owner),
        sweeper(Sweep, EveryMs, Ref)
    end),
    nil.

sweeper(Sweep, EveryMs, Ref) ->
    receive
        {'DOWN', Ref, process, _, _} -> ok
    after EveryMs ->
        try Sweep() of
            {ok, _} -> ok;
            {error, Error} ->
                logger:warning(#{msg => "howdy_cache: database sweep failed",
                                 error => Error})
        catch Class:Reason:Stack ->
            logger:warning(#{msg => "howdy_cache: database sweep crashed",
                             class => Class, reason => Reason,
                             stacktrace => Stack})
        end,
        sweeper(Sweep, EveryMs, Ref)
    end.
