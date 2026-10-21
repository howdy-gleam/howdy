-module(howdy_ui_app).
-behaviour(application).
-behaviour(supervisor).
-export([start/2, stop/1, init/1]).

start(_Type, _Args) ->
    supervisor:start_link({local, howdy_ui_supervisor}, ?MODULE, []).

stop(_State) -> ok.

%% The heir starts first and the owner reclaims the tables from it, so an
%% owner restart keeps every registered class. rest_for_one: should the heir
%% ever go, the owner restarts with fresh tables rather than a dead heir.
init([]) ->
    Heir = #{id => howdy_ui_heir,
             start => {howdy_ui_cache, start_heir, []},
             restart => permanent,
             shutdown => 5000,
             type => worker,
             modules => [howdy_ui_cache]},
    Owner = #{id => howdy_ui_cache,
              start => {howdy_ui_cache, start_link, []},
              restart => permanent,
              shutdown => 5000,
              type => worker,
              modules => [howdy_ui_cache]},
    {ok, {#{strategy => rest_for_one, intensity => 3, period => 5}, [Heir, Owner]}}.
