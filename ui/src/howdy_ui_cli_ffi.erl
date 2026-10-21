-module(howdy_ui_cli_ffi).
-export([fetch/1, run/2, version/0]).

%% The version from the application resource file, which Gleam writes
%% from gleam.toml. `undefined` only when the application was never loaded.
version() ->
    _ = application:load(howdy_ui),
    case application:get_key(howdy_ui, vsn) of
        {ok, Vsn} -> {ok, unicode:characters_to_binary(Vsn)};
        undefined -> {error, nil}
    end.

%% GET a URL with OTP's httpc, verifying the server's certificate against
%% the system's trusted roots.
fetch(Url) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Ssl = [{verify, verify_peer},
           {cacerts, public_key:cacerts_get()},
           {customize_hostname_check,
            [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],
    Request = {binary_to_list(Url), [{"user-agent", "howdy_ui"}]},
    case httpc:request(get, Request, [{ssl, Ssl}, {timeout, 15000}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} -> {ok, Body};
        {ok, {{_, Status, _}, _, _}} ->
            {error, <<"HTTP status ", (integer_to_binary(Status))/binary>>};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Run a program with arguments, without a shell, and return its exit code
%% and output.
run(Program, Args) ->
    case os:find_executable(binary_to_list(Program)) of
        false -> {127, <<"could not find ", Program/binary>>};
        Path ->
            Port = open_port({spawn_executable, Path},
                             [{args, [binary_to_list(A) || A <- Args]},
                              exit_status, stderr_to_stdout, binary]),
            collect(Port, <<>>)
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, Status}} -> {Status, Acc}
    end.
