%% The process that owns auth's shared, named ETS tables.
%%
%% An ETS table dies with its owner, so a cache must not be owned by whichever
%% process happened to construct it: a request that builds an `Authorization`
%% or a provider would take the table with it when it ends, and every such
%% construction would leak a table until then. Instead there is one public
%% table per purpose (authorization decisions, provider keys), created lazily
%% by this small gen_server and held for as long as it lives. Handles returned
%% to Gleam are references that partition a table between instances, so
%% constructing a cache is free and leaks nothing. Reads and writes go
%% straight to the named table, never through this process.
%%
%% `start_link/0` is for a supervisor. Without one the owner is started on
%% first use, unlinked, and runs until the VM stops; a table missing while it
%% is being restarted makes its cache miss, never crash.
-module(howdy_auth_tables).
-behaviour(gen_server).
-export([start_link/0, ensure/1, versions/0, counter/1]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(VERSIONS, howdy_auth_cache_versions).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% The named public table `Name`, created by the owner if it does not exist.
ensure(Name) ->
    case ets:whereis(Name) of
        undefined -> call({ensure, Name});
        Table -> Table
    end.

%% One authorization cache generation counter for the life of the VM, so a
%% generation is never reused even across an owner restart. The owner decides
%% the race to create it.
versions() ->
    case persistent_term:get(?VERSIONS, undefined) of
        undefined -> call(versions);
        Versions -> Versions
    end.

%% One `counters` reference under `Key` for the life of the VM, such as the
%% SAML atom budget. Created by the owner, so two callers racing on first
%% use share one counter rather than each starting their own.
counter(Key) ->
    case persistent_term:get(Key, undefined) of
        undefined -> call({counter, Key});
        Counter -> Counter
    end.

call(Request) -> call(Request, 3).

call(Request, Attempts) ->
    _ = case whereis(?MODULE) of
        undefined -> gen_server:start({local, ?MODULE}, ?MODULE, [], []);
        _ -> ok
    end,
    try gen_server:call(?MODULE, Request)
    catch exit:{noproc, _} when Attempts > 1 -> call(Request, Attempts - 1)
    end.

init([]) -> {ok, nil}.

handle_call({ensure, Name}, _From, State) ->
    Table = case ets:whereis(Name) of
        undefined -> ets:new(Name, [named_table, public, set, {read_concurrency, true}]);
        Existing -> Existing
    end,
    {reply, Table, State};
handle_call({counter, Key}, _From, State) ->
    Counter = case persistent_term:get(Key, undefined) of
        undefined ->
            Created = counters:new(1, []),
            persistent_term:put(Key, Created),
            Created;
        Existing ->
            Existing
    end,
    {reply, Counter, State};
handle_call(versions, _From, State) ->
    Versions = case persistent_term:get(?VERSIONS, undefined) of
        undefined ->
            Created = atomics:new(1, []),
            persistent_term:put(?VERSIONS, Created),
            Created;
        Existing ->
            Existing
    end,
    {reply, Versions, State}.

handle_cast(_Request, State) -> {noreply, State}.
