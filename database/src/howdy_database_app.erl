-module(howdy_database_app).
-behaviour(application).
-behaviour(supervisor).
-export([start/2, stop/1, init/1]).

start(_Type, _Args) ->
    supervisor:start_link({local, howdy_database_supervisor}, ?MODULE, []).

stop(_State) -> ok.

init([]) ->
    Locks = #{id => howdy_database_locks,
              start => {howdy_database_locks, start_link, []},
              restart => permanent,
              shutdown => 5000,
              type => worker,
              modules => [howdy_database_locks]},
    {ok, {#{strategy => one_for_one, intensity => 3, period => 5}, [Locks]}}.
