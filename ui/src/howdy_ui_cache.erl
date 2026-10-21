-module(howdy_ui_cache).
-behaviour(gen_server).
-export([start_link/0, start_heir/0, tables/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% Own the tables independently of renderers. All normal cache access remains
%% direct ETS access; the server only participates in startup and supervision.
%%
%% Two processes share this module. The heir does nothing but exist: the
%% tables name it as their heir, so when the owner dies they pass to it
%% rather than being deleted, and the restarted owner takes them back. Every
%% class registered before the crash stays available throughout.

%% The class registry ({Name, Seq, Css}) and the name memo ({Class, Name}).
tables() -> [howdy_ui_classes, howdy_ui_names].

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, owner, []).

start_heir() ->
    gen_server:start_link({local, howdy_ui_heir}, ?MODULE, heir, []).

init(heir) ->
    {ok, heir};
init(owner) ->
    Heir = whereis(howdy_ui_heir),
    [own(Table, Heir) || Table <- tables()],
    {ok, owner}.

own(Table, Heir) ->
    case reclaim(Table, Heir) of
        ok -> ok;
        none ->
            Heirship = case is_pid(Heir) of
                true -> [{heir, Heir, nil}];
                false -> []
            end,
            Options = [set, public, named_table, {read_concurrency, true}],
            ets:new(Table, Options ++ Heirship)
    end.

reclaim(_Table, undefined) -> none;
reclaim(Table, Heir) -> gen_server:call(Heir, {reclaim, Table}, 5000).

handle_call(ready, _From, State) ->
    {reply, ok, State};
handle_call({reclaim, Table}, {Owner, _}, heir) ->
    case ets:info(Table, owner) of
        Self when Self =:= self() ->
            true = ets:give_away(Table, Owner, nil),
            {reply, ok, heir};
        _ ->
            {reply, none, heir}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.

%% 'ETS-TRANSFER' notices arrive whenever a table changes hands.
handle_info(_Message, State) -> {noreply, State}.
