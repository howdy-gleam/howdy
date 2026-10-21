-module(howdy_release_ffi).
-export([arguments/0, halt/1]).

%% The arguments after `--` in `gleam run -m howdy_release -- ...`.
arguments() ->
    [unicode:characters_to_binary(A) || A <- init:get_plain_arguments()].

halt(Code) ->
    erlang:halt(Code).
