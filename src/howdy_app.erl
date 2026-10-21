%% The howdy application: a supervisor for the processes the framework
%% keeps for the whole node: the `pg` scope behind WebSocket channels, and
%% the presence tracker with its own `pg` scope. They start at boot with the
%% application, and lazily from the first channel or presence call when the
%% node was not booted through the application controller, as in
%% `gleam test`.
-module(howdy_app).
-behaviour(application).
-behaviour(supervisor).
-export([start/2, stop/1, init/1, ensure_started/0]).

-define(SCOPE, howdy_websocket_channels).
-define(PRESENCE_SCOPE, howdy_presence_scope).

start(_Type, _Args) ->
    supervisor:start_link({local, howdy_supervisor}, ?MODULE, top).

stop(_State) -> ok.

init(top) ->
    Scope = #{id => channel_scope,
              start => {pg, start_link, [?SCOPE]},
              restart => permanent,
              shutdown => 5000,
              type => worker,
              modules => [pg]},
    Presence = #{id => presence,
                 start => {supervisor, start_link, [?MODULE, presence]},
                 restart => permanent,
                 shutdown => infinity,
                 type => supervisor,
                 modules => [?MODULE]},
    {ok, {#{strategy => one_for_one, intensity => 3, period => 5}, [Scope, Presence]}};
%% The tracker finds its peers through its scope, so a new scope means a
%% new tracker.
init(presence) ->
    Scope = #{id => presence_scope,
              start => {pg, start_link, [?PRESENCE_SCOPE]},
              restart => permanent,
              shutdown => 5000,
              type => worker,
              modules => [pg]},
    Tracker = #{id => presence_tracker,
                start => {howdy_presence, start_link, []},
                restart => permanent,
                shutdown => 5000,
                type => worker,
                modules => [howdy_presence]},
    {ok, {#{strategy => rest_for_one, intensity => 3, period => 5}, [Scope, Tracker]}}.

%% Make sure the scope is running, whichever way the node was started.
ensure_started() ->
    case whereis(?SCOPE) of
        undefined ->
            case application:ensure_all_started(howdy) of
                {ok, _} -> await_scope(50);
                {error, Reason} -> error({howdy_start_failed, Reason})
            end;
        _ ->
            ok
    end.

%% The supervisor restarts the scope if it dies; a caller that raced the
%% restart waits briefly for it.
await_scope(0) -> error({howdy_start_failed, channel_scope_missing});
await_scope(N) ->
    case whereis(?SCOPE) of
        undefined -> timer:sleep(10), await_scope(N - 1);
        _ -> ok
    end.
