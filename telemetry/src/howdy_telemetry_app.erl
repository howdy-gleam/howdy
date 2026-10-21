-module(howdy_telemetry_app).
-behaviour(application).
-behaviour(supervisor).
-export([start/2, stop/1, init/1]).

%% The OpenTelemetry SDK is an application, so it starts at boot with its
%% defaults, before any app code runs, and those defaults export to
%% localhost:4318. Until `telemetry.start` configures it, stop that provider
%% so adding the package records and sends nothing by itself.
start(_Type, _Args) ->
    ok = howdy_telemetry_ffi:check_sdk_shape(),
    howdy_telemetry_ffi:idle(),
    supervisor:start_link({local, howdy_telemetry_supervisor}, ?MODULE, []).

stop(_State) ->
    ok.

init([]) ->
    Recorders = #{id => howdy_telemetry_recorder_sup,
                  start => {howdy_telemetry_recorder_sup, start_link, []},
                  restart => permanent,
                  shutdown => infinity,
                  type => supervisor,
                  modules => [howdy_telemetry_recorder_sup]},
    {ok, {#{strategy => one_for_one, intensity => 3, period => 5}, [Recorders]}}.
