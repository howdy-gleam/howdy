-module(howdy_templates_ffi).
-export([read_stdin/0, temporary_directory/0, unique/0, format/1, hash/1,
         gleam_version/0]).

%% All of stdin, for `rewrite`.
read_stdin() ->
    ok = io:setopts(standard_io, [binary, {encoding, unicode}]),
    read_stdin([]).

read_stdin(Acc) ->
    case io:get_chars(standard_io, "", 65536) of
        eof -> unicode:characters_to_binary(lists:reverse(Acc));
        {error, _} -> unicode:characters_to_binary(lists:reverse(Acc));
        Data -> read_stdin([Data | Acc])
    end.

temporary_directory() ->
    Candidates = [os:getenv(V) || V <- ["TMPDIR", "TEMP", "TMP"]],
    case [D || D <- Candidates, D =/= false, D =/= ""] of
        [Dir | _] -> unicode:characters_to_binary(string:trim(Dir, trailing, "/\\"));
        [] -> <<"/tmp">>
    end.

unique() ->
    erlang:unique_integer([positive]).

%% `gleam format Paths...`; true if it exited cleanly.
format(Paths) ->
    case os:find_executable("gleam") of
        false -> false;
        Gleam ->
            Args = ["format" | [unicode:characters_to_list(P) || P <- Paths]],
            Port = open_port({spawn_executable, Gleam},
                             [{args, Args}, binary, exit_status, stderr_to_stdout,
                              use_stdio, hide]),
            wait_for(Port)
    end.

wait_for(Port) ->
    receive
        {Port, {data, _}} -> wait_for(Port);
        {Port, {exit_status, Status}} -> Status =:= 0
    after 30000 ->
        try port_close(Port) catch _:_ -> ok end,
        false
    end.

%% Eight hex digits: enough to tell one generated module from another.
hash(Text) ->
    <<Hash:32>> = <<(erlang:phash2(Text, 4294967296)):32>>,
    list_to_binary(io_lib:format("~8.16.0b", [Hash])).

%% `gleam --version`, asked once per VM.
gleam_version() ->
    case persistent_term:get({?MODULE, gleam_version}, undefined) of
        undefined ->
            Version = case os:find_executable("gleam") of
                false -> <<>>;
                Gleam ->
                    Port = open_port({spawn_executable, Gleam},
                                     [{args, ["--version"]}, binary, exit_status,
                                      stderr_to_stdout, use_stdio, hide]),
                    string:trim(collect(Port, <<>>))
            end,
            persistent_term:put({?MODULE, gleam_version}, Version),
            Version;
        Version ->
            Version
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, _}} -> Acc
    after 10000 ->
        try port_close(Port) catch _:_ -> ok end,
        Acc
    end.
