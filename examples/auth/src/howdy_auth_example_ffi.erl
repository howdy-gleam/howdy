-module(howdy_auth_example_ffi).
-export([getenv/1]).

getenv(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        "" -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.
