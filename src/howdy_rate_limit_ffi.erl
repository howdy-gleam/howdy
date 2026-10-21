%% ETS-backed admission for howdy/rate_limit: fixed windows and token buckets.
-module(howdy_rate_limit_ffi).
-export([fixed_window_new/1, token_bucket_new/2, fixed_window_hit/4,
         token_bucket_hit/6, token_bucket_check/5, now_ms/0, system_ms/0]).
-export([fixed_window_cleanup/2, token_bucket_cleanup/4]).

%% -- Admission -----------------------------------------------------------------
%%
%% A limiter holds at most MaxIdentities rows (unbounded when it is the atom
%% `infinity`). The count lives in the table under ?COUNT, a key no cleanup
%% pattern matches. A new row first reserves a slot with one atomic counter
%% update and only then inserts; the slot is given back if the insert loses
%% to a concurrent one, and sweeps give back what they delete. Rows therefore
%% never exceed the cap, even under concurrent first hits. The only effect of
%% contention is that a hit for a new key may be refused while another new
%% key's insert is in flight at the cap.
%% Hits on an existing row never consult the counter, so depleted buckets and
%% open windows keep limiting while the table is full.
%%
%% Keys longer than 64 bytes are replaced by their SHA-256 so row size is
%% bounded regardless of what a client puts in an identifying header.
%% Functions return {admitted, Value} or refused.
-define(COUNT, '$howdy_identities').
-define(MAX_KEY_BYTES, 64).

key(Key) when byte_size(Key) > ?MAX_KEY_BYTES -> crypto:hash(sha256, Key);
key(Key) -> Key.

reserve(_Table, infinity) ->
    true;
reserve(Table, Max) ->
    case ets:update_counter(Table, ?COUNT, {2, 1}, {?COUNT, 0}) > Max of
        true -> release(Table, 1), false;
        false -> true
    end.

%% Never below zero, and never creates the counter: an unbounded table has none.
release(_Table, 0) ->
    ok;
release(Table, N) ->
    try ets:update_counter(Table, ?COUNT, {2, -N, 0, 0}) of
        _ -> ok
    catch error:badarg ->
        case ets:member(Table, ?COUNT) of
            false -> ok;
            true -> error(badarg)
        end
    end.

%% Atomically count a hit. Expired windows are reclaimed by the janitor even
%% if no further requests arrive. Membership is checked first: raising and
%% catching badarg from update_counter costs time that grows with table size,
%% so the exception is left for the rare case of a sweep removing the row
%% between the check and the update.
fixed_window_hit(Table, Key, Window, MaxIdentities) ->
    Row = {key(Key), Window},
    case ets:member(Table, Row) of
        true ->
            try ets:update_counter(Table, Row, {2, 1}) of
                Count -> {admitted, Count}
            catch error:badarg ->
                case ets:info(Table) of
                    undefined -> error(badarg);
                    _ -> fixed_window_hit(Table, Key, Window, MaxIdentities)
                end
            end;
        false ->
            fixed_window_insert(Table, Key, Window, Row, MaxIdentities)
    end.

fixed_window_insert(Table, Key, Window, Row, MaxIdentities) ->
    case reserve(Table, MaxIdentities) of
        false ->
            %% A concurrent hit on the same key may have just inserted it.
            case ets:member(Table, Row) of
                true -> fixed_window_hit(Table, Key, Window, MaxIdentities);
                false -> refused
            end;
        true ->
            case ets:insert_new(Table, {Row, 1}) of
                true -> {admitted, 1};
                false ->
                    release(Table, 1),
                    fixed_window_hit(Table, Key, Window, MaxIdentities)
            end
    end.

%% Token bucket in milli-tokens so refill never loses a remainder.
%% Row: {Key, MilliTokens, LastRefillMs}.
%%
%% Refill, admission and consumption are one compare-and-swap of the row.
%% A competing writer invalidates our snapshot, so retry from its new state.
%% Returns the balance after refill and before taking a token.
token_bucket_hit(Table, Key, CapacityMilli, RatePerSecond, MaxIdentities, NowMs) ->
    token_bucket_update(Table, key(Key), CapacityMilli, RatePerSecond, MaxIdentities, fun() -> NowMs end).

%% Sample after lookup, and again on a failed CAS: a request paused across
%% eviction must not recreate a full bucket with its pre-eviction timestamp.
token_bucket_check(Table, Key, CapacityMilli, RatePerSecond, MaxIdentities) ->
    token_bucket_update(Table, key(Key), CapacityMilli, RatePerSecond, MaxIdentities, fun now_ms/0).

token_bucket_update(Table, Key, CapacityMilli, RatePerSecond, Max, Clock) ->
    case ets:lookup(Table, Key) of
        [] ->
            case reserve(Table, Max) of
                false ->
                    %% A concurrent hit on the same key may have just inserted it.
                    case ets:member(Table, Key) of
                        true -> token_bucket_update(Table, Key, CapacityMilli, RatePerSecond, Max, Clock);
                        false -> refused
                    end;
                true ->
                    %% The first hit consumes a token as part of inserting the bucket.
                    case ets:insert_new(Table, {Key, CapacityMilli - 1000, Clock()}) of
                        true ->
                            {admitted, CapacityMilli};
                        false ->
                            release(Table, 1),
                            token_bucket_update(Table, Key, CapacityMilli, RatePerSecond, Max, Clock)
                    end
            end;
        [{Key, Tokens, Last} = Old] ->
            %% A request may have sampled time before a competing request but
            %% reached ETS later. Never move the refill clock backwards.
            Time = max(Clock(), Last),
            Available = min(CapacityMilli, Tokens + (Time - Last) * RatePerSecond),
            Remaining = case Available >= 1000 of
                true -> Available - 1000;
                false -> Available
            end,
            New = {Key, Remaining, Time},
            %% Key is a Gleam String (binary), not match-spec syntax.
            case ets:select_replace(Table, [{Old, [], [{const, New}]}]) of
                1 -> {admitted, Available};
                0 -> token_bucket_update(Table, Key, CapacityMilli, RatePerSecond, Max, Clock)
            end
    end.

%% Only the janitor scans; requests never send cleanup messages or scan ETS.
%% Constructors return {Table, SweepIntervalMs}.
fixed_window_new(WindowMs) ->
    new_limiter(min(60000, WindowMs), {fixed_window, WindowMs}).

token_bucket_new(CapacityMilli, RatePerSecond) ->
    IdleMs = max(1000, (CapacityMilli + RatePerSecond - 1) div RatePerSecond),
    new_limiter(min(60000, IdleMs), {token_bucket, CapacityMilli, RatePerSecond}).

new_limiter(Interval, Policy) ->
    %% The janitor owns the table and is not linked to the caller, so a fault
    %% while sweeping can never take the process that built the limiter down.
    %% It monitors that process and deletes the table when it exits, so the
    %% limiter still lives exactly as long as its creator, as documented.
    Owner = self(),
    Ready = make_ref(),
    Janitor = spawn(fun() ->
        Table = ets:new(howdy_rate_limit, [set, public, {write_concurrency, true}]),
        Ref = monitor(process, Owner),
        Owner ! {Ready, Table},
        cleanup_loop(Table, Ref, Interval, Policy)
    end),
    receive
        {Ready, Table} -> {Table, Interval}
    after 5000 ->
        exit(Janitor, kill),
        error({howdy_rate_limit, janitor_did_not_start})
    end.

cleanup_loop(Table, Ref, Interval, Policy) ->
    receive
        {'DOWN', Ref, process, _, _} ->
            ets:delete(Table),
            ok
    after Interval ->
        try
            Now = now_ms(),
            case Policy of
                {fixed_window, WindowMs} ->
                    fixed_window_cleanup(Table, floor_div(Now, WindowMs));
                {token_bucket, CapacityMilli, RatePerSecond} ->
                    token_bucket_cleanup(Table, CapacityMilli, RatePerSecond, Now)
            end
        catch Class:Reason:Stack ->
            logger:warning(#{msg => "howdy rate limiter sweep failed; keeping the limiter",
                             class => Class, reason => Reason, stacktrace => Stack})
        end,
        cleanup_loop(Table, Ref, Interval, Policy)
    end.

floor_div(A, B) ->
    case A rem B < 0 of true -> A div B - 1; false -> A div B end.

now_ms() ->
    erlang:monotonic_time(millisecond).

%% Shared limiters need a clock every node agrees on, not the VM's own.
system_ms() ->
    erlang:system_time(millisecond).

%% Atomic per-row deletion cannot discard a concurrently refreshed bucket.
%% Sweeps return how many rows they removed and give those slots back.
fixed_window_cleanup(Table, Window) ->
    Deleted = ets:select_delete(Table, [{{{'_', '$1'}, '_'}, [{'<', '$1', Window}], [true]}]),
    release(Table, Deleted),
    Deleted.

%% A bucket whose refill has reached capacity is indistinguishable from an
%% absent row, so evicting it loses nothing. This subsumes idle eviction: a
%% bucket untouched for a full refill interval is always at capacity. Depleted
%% or partially refilled buckets are never evicted.
token_bucket_cleanup(Table, CapacityMilli, RatePerSecond, NowMs) ->
    Refilled = {'+', '$1', {'*', {'-', NowMs, '$2'}, RatePerSecond}},
    Deleted = ets:select_delete(Table, [{{'_', '$1', '$2'}, [{'>=', Refilled, CapacityMilli}], [true]}]),
    release(Table, Deleted),
    Deleted.

