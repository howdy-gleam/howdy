-module(howdy_telemetry_recorder_owner).
-behaviour(gen_server).

%% Owns a recorder's three public ETS tables, so a recorder made in a
%% short-lived process still outlives it, and sweeps orphaned spans. It is
%% a child of `howdy_telemetry_recorder_sup` and stops, taking the tables
%% with it, when the process that called `recorder.new` exits, which in an
%% app is `main`.

-export([start_link/2, tables/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SWEEP_MS, 30000).

-record(state, {tables, creator}).

start_link(Creator, Keep) ->
    gen_server:start_link(?MODULE, {Creator, Keep}, []).

tables(Owner) ->
    gen_server:call(Owner, tables).

init({Creator, Keep}) ->
    Tables = howdy_telemetry_recorder:create_tables(Keep),
    Ref = erlang:monitor(process, Creator),
    erlang:send_after(?SWEEP_MS, self(), sweep),
    {ok, #state{tables = Tables, creator = Ref}}.

handle_call(tables, _From, State = #state{tables = Tables}) ->
    {reply, Tables, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(sweep, State = #state{tables = Tables}) ->
    howdy_telemetry_recorder:sweep(Tables),
    erlang:send_after(?SWEEP_MS, self(), sweep),
    {noreply, State};
handle_info({'DOWN', Ref, process, _, _}, State = #state{creator = Ref}) ->
    {stop, normal, State};
handle_info(_Message, State) ->
    {noreply, State}.
