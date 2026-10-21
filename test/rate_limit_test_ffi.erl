-module(rate_limit_test_ffi).
-export([cleanup_boundaries/0, cleanup_races/0, scheduled_cleanup/0,
         owner_lifecycle/0, identity_cap/0, cardinality_benchmark/0]).

with_table(Run) ->
    T = ets:new(rate_limit_test, [set, public, {write_concurrency, true}]),
    try Run(T) after ets:delete(T) end.

%% Identity rows, excluding the admission counter a capped table keeps.
rows(T) ->
    ets:info(T, size) - case ets:member(T, '$howdy_identities') of true -> 1; false -> 0 end.

counter(T) ->
    case ets:lookup(T, '$howdy_identities') of [{_, N}] -> N; [] -> 0 end.

cleanup_boundaries() ->
    with_table(fun(T) ->
        %% Expired negative windows disappear; current/future counters survive.
        {admitted, 1} = fixed_hit(T, <<"old">>, -2),
        {admitted, 1} = fixed_hit(T, <<"current">>, -1),
        {admitted, 1} = fixed_hit(T, <<"future">>, 0),
        1 = howdy_rate_limit_ffi:fixed_window_cleanup(T, -1),
        2 = rows(T),
        {admitted, 2} = fixed_hit(T, <<"current">>, -1),
        1 = howdy_rate_limit_ffi:fixed_window_cleanup(T, 0),
        {admitted, 2} = fixed_hit(T, <<"future">>, 0)
    end),
    with_table(fun(T) ->
        %% 2,000 one-off identities, plus an active, depleted bucket.
        %% Capacity 2 tokens, 3 tokens/s: a one-hit bucket from -1000 is
        %% back at capacity once (Now + 1000) * 3 >= 1000, i.e. at -666.
        [{admitted, 2000} = bucket_hit(T, integer_to_binary(I), 2000, 3, -1000)
         || I <- lists:seq(1, 2000)],
        {admitted, 2000} = bucket_hit(T, <<"active">>, 2000, 3, -500),
        {admitted, 1000} = bucket_hit(T, <<"active">>, 2000, 3, -500),
        0 = howdy_rate_limit_ffi:token_bucket_cleanup(T, 2000, 3, -667),
        %% Well inside the old idle horizon, yet lossless to evict.
        2000 = howdy_rate_limit_ffi:token_bucket_cleanup(T, 2000, 3, -666),
        1 = rows(T),
        %% The depleted bucket survives every later sweep until it refills.
        0 = howdy_rate_limit_ffi:token_bucket_cleanup(T, 2000, 3, 100),
        {admitted, 300} = bucket_hit(T, <<"active">>, 2000, 3, -400),
        {admitted, 2000} = bucket_hit(T, <<"1">>, 2000, 3, 0),
        {admitted, 1000} = bucket_hit(T, <<"1">>, 2000, 3, 0),
        {admitted, 0} = bucket_hit(T, <<"1">>, 2000, 3, 0),
        %% "active" (300 tokens at -400) is full from 167; "1" (empty at 0)
        %% needs 1000/3 ms, so it is full at 667 and not before.
        1 = howdy_rate_limit_ffi:token_bucket_cleanup(T, 2000, 3, 666),
        1 = howdy_rate_limit_ffi:token_bucket_cleanup(T, 2000, 3, 667),
        0 = rows(T)
    end),
    nil.

fixed_hit(T, Key, Window) ->
    howdy_rate_limit_ffi:fixed_window_hit(T, Key, Window, infinity).

bucket_hit(T, Key, Capacity, Rate, Now) ->
    howdy_rate_limit_ffi:token_bucket_hit(T, Key, Capacity, Rate, infinity, Now).

cleanup_races() ->
    with_table(fun(T) ->
        [begin
            ets:delete_all_objects(T),
            {admitted, 2000} = bucket_hit(T, <<"k">>, 2000, 1, -2000),
            %% The old bucket is now fully refilled. Racing deletion with
            %% refill/consume must allow exactly one capacity, never two.
            Hits = lists:duplicate(40, fun() ->
                bucket_hit(T, <<"k">>, 2000, 1, 0)
            end),
            Results = howdy_test_ffi:parallel_at_once(
                [fun() -> howdy_rate_limit_ffi:token_bucket_cleanup(T, 2000, 1, 0), skipped end | Hits]),
            2 = length([N || {admitted, N} <- Results, N >= 1000]),
            [{_, 0, 0}] = [R || {_, _, _} = R <- ets:tab2list(T)]
        end || _ <- lists:seq(1, 100)]
    end),
    nil.

scheduled_cleanup() ->
    Fixed = 'howdy@rate_limit':fixed_window(1, 1),
    Bucket = 'howdy@rate_limit':token_bucket(1, 1),
    Slow = 'howdy@rate_limit':token_bucket(10, 1),
    FT = element(2, Fixed), BT = element(2, Bucket), ST = element(2, Slow),
    ['howdy@rate_limit':check(Fixed, integer_to_binary(I)) || I <- lists:seq(1, 2000)],
    ['howdy@rate_limit':check(Bucket, integer_to_binary(I)) || I <- lists:seq(1, 2000)],
    ['howdy@rate_limit':check(Slow, <<"active">>) || _ <- lists:seq(1, 10)],
    wait_until(fun() -> rows(FT) == 0 andalso rows(BT) == 0 end, 3500),
    1 = rows(ST),
    {allowed, 1, 0, 1} = 'howdy@rate_limit':check(Bucket, <<"1">>),
    {denied, 1, 1} = 'howdy@rate_limit':check(Bucket, <<"1">>),
    nil.

identity_cap() ->
    %% Fixed window: the cap counts rows, never touches existing rows.
    with_table(fun(T) ->
        [{admitted, 1} = howdy_rate_limit_ffi:fixed_window_hit(T, integer_to_binary(I), 0, 3)
         || I <- lists:seq(1, 3)],
        refused = howdy_rate_limit_ffi:fixed_window_hit(T, <<"4">>, 0, 3),
        {admitted, 2} = howdy_rate_limit_ffi:fixed_window_hit(T, <<"1">>, 0, 3),
        %% The same key in a new window is a new row.
        refused = howdy_rate_limit_ffi:fixed_window_hit(T, <<"1">>, 1, 3),
        3 = rows(T),
        3 = counter(T),
        3 = howdy_rate_limit_ffi:fixed_window_cleanup(T, 1),
        0 = counter(T),
        {admitted, 1} = howdy_rate_limit_ffi:fixed_window_hit(T, <<"4">>, 1, 3)
    end),
    %% Token bucket: depleted buckets keep denying while the table is full,
    %% and a refused hit leaves no trace.
    with_table(fun(T) ->
        {admitted, 1000} = howdy_rate_limit_ffi:token_bucket_hit(T, <<"b">>, 1000, 1, 2, 0),
        {admitted, 1000} = howdy_rate_limit_ffi:token_bucket_hit(T, <<"a">>, 1000, 1, 2, 500),
        refused = howdy_rate_limit_ffi:token_bucket_hit(T, <<"c">>, 1000, 1, 2, 500),
        2 = rows(T),
        2 = counter(T),
        {admitted, 0} = howdy_rate_limit_ffi:token_bucket_hit(T, <<"a">>, 1000, 1, 2, 500),
        %% Nothing has refilled, so the sweep frees nothing.
        0 = howdy_rate_limit_ffi:token_bucket_cleanup(T, 1000, 1, 999),
        refused = howdy_rate_limit_ffi:token_bucket_hit(T, <<"c">>, 1000, 1, 2, 999),
        %% "b" is back at capacity at 1000ms and gets evicted; "a" is not.
        1 = howdy_rate_limit_ffi:token_bucket_cleanup(T, 1000, 1, 1000),
        1 = counter(T),
        {admitted, 1000} = howdy_rate_limit_ffi:token_bucket_hit(T, <<"c">>, 1000, 1, 2, 1000),
        {admitted, 1000} = howdy_rate_limit_ffi:token_bucket_hit(T, <<"a">>, 1000, 1, 2, 1500)
    end),
    %% Unbounded tables never grow a counter row.
    with_table(fun(T) ->
        {admitted, 1000} = howdy_rate_limit_ffi:token_bucket_hit(T, <<"a">>, 1000, 1, infinity, 0),
        1 = howdy_rate_limit_ffi:token_bucket_cleanup(T, 1000, 1, 1000),
        false = ets:member(T, '$howdy_identities')
    end),
    %% Concurrent first hits never exceed the cap, for either store.
    with_table(fun(T) ->
        Hits = [fun() -> howdy_rate_limit_ffi:token_bucket_hit(T, integer_to_binary(I), 1000, 1, 10, 0) end
                || I <- lists:seq(1, 100)],
        Results = howdy_test_ffi:parallel_at_once(Hits),
        Admitted = length([ok || {admitted, _} <- Results]),
        true = Admitted =< 10,
        Admitted = rows(T),
        Admitted = counter(T)
    end),
    %% The reviewer's probe: cap 1, 100 keys at once, 100 trials, never 2 rows.
    with_table(fun(T) ->
        [begin
            ets:delete_all_objects(T),
            Hits = [fun() -> howdy_rate_limit_ffi:fixed_window_hit(T, integer_to_binary(I), 0, 1) end
                    || I <- lists:seq(1, 100)],
            Results = howdy_test_ffi:parallel_at_once(Hits),
            Admitted = length([ok || {admitted, _} <- Results]),
            true = Admitted =< 1,
            Admitted = rows(T)
        end || _ <- lists:seq(1, 100)]
    end),
    %% Losing an insert race gives the slot back, and a hit that saw the
    %% reservation fail while the same key was being inserted still counts.
    with_table(fun(T) ->
        Hits = [fun() -> howdy_rate_limit_ffi:token_bucket_hit(T, <<"same">>, 5000, 1, 1, 0) end
                || _ <- lists:seq(1, 50)],
        Results = howdy_test_ffi:parallel_at_once(Hits),
        Admitted = length([ok || {admitted, _} <- Results]),
        true = Admitted >= 1,
        1 = rows(T),
        1 = counter(T),
        %% Every admitted hit took a token from the one bucket.
        [{_, Tokens, _}] = [R || {_, _, _} = R <- ets:tab2list(T)],
        Tokens = max(0, 5000 - 1000 * Admitted)
    end),
    %% Long keys are stored hashed, so row bytes are bounded.
    with_table(fun(T) ->
        Long = binary:copy(<<"x">>, 10000),
        {admitted, 1000} = howdy_rate_limit_ffi:token_bucket_hit(T, Long, 1000, 1, infinity, 0),
        {admitted, 0} = howdy_rate_limit_ffi:token_bucket_hit(T, Long, 1000, 1, infinity, 0),
        [{Stored, 0, 0}] = ets:tab2list(T),
        32 = byte_size(Stored),
        {admitted, 1000} = howdy_rate_limit_ffi:token_bucket_hit(T, <<Long/binary, "y">>, 1000, 1, infinity, 0),
        Short = binary:copy(<<"x">>, 64),
        {admitted, 1000} = howdy_rate_limit_ffi:token_bucket_hit(T, Short, 1000, 1, infinity, 0),
        true = ets:member(T, Short)
    end),
    nil.

owner_lifecycle() ->
    Parent = self(),
    [begin
        {Owner, Ref} = spawn_monitor(fun() ->
            {T, _} = howdy_rate_limit_ffi:fixed_window_new(1000),
            %% The janitor owns the table and is not linked to us.
            Janitor = ets:info(T, owner),
            true = Janitor =/= self(),
            {links, []} = process_info(self(), links),
            Parent ! {self(), T, Janitor},
            receive stop -> ok end
        end),
        {T, Janitor} = receive {Owner, Table, Worker} -> {Table, Worker} end,
        WorkerRef = monitor(process, Janitor),
        case Mode of normal -> Owner ! stop; crash -> exit(Owner, kill) end,
        receive {'DOWN', Ref, process, Owner, _} -> ok after 1000 -> error(owner_leaked) end,
        receive {'DOWN', WorkerRef, process, Janitor, _} -> ok after 1000 -> error(janitor_leaked) end,
        undefined = ets:info(T)
    end || Mode <- [normal, crash]],
    nil.

wait_until(Check, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_loop(Check, Deadline).
wait_loop(Check, Deadline) ->
    case Check() of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> timer:sleep(10), wait_loop(Check, Deadline);
                false -> error(cleanup_timeout)
            end
    end.

cardinality_benchmark() ->
    %% Warm up code loading; compare reductions rather than noisy wall time.
    sample(1000),
    Results = [begin
        Samples = [sample(N) || _ <- lists:seq(1, 5)],
        {Us, Reductions} = lists:nth(3, lists:sort(Samples)),
        io:format("~B keys: ~B us, ~B reductions~n", [N, Us, Reductions]),
        {N, Reductions}
    end || N <- [1000, 2000, 4000, 8000]],
    [{1000, Small} | _] = Results,
    {8000, Large} = lists:last(Results),
    %% Linear work should grow about 8x; the former full scan per key grows
    %% about 64x. Leave room for VM/allocator variation without masking it.
    case Large < Small * 24 of
        true -> nil;
        false -> error({superlinear_cardinality_cost, Small, Large})
    end.

sample(N) ->
    with_table(fun(T) ->
        Keys = [integer_to_binary(I) || I <- lists:seq(1, N)],
        {reductions, Before} = process_info(self(), reductions),
        {Us, _} = timer:tc(fun() ->
            [{admitted, 1} = howdy_rate_limit_ffi:fixed_window_hit(T, K, 0, 100000) || K <- Keys]
        end),
        {reductions, After} = process_info(self(), reductions),
        N = rows(T),
        {Us, After - Before}
    end).
