-module(howdy_ui_island_ffi).
-export([function_location/1, identity/1, build_javascript/1, run/2,
         development/0, bundle_root/0, fingerprint/1, esbuild/0,
         cached_boot/0, cache_boot/1, log_error/1]).

-define(ESBUILD_VERSION, "0.28.2").

identity(Value) -> Value.

%% The package (OTP application), module and name of a function, so the
%% browser can import the same function from the JavaScript build.
function_location(Fun) when is_function(Fun) ->
    {module, Module} = erlang:fun_info(Fun, module),
    {name, Name} = erlang:fun_info(Fun, name),
    case application:get_application(Module) of
        {ok, App} ->
            {ok, {atom_to_binary(App), atom_to_binary(Module), atom_to_binary(Name)}};
        undefined ->
            {error, <<"island.mount could not tell which package defines ",
                      (atom_to_binary(Module))/binary>>}
    end.

%% Development means running the dev build of a project, with its sources
%% and the compiler to hand: `gleam run`, `gleam dev` or `gleam test`. An
%% exported release loads its code from elsewhere, even when started from
%% the project directory.
development() ->
    Loaded = code:which(?MODULE),
    is_list(Loaded)
        andalso string:find(Loaded, "/build/dev/erlang/") =/= nomatch
        andalso filelib:is_regular("gleam.toml").

%% The directory holding the islands bundle: `priv/howdy_islands` of
%% whichever package on the code path has one. Every package in a release
%% sits next to its `priv`.
bundle_root() ->
    Candidates = [filename:join([filename:dirname(Dir), "priv", "howdy_islands"])
                  || Dir <- code:get_path()],
    case [C || C <- Candidates, filelib:is_regular(filename:join(C, "manifest.json"))] of
        [Root | _] -> {ok, unicode:characters_to_binary(Root)};
        [] -> {error, nil}
    end.

%% The MD5 of a compiled module, as hex. Gleam builds the same beam for
%% `gleam run` and `gleam export`, so the two agree.
fingerprint(Module) ->
    case code:which(binary_to_atom(Module)) of
        Path when is_list(Path) ->
            case beam_lib:md5(Path) of
                {ok, {_, Md5}} -> {ok, binary:encode_hex(Md5)};
                _ -> {error, nil}
            end;
        _ ->
            {error, nil}
    end.

cached_boot() ->
    case persistent_term:get(howdy_ui_islands_boot, undefined) of
        undefined -> {error, nil};
        Script -> {ok, Script}
    end.

cache_boot(Script) ->
    persistent_term:put(howdy_ui_islands_boot, Script),
    nil.

log_error(Message) ->
    logger:error("~ts", [Message]),
    nil.

%% Run `gleam build --target javascript` in Dir, one build at a time per
%% node. Returns the exit code and everything it printed.
build_javascript(Dir) ->
    global:trans({howdy_ui_islands_build, self()},
                 fun() ->
                     case os:find_executable("gleam") of
                         false -> {127, <<"gleam is not on the PATH">>};
                         Gleam -> run(Gleam, [<<"build">>, <<"--target">>, <<"javascript">>], Dir)
                     end
                 end,
                 [node()]).

run(Executable, Args) ->
    {ok, Dir} = file:get_cwd(),
    run(Executable, Args, Dir).

run(Executable, Args, Dir) ->
    Port = erlang:open_port({spawn_executable, unicode:characters_to_list(Executable)},
                            [{args, [unicode:characters_to_list(A) || A <- Args]},
                             {cd, Dir}, exit_status, binary, stderr_to_stdout, hide]),
    collect(Port, []).

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect(Port, [Data | Acc]);
        {Port, {exit_status, Code}} -> {Code, iolist_to_binary(lists:reverse(Acc))}
    after 120000 ->
        try erlang:port_close(Port) catch _:_ -> ok end,
        {124, <<"timed out">>}
    end.

%% The esbuild executable: HOWDY_ESBUILD if set, otherwise a pinned
%% release downloaded once into the user cache and checked against the
%% npm registry's published SHA-512.
esbuild() ->
    case os:getenv("HOWDY_ESBUILD") of
        Path when is_list(Path), Path =/= "" -> {ok, unicode:characters_to_binary(Path)};
        _ -> cached_esbuild()
    end.

cached_esbuild() ->
    case esbuild_package() of
        {error, _} = Error ->
            Error;
        {ok, {Platform, Integrity, Member}} ->
            Dir = filename:basedir(user_cache, "howdy"),
            Exe = filename:join([Dir, "esbuild-" ?ESBUILD_VERSION, filename:basename(Member)]),
            case filelib:is_regular(Exe) of
                true -> {ok, unicode:characters_to_binary(Exe)};
                false -> download_esbuild(Platform, Integrity, Member, Exe)
            end
    end.

download_esbuild(Platform, Integrity, Member, Exe) ->
    Url = iolist_to_binary(["https://registry.npmjs.org/@esbuild/", Platform,
                            "/-/", Platform, "-", ?ESBUILD_VERSION, ".tgz"]),
    io:format("Downloading esbuild ~s for ~s...~n", [?ESBUILD_VERSION, Platform]),
    case howdy_ui_cli_ffi:fetch(Url) of
        {error, Reason} ->
            {error, <<"could not download esbuild from ", Url/binary, ": ", Reason/binary>>};
        {ok, Tarball} ->
            Actual = <<"sha512-", (base64:encode(crypto:hash(sha512, Tarball)))/binary>>,
            case Actual =:= Integrity of
                false ->
                    {error, <<"the esbuild download from ", Url/binary,
                              " did not match its expected checksum">>};
                true ->
                    case erl_tar:extract({binary, Tarball}, [compressed, memory, {files, [Member]}]) of
                        {ok, [{_, Binary}]} ->
                            ok = filelib:ensure_dir(Exe),
                            ok = file:write_file(Exe, Binary),
                            ok = file:change_mode(Exe, 8#755),
                            {ok, unicode:characters_to_binary(Exe)};
                        _ ->
                            {error, <<"could not unpack esbuild from ", Url/binary>>}
                    end
            end
    end.

%% npm package, SHA-512 integrity and executable path inside the tarball
%% for this machine.
esbuild_package() ->
    Arch = case erlang:system_info(system_architecture) of
               "x86_64" ++ _ -> x64;
               "amd64" ++ _ -> x64;
               "aarch64" ++ _ -> arm64;
               "arm64" ++ _ -> arm64;
               _ -> other
           end,
    case {os:type(), Arch} of
        {{unix, linux}, x64} ->
            {ok, {<<"linux-x64">>, <<"sha512-4xTZr1FUmSoQW4XIWmit3tzQrUTZM+N3P0XV8xROKYF50XfI7xeO90+1bZvNwxIufQ9hDQVRJH5YhgPVF8A/HQ==">>, "package/bin/esbuild"}};
        {{unix, linux}, arm64} ->
            {ok, {<<"linux-arm64">>, <<"sha512-pW4AC0P3it8c7do9MVM4p51FzHzdM/TZrerurgRcHJ2WTa1VQ1CIq18xncfpBJw4ojkiZZrKW2yIBWBP92j6Ug==">>, "package/bin/esbuild"}};
        {{unix, darwin}, x64} ->
            {ok, {<<"darwin-x64">>, <<"sha512-uq6suIWYP37qzGddBKPw5QEQPi6HiLGsO7UmkpfyaYNQ3D+rN6w6WfwH+nuqcGXWvawGwxOEroO4YGnFh95azw==">>, "package/bin/esbuild"}};
        {{unix, darwin}, arm64} ->
            {ok, {<<"darwin-arm64">>, <<"sha512-n4KqkOQrraxHJcgjM1RvwbigfQKIKJVpM7xp+KsxiyUSrRdIXnt73VhrPAx0fV44hgfmIVKjxMN9J1t5jySVkw==">>, "package/bin/esbuild"}};
        {{win32, _}, x64} ->
            {ok, {<<"win32-x64">>, <<"sha512-5ebpxr3nWMzrL/rnUI755Jkuee0bHL/Gq0WTF9lvcpv73wAp5eu8MfBUgWK9bhWvZjj7yX8etf/8tI8Ney695g==">>, "package/esbuild.exe"}};
        {{win32, _}, arm64} ->
            {ok, {<<"win32-arm64">>, <<"sha512-PIhhEkE9uPBleRBrQEJpUn7MBnibZzbGzYWPmY3x+YoVg/95zbjB4CxPPOQ8l5tYYM4mMaCthF8/1DIfBQQyWQ==">>, "package/esbuild.exe"}};
        _ ->
            {error, <<"no esbuild download for this machine (",
                      (unicode:characters_to_binary(erlang:system_info(system_architecture)))/binary,
                      "). Install esbuild and set HOWDY_ESBUILD to its path.">>}
    end.
