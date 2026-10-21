%% The process that owns the in-memory session store's ETS table.
%%
%% An ETS table dies with its owner, so `session_store.memory()` must not let
%% the calling process own it: a restart of that process (or the end of a
%% request that happened to build the store) would take every session with
%% it and turn each `authenticate` into a crash. Instead this small gen_server
%% creates the table and holds it for as long as it lives.
%%
%% Lifecycle. `start/0` starts the owner unlinked: it outlives the caller and a
%% crash in either does not reach the other, and it runs until the VM stops.
%% `start_link/1` is for a supervisor, which then decides when it stops and
%% restarts it after a crash. The store never holds the table id, because a
%% restarted owner has a new table: it holds a reference, under which the
%% owner publishes the current table in `persistent_term` and withdraws it on
%% a clean shutdown. Operations resolve the reference on each call, so they
%% find the new table after a restart and fail closed, never crash, while
%% there is none.
-module(howdy_auth_sessions).
-behaviour(gen_server).
-export([new_ref/0, start/0, start_link/1, table/1]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

new_ref() -> make_ref().

start() ->
    Ref = new_ref(),
    {ok, _} = gen_server:start(?MODULE, Ref, []),
    Ref.

start_link(Ref) -> gen_server:start_link(?MODULE, Ref, []).

%% The table currently published for a reference, or `undefined` while the
%% owner is not running.
table(Ref) -> persistent_term:get({?MODULE, Ref}, undefined).

init(Ref) ->
    %% Trap exits so a supervisor's shutdown reaches terminate/2 and the
    %% stale table is withdrawn rather than left to fail lookups.
    process_flag(trap_exit, true),
    Table = ets:new(howdy_auth_sessions, [public, set, {read_concurrency, true}]),
    persistent_term:put({?MODULE, Ref}, Table),
    {ok, Ref}.

handle_call(_Request, _From, Ref) -> {reply, ok, Ref}.

handle_cast(_Request, Ref) -> {noreply, Ref}.

terminate(_Reason, Ref) ->
    persistent_term:erase({?MODULE, Ref}),
    ok.
