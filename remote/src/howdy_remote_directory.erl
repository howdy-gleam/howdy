-module(howdy_remote_directory).
-behaviour(gen_server).

%% A started server is a small directory process. It joins one `pg` group
%% per procedure name and answers "which function handles this name?".
%% Calls never run inside the directory: `erpc` starts a fresh process on
%% the serving node, that process fetches the handler from the directory
%% and runs it. A slow or crashing handler therefore only affects its own
%% call, and `erpc` reports timeouts, crashes and lost nodes to the caller.

-export([start_link/1, lookup/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link(Handlers) ->
    gen_server:start_link(?MODULE, Handlers, []).

%% The handler for `Name` from the directory `Pid`, which lives on this
%% node and may have stopped since the caller looked it up.
lookup(Pid, Name) ->
    try gen_server:call(Pid, {lookup, Name}, 5000) of
        {ok, Handler} -> {ok, Handler};
        error -> error
    catch
        exit:_ -> error
    end.

init(Handlers) ->
    Scope = howdy_remote_ffi:scope(),
    lists:foreach(fun(Name) -> ok = pg:join(Scope, Name, self()) end, maps:keys(Handlers)),
    {ok, Handlers}.

handle_call({lookup, Name}, _From, Handlers) ->
    {reply, maps:find(Name, Handlers), Handlers}.

handle_cast(_Message, Handlers) ->
    {noreply, Handlers}.

handle_info(_Message, Handlers) ->
    {noreply, Handlers}.
