%% The application callback behind `howdy.start_application`. The tree is
%% whatever the Gleam start function returns, so this module only adapts the
%% `{ok, Started}` a supervisor returns to the `{ok, Pid}` OTP expects.
-module(howdy_application).
-behaviour(application).
-export([start/2, stop/1, load_and_start/2, stop_application/1]).

start(_Type, Start) ->
    case Start() of
        {ok, {started, Pid, _Data}} -> {ok, Pid};
        {error, Reason} -> {error, Reason}
    end.

stop(_State) ->
    ok.

%% Register an application called `Name` whose only job is to run the tree
%% `Start` returns, then start it. Once it is an application, `init:stop()`
%% (which is what SIGTERM does) stops it in order: the supervisor asks each
%% child to shut down and waits, so the server drains its connections.
load_and_start(Name, Start) ->
    App = binary_to_atom(Name, utf8),
    Spec = {application, App,
            [{description, "howdy application"},
             {vsn, "0.0.0"},
             {registered, []},
             {applications, [kernel, stdlib]},
             {mod, {?MODULE, Start}}]},
    Load = case application:load(Spec) of
        ok -> ok;
        {error, {already_loaded, _}} ->
            case application:get_key(App, mod) of
                {ok, {?MODULE, _}} -> ok;
                _ -> {error, taken}
            end;
        {error, Other} -> {error, Other}
    end,
    case Load of
        ok ->
            case application:ensure_all_started(App) of
                {ok, _} ->
                    case application_controller:get_master(App) of
                        undefined -> {error, <<"the application did not start">>};
                        Master ->
                            {Pid, _Mod} = application_master:get_child(Master),
                            {ok, Pid}
                    end;
                {error, {App, {bad_return, {_, {error, {init_failed, Message}}}}}} when is_binary(Message) ->
                    {error, Message};
                {error, Reason} ->
                    {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
            end;
        {error, taken} ->
            {error, <<"an application called ", Name/binary, " already exists; pick another name">>};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

stop_application(Name) ->
    App = binary_to_atom(Name, utf8),
    _ = application:stop(App),
    _ = application:unload(App),
    nil.
