-module(howdy_i18n_cli_ffi).
-export([halt/1, format/1]).

halt(Code) -> erlang:halt(Code).

%% Run `gleam format` on a generated file. Formatting is a courtesy, so a
%% missing or failing `gleam` is reported but not fatal.
format(Path) ->
    case os:find_executable("gleam") of
        false -> {error, nil};
        Gleam ->
            Port = erlang:open_port(
                {spawn_executable, Gleam},
                [{args, [<<"format">>, Path]}, exit_status, stderr_to_stdout, binary]
            ),
            wait(Port)
    end.

wait(Port) ->
    receive
        {Port, {data, _}} -> wait(Port);
        {Port, {exit_status, 0}} -> {ok, nil};
        {Port, {exit_status, _}} -> {error, nil}
    end.
