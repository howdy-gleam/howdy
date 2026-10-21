-module(howdy_openapi_test_ffi).
-export([rescue/1]).

%% Run a function, returning the message of a Gleam panic it raises.
rescue(Fun) ->
    try
        {ok, Fun()}
    catch
        error:#{gleam_error := panic, message := Message} -> {error, Message}
    end.
