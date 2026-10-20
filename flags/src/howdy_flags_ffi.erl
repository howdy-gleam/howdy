-module(howdy_flags_ffi).
-export([publish/2, current/1, withdraw/1, attempt/1, arguments/0, halt/1, getenv/1, send_to/3]).

%% Each running Flags keeps its settings in persistent_term: every check reads
%% them without copying, and they change only when someone changes a flag, so
%% the global scan a replacement costs is rare. The key holds a reference, so
%% separate instances, such as in tests, never share settings.
publish(Key, Snapshot) ->
    persistent_term:put(Key, Snapshot),
    nil.

%% Nothing is published before the keeper starts and after it stops, and
%% checks must not fail then: they fall back to the flags' defaults.
current(Key) ->
    case persistent_term:get(Key, undefined) of
        undefined -> {error, nil};
        Index -> {ok, Index}
    end.

withdraw(Key) ->
    persistent_term:erase(Key),
    nil.

%% Run a store call that may raise rather than return an error, so the
%% keeper survives it and keeps serving the settings it has.
attempt(Run) ->
    try
        {ok, Run()}
    catch
        Class:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [{Class, Reason}]))}
    end.

%% The command's arguments: what `gleam run -m tasks/flags ...` passes, or
%% what follows `-extra` on an `erl` command line.
arguments() ->
    [unicode:characters_to_binary(A) || A <- init:get_plain_arguments()].

halt(Code) -> erlang:halt(Code).

getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

%% Send to the process a name was looked up as, the way a send to that name
%% does. Unlike sending to the name again, it does nothing if the process
%% has exited since, rather than crashing the sender.
send_to(Pid, Name, Message) ->
    erlang:send(Pid, {Name, Message}),
    nil.
