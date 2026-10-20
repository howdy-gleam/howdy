-module(howdy_notifications_test_ffi).
-export([getenv/1, clock/0, advance/1, kept/0, keep/1, crashes/1]).

getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        "" -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

%% A clock shared by every process, which only moves when a test says so.
counter() ->
    case persistent_term:get(howdy_notifications_test_clock, undefined) of
        undefined ->
            Counter = atomics:new(1, []),
            atomics:put(Counter, 1, 1000000),
            persistent_term:put(howdy_notifications_test_clock, Counter),
            Counter;
        Counter -> Counter
    end.

clock() ->
    atomics:get(counter(), 1).

advance(Milliseconds) ->
    atomics:add(counter(), 1, Milliseconds),
    nil.

%% The PostgreSQL pool, opened by the first test and shared by the rest.
kept() ->
    case persistent_term:get(howdy_notifications_test_repo, undefined) of
        undefined -> {error, nil};
        Repo -> {ok, Repo}
    end.

keep(Repo) ->
    persistent_term:put(howdy_notifications_test_repo, Repo),
    nil.

%% Whether running F crashes.
crashes(F) ->
    try F() of
        _ -> false
    catch
        _:_ -> true
    end.
