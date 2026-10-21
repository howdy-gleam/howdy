-module(behaviour_test_ffi).
-export([node_check/1]).

%% Run `node --check` on a file. Returns {ok, nil} when node accepts it,
%% {error, Output} when it does not, and skipped when node is not on PATH.
node_check(Path) ->
    case os:find_executable("node") of
        false ->
            skipped;
        Node ->
            Port = erlang:open_port({spawn_executable, Node},
                                    [{args, ["--check", binary_to_list(Path)]},
                                     exit_status, stderr_to_stdout, binary]),
            collect(Port, [])
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect(Port, [Data | Acc]);
        {Port, {exit_status, 0}} -> {ok, nil};
        {Port, {exit_status, _}} -> {error, iolist_to_binary(lists:reverse(Acc))}
    after 30000 ->
        {error, <<"node --check timed out">>}
    end.
