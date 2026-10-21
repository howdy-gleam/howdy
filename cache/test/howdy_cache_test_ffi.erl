-module(howdy_cache_test_ffi).
-export([counter/0, bump/1, count/1, add/2, getenv/1]).

counter() -> counters:new(1, [atomics]).

bump(Counter) -> counters:add(Counter, 1, 1), nil.

count(Counter) -> counters:get(Counter, 1).

add(Counter, N) -> counters:add(Counter, 1, N), nil.

getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.
