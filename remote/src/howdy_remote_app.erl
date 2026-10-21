-module(howdy_remote_app).
-behaviour(application).
-behaviour(supervisor).
-export([start/2, stop/1, init/1]).

%% Starts the `howdy_remote` pg scope under a supervisor, so it is linked,
%% restarted if it dies, and running before any server joins it. The FFI
%% starts this application on first use for callers outside a boot.

start(_Type, _Args) ->
    howdy_remote_ffi:init_casts(),
    supervisor:start_link({local, howdy_remote_supervisor}, ?MODULE, []).

stop(_State) -> ok.

init([]) ->
    Scope = #{id => howdy_remote_scope,
              start => {pg, start_link, [howdy_remote]},
              restart => permanent,
              shutdown => 5000,
              type => worker,
              modules => [pg]},
    {ok, {#{strategy => one_for_one, intensity => 3, period => 5}, [Scope]}}.
