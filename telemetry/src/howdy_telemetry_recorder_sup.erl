-module(howdy_telemetry_recorder_sup).
-behaviour(supervisor).

%% One `howdy_telemetry_recorder_owner` child per recorder, started by
%% `howdy_telemetry_recorder:new/1`. A child is temporary: its tables are
%% the recorder, so there is nothing to restart it into.

-export([start_link/0, start_owner/2, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_owner(Creator, Keep) ->
    supervisor:start_child(?MODULE, [Creator, Keep]).

init([]) ->
    Owner = #{id => howdy_telemetry_recorder_owner,
              start => {howdy_telemetry_recorder_owner, start_link, []},
              restart => temporary,
              shutdown => 5000,
              type => worker,
              modules => [howdy_telemetry_recorder_owner]},
    {ok, {#{strategy => simple_one_for_one, intensity => 3, period => 5}, [Owner]}}.
