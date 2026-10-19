-module(howdy_jobs_test_ffi).
-export([getenv/1, new_clock/0, read_clock/1, advance/2, kept/0, keep/1, now_ms/0]).

getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        "" -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

now_ms() ->
    erlang:system_time(millisecond).

%% A test's clock: the real time plus however far the test has moved it on,
%% shared by every process the test starts.
new_clock() ->
    atomics:new(1, [{signed, true}]).

read_clock(Clock) ->
    erlang:system_time(millisecond) + atomics:get(Clock, 1).

advance(Clock, Milliseconds) ->
    atomics:add(Clock, 1, Milliseconds),
    nil.

%% The PostgreSQL pool, opened by the first test and shared by the rest.
kept() ->
    case persistent_term:get(howdy_jobs_test_repo, undefined) of
        undefined -> {error, nil};
        Repo -> {ok, Repo}
    end.

keep(Repo) ->
    persistent_term:put(howdy_jobs_test_repo, Repo),
    nil.
