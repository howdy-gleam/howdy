%% Support for reading multipart forms in howdy/form: finding a part's
%% delimiter, writing uploaded files to temporary files, and deleting those
%% files once the request is done with them, however it ends.
-module(howdy_form_ffi).
-export([find/3, default_temporary_directory/0, random_name/0]).
-export([append/2]).
-export([watch/0, track/2, finish/1]).

%% The position of Pattern in Data, looking no earlier than From.
find(Data, Pattern, From) ->
    case binary:match(Data, Pattern, [{scope, {From, byte_size(Data) - From}}]) of
        {Position, _} -> {ok, Position};
        nomatch -> {error, nil}
    end.

default_temporary_directory() ->
    Found = [D || Name <- ["TMPDIR", "TMP", "TEMP"],
                  D <- [os:getenv(Name)], D =/= false, D =/= ""],
    case Found of
        [Directory | _] -> unicode:characters_to_binary(Directory);
        [] -> <<"/tmp">>
    end.

random_name() ->
    binary:encode_hex(crypto:strong_rand_bytes(16), lowercase).

%% -- Temporary files ---------------------------------------------------------

%% Each piece is appended by opening and closing the file, so that no handle
%% is left open when reading the rest of the body fails.
append(Path, Data) ->
    case file:write_file(Path, Data, [append, raw, binary]) of
        ok -> {ok, nil};
        {error, Reason} -> {error, describe(Reason)}
    end.

describe(Reason) ->
    unicode:characters_to_binary(file:format_error(Reason)).

%% -- Deleting the files ------------------------------------------------------
%%
%% Each request that receives files gets a watcher process. A path is
%% tracked before its file is created, and the watcher deletes every tracked
%% file when the request calls `finish`, or when the request's process ends
%% without doing so, such as when it is killed because its client went away.

watch() ->
    Request = self(),
    spawn(fun() ->
        Monitor = monitor(process, Request),
        watching(Monitor, [])
    end).

watching(Monitor, Paths) ->
    receive
        {track, Path} ->
            watching(Monitor, [Path | Paths]);
        {finish, From, Tag} ->
            delete(Paths),
            From ! {Tag, done};
        {'DOWN', Monitor, process, _, _} ->
            delete(Paths)
    end.

delete(Paths) ->
    lists:foreach(fun(Path) -> _ = file:delete(Path) end, Paths).

track(Watcher, Path) ->
    Watcher ! {track, Path},
    nil.

finish(Watcher) ->
    Monitor = monitor(process, Watcher),
    Watcher ! {finish, self(), Monitor},
    receive
        {Monitor, done} ->
            demonitor(Monitor, [flush]);
        {'DOWN', Monitor, process, _, _} ->
            ok
    end,
    nil.
