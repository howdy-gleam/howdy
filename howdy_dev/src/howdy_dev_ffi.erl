-module(howdy_dev_ffi).
-export([build/0, reload_modules/0, reload_token/0, token_matches/2, file_hash/1, attempt/1]).

%% CRC32 of the file contents, so edits that keep size and timestamp are
%% still noticed. Errors leave the file out of the snapshot.
file_hash(Path) ->
    case file:read_file(Path) of
        {ok, Bytes} -> {ok, erlang:crc32(Bytes)};
        {error, _} -> {error, nil}
    end.

reload_token() -> binary:encode_hex(crypto:strong_rand_bytes(32)).

token_matches(Expected, Supplied) when byte_size(Expected) =:= byte_size(Supplied) ->
    crypto:hash_equals(Expected, Supplied);
token_matches(_, _) -> false.

%% Run `gleam build` in the current directory. Returns the exit code and
%% everything it printed.
build() ->
    case os:find_executable("gleam") of
        false ->
            {127, <<"gleam is not on the PATH">>};
        Gleam ->
            Port = erlang:open_port({spawn_executable, Gleam},
                                    [{args, ["build"]}, exit_status, binary,
                                     stderr_to_stdout, hide]),
            collect(Port, [])
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect(Port, [Data | Acc]);
        {Port, {exit_status, Code}} -> {Code, iolist_to_binary(lists:reverse(Acc))}
    after 120000 ->
        try erlang:port_close(Port) catch _:_ -> ok end,
        {124, <<"gleam build timed out">>}
    end.

%% Load every module whose compiled file changed since it was last loaded.
%% Old code is purged first, which ends any process still running it.
%% Returns the names of the modules loaded.
reload_modules() ->
    Modules = code:modified_modules(),
    lists:foreach(fun code:purge/1, Modules),
    case code:atomic_load(Modules) of
        ok -> ok;
        {error, _} -> lists:foreach(fun code:load_file/1, Modules)
    end,
    [atom_to_binary(M, utf8) || M <- Modules].

%% Run `Fun`, turning a crash into `{error, Description}`.
attempt(Fun) ->
    try
        {ok, Fun()}
    catch
        Class:Reason -> {error, unicode:characters_to_binary(io_lib:format("~p:~0tP", [Class, Reason, 6]))}
    end.
