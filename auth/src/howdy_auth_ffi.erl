-module(howdy_auth_ffi).
-export([now/0, normalize_password/1, pbkdf2_sha256/4, canonical_host/1, constant_time_equal/2,
         cache_new/0, cache_run/4, cache_invalidate/0, cache_transaction/1, cache_changing/1,
         sessions_put/5, sessions_get/2, sessions_list/2, sessions_delete/3, sessions_delete_user/3, sessions_prune/2]).

%% Seconds since the epoch. Tests may skew every clock in their own process
%% through `howdy_auth_test_ffi:advance_clock/2` instead of sleeping; nothing
%% else sets the offset.
now() -> erlang:system_time(second) + clock_offset_ms() div 1000.

clock_offset_ms() ->
    case get(howdy_auth_clock_offset_ms) of
        undefined -> 0;
        Offset -> Offset
    end.

normalize_password(Value) -> unicode:characters_to_nfc_binary(Value).

%% OTP runs this on a dirty CPU scheduler, so concurrent hashing is bounded by
%% the number of those schedulers rather than blocking normal ones.
pbkdf2_sha256(Password, Salt, Iterations, Length) ->
    crypto:pbkdf2_hmac(sha256, Password, Salt, Iterations, Length).

%% Equality of two digests in time that depends only on their length.
%% `crypto:hash_equals/2` raises on unequal lengths, and a length is not a
%% secret, so unequal lengths are simply unequal.
constant_time_equal(A, B) when byte_size(A) =:= byte_size(B) -> crypto:hash_equals(A, B);
constant_time_equal(_, _) -> false.


%% The authorization cache is one named public table owned by
%% howdy_auth_tables, partitioned between Authorization instances by the
%% reference each `new` returns. Generation changes bracket grant/suspension
%% mutations, so a slow read cannot install a stale grant after a mutation has
%% committed.
%%
%% Invariant: the transaction and dirty markers live in the process
%% dictionary, so `cache_transaction` (the Howdy transaction hook) and
%% `cache_changing` (around each grant/suspension mutation) must run in the
%% one process that holds the transaction. A mutation performed from a
%% process spawned inside a transaction sees no marker: it invalidates
%% immediately, when its own `cache_changing` ends, rather than after the
%% outer transaction commits, and a concurrent read could re-cache the old
%% grant in between. Such a mutation cannot be told apart from one made with
%% no transaction at all, so it is a documented rule, not a checked one. What
%% can be seen is a mutation inside a Howdy transaction that the cache hook
%% did not bracket (a transaction opened before the cache was created); that
%% is logged once and otherwise behaves the same.
-define(CACHE, howdy_auth_cache).

cache_new() ->
    _ = howdy_auth_tables:ensure(?CACHE),
    make_ref().

cache_generation() -> atomics:get(howdy_auth_tables:versions(), 1).

cache_invalidate() ->
    atomics:add(howdy_auth_tables:versions(), 1, 1),
    nil.

cache_now() -> erlang:monotonic_time(millisecond) + clock_offset_ms().

cache_run(Ref, Key, Seconds, Run) ->
    case get(howdy_auth_cache_dirty) of
        true -> Run();
        _ -> cache_read(Ref, Key, Seconds, Run)
    end.

cache_read(Ref, Key, Seconds, Run) ->
    Generation = cache_generation(),
    Now = cache_now(),
    Cached = try ets:lookup(?CACHE, {Ref, Key}) catch error:badarg -> unavailable end,
    case Cached of
        unavailable ->
            %% The owner is down or restarting: answer from the database and
            %% have the table back for the next request.
            _ = howdy_auth_tables:ensure(?CACHE),
            Run();
        [{_, Generation, Until, Value}] when Until > Now -> {ok, Value};
        _ ->
            Result = Run(),
            case Result of
                {ok, Value} -> cache_store({Ref, Key}, Generation, Now + Seconds * 1000, Value);
                _ -> ok
            end,
            Result
    end.

%% Bound memory independently of the number of distinct sessions/permissions
%% an application asks about. Deliberately unlocked: two writers may both see
%% the table full and both clear it, or an insert may land between another's
%% check and its clear, so the bound is exceeded by at most the number of
%% concurrent writers and a few freshly cached rows may be dropped. Both are
%% harmless for a cache whose every row is recomputable and whose safety
%% comes from generations, not from row counts; a round trip to a lock
%% process on every miss is not.
cache_store(Key, Generation, Until, Value) ->
    try
        case ets:info(?CACHE, size) >= 10000 of
            true -> ets:delete_all_objects(?CACHE);
            false -> ok
        end,
        ets:insert(?CACHE, {Key, Generation, Until, Value})
    catch error:badarg -> ok end.


canonical_host(Host) ->
    Lower = string:lowercase(binary_to_list(Host)),
    case inet:parse_address(Lower) of
        {ok, Address} -> {ok, list_to_binary(inet:ntoa(Address))};
        {error, _} ->
            %% IDNs must be configured using their ASCII (punycode) spelling.
            %% Reject URI forms the browser would escape or interpret as IPv4.
            Allowed = Lower =/= [] andalso lists:all(fun(C) ->
                (C >= $a andalso C =< $z) orelse
                (C >= $0 andalso C =< $9) orelse C =:= $. orelse C =:= $-
            end, Lower),
            Labels = string:split(Lower, ".", all),
            Last = lists:last(Labels),
            NumericEnd = Last =/= [] andalso lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Last),
            case Allowed andalso not NumericEnd of
                true -> {ok, list_to_binary(Lower)};
                false -> {error, nil}
            end
    end.


cache_transaction(Run) ->
    Key = howdy_auth_cache_transaction_depth,
    Depth = case get(Key) of undefined -> 0; N -> N end,
    put(Key, Depth + 1),
    try Run()
    after
        case Depth of
            0 ->
                erase(Key),
                case erase(howdy_auth_cache_dirty) of
                    true -> cache_invalidate();
                    _ -> ok
                end;
            _ -> put(Key, Depth)
        end
    end.

cache_changing(Run) ->
    unbracketed_check(),
    cache_transaction(fun() ->
        put(howdy_auth_cache_dirty, true),
        cache_invalidate(),
        Run()
    end).

%% Inside a Howdy database transaction in this process, yet without the
%% cache's own marker: the transaction hook did not bracket it. Warn once per
%% node; behaviour is unchanged.
unbracketed_check() ->
    case get(howdy_database_transaction_depth) =/= undefined
         andalso get(howdy_auth_cache_transaction_depth) =:= undefined
         andalso not persistent_term:get(howdy_auth_cache_unbracketed_warned, false) of
        true ->
            persistent_term:put(howdy_auth_cache_unbracketed_warned, true),
            logger:warning("howdy/auth: authorization cache mutation inside a transaction "
                           "the cache hook did not bracket; the cache was created after the "
                           "transaction opened, or the mutation runs in another process. "
                           "Invalidation happens now rather than after commit.");
        false -> ok
    end.

%% The in-memory session store: one public ETS table of
%% {Digest, UserId, ExpiresAt, Record}, owned by a howdy_auth_sessions process
%% and found through its reference on every call. Every operation returns
%% {ok, _} or {error, nil}: the table is missing while the owner is down or
%% being restarted, and ets raises badarg once it has been deleted. Either
%% way the store fails closed rather than crashing the request.
sessions_run(Ref, Run) ->
    case howdy_auth_sessions:table(Ref) of
        undefined -> {error, nil};
        Table -> try {ok, Run(Table)} catch error:badarg -> {error, nil} end
    end.

sessions_put(Ref, Digest, UserId, ExpiresAt, Record) ->
    sessions_run(Ref, fun(Table) ->
        ets:insert(Table, {Digest, UserId, ExpiresAt, Record}),
        nil
    end).

sessions_get(Ref, Digest) ->
    sessions_run(Ref, fun(Table) ->
        case ets:lookup(Table, Digest) of
            [{_, _, _, Record}] -> {some, Record};
            [] -> none
        end
    end).

sessions_list(Ref, UserId) ->
    sessions_run(Ref, fun(Table) ->
        [Record || [Record] <- ets:match(Table, {'_', UserId, '_', '$1'})]
    end).

sessions_delete(Ref, Digest, UserId) ->
    sessions_run(Ref, fun(Table) ->
        ets:match_delete(Table, {Digest, UserId, '_', '_'}),
        nil
    end).

sessions_delete_user(Ref, UserId, Keep) ->
    sessions_run(Ref, fun(Table) ->
        ets:select_delete(Table, [{{'$1', UserId, '_', '_'}, [{'=/=', '$1', {const, Keep}}], [true]}]),
        nil
    end).

sessions_prune(Ref, Now) ->
    sessions_run(Ref, fun(Table) ->
        ets:select_delete(Table, [{{'_', '_', '$1', '_'}, [{'=<', '$1', Now}], [true]}]),
        nil
    end).
