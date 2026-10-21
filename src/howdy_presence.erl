%% The presence tracker behind howdy/websocket/presence.
%%
%% One tracker runs on each node, under the howdy application's supervisor.
%% It is the only writer of an ETS table holding every presence it knows
%% of, its own and its peers', which any process may read.
%%
%% Each tracker owns the presences of the processes on its node: it monitors
%% them and removes their presences when they exit. Nothing else ever
%% changes them, so replicas never conflict and no CRDT is needed. Trackers
%% find each other through a `pg` group. On meeting a peer, a tracker sends
%% it a snapshot of the presences it owns, then a numbered delta for every
%% change. Messages between two processes arrive in order while their nodes
%% stay connected, so a peer only needs the next number: a gap means
%% something was lost, and it asks for a fresh snapshot. When a peer's
%% tracker goes down, because it crashed or its node left or became
%% unreachable, its presences are dropped and announced as leaves. If the
%% node comes back, `pg` reports the tracker again and snapshots are swapped
%% once more.
%%
%% Rows are `{{Name, Topic, Key, Ref}, Owner, Pid, At, Meta}`: `Owner` is
%% the tracker that owns the row, `Pid` the tracked process, `At` the system
%% time it was tracked, which orders a key's metas, and `Ref` a random id
%% for this one presence, which clients use to merge diffs.
%%
%% Subscribers get `{howdy_presence_diff, Name, Topic, Joins, Leaves}`
%% after every change to a topic they subscribed to, with entries
%% `{Key, Ref, At, Meta}`. A tracker only notifies subscribers on its own
%% node; each node computes the same diffs from the deltas it receives.
-module(howdy_presence).
-behaviour(gen_server).

-export([start_link/0, track/5, untrack/4, list/2, subscribe/2, deliver/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([tracker/0, subscriber_count/2, peer_count/0]).

-define(TABLE, howdy_presence).
-define(SCOPE, howdy_presence_scope).
-define(GROUP, trackers).

%% -- API ---------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

track(Name, Topic, Key, Pid, Meta) ->
    call({track, Name, Topic, Key, Pid, Meta}).

untrack(Name, Topic, Key, Pid) ->
    call({untrack, Name, Topic, Key, Pid}).

%% Every presence on a topic, ordered by key and then by when it was
%% tracked. Read straight from the table: a key prefix on an ordered set
%% only visits the topic's rows.
list(Name, Topic) ->
    tracker(),
    Rows = ets:select(?TABLE, [{{{Name, Topic, '_', '_'}, '_', '_', '_', '_'}, [], ['$_']}]),
    by_key([{Key, Ref, At, Meta} || {{_, _, Key, Ref}, _, _, At, Meta} <- Rows]).

%% Subscribe the calling process to a topic's diffs. Returns the topic's
%% presences at that moment, so nothing falls between the list and the
%% first diff.
subscribe(Name, Topic) ->
    call({subscribe, Name, Topic}).

%% Send a frame to a socket process, as howdy/websocket/channel does.
deliver(Pid, Frame) ->
    Pid ! {howdy_websocket, Frame},
    nil.

%% Make sure the tracker is running, whichever way the node was started.
tracker() ->
    howdy_app:ensure_started(),
    case whereis(?MODULE) of
        undefined -> await_tracker(50);
        Pid -> Pid
    end.

await_tracker(0) -> error({howdy_start_failed, presence_tracker_missing});
await_tracker(N) ->
    case whereis(?MODULE) of
        undefined -> timer:sleep(10), await_tracker(N - 1);
        Pid -> Pid
    end.

subscriber_count(Name, Topic) ->
    call({subscriber_count, Name, Topic}).

peer_count() ->
    call(peer_count).

call(Request) ->
    gen_server:call(tracker(), Request, infinity).

%% -- Tracker -----------------------------------------------------------------

%% seq: the number of the last delta this tracker sent.
%% peers: Tracker => #{monitor, seq}; seq is the last delta applied from it,
%%   or `undefined` until its snapshot arrives.
%% owners: tracked Pid => #{monitor, entries => #{{Name, Topic, Key} => Ref}}
%% subscribers: {Name, Topic} => #{Pid => true}
%% subscriptions: subscriber Pid => #{monitor, topics => [{Name, Topic}]}
init([]) ->
    ?TABLE = ets:new(?TABLE, [ordered_set, protected, named_table, {read_concurrency, true}]),
    ok = pg:join(?SCOPE, ?GROUP, self()),
    {Ref, Members} = pg:monitor(?SCOPE, ?GROUP),
    State0 = #{seq => 0, peers => #{}, owners => #{}, subscribers => #{},
               subscriptions => #{}, pg => Ref},
    {ok, lists:foldl(fun meet/2, State0, Members)}.

handle_call({track, Name, Topic, Key, Pid, Meta}, _From, State) ->
    Id = {Name, Topic, Key},
    Owner = owner(Pid, State),
    Entries = maps:get(entries, Owner),
    Leave = case Entries of
        #{Id := Old} -> [{leave, Name, Topic, Key, Old}];
        _ -> []
    end,
    Ref = new_ref(),
    Join = {join, Name, Topic, Key, Ref, Pid, erlang:system_time(microsecond), Meta},
    Owners = maps:put(Pid, Owner#{entries => Entries#{Id => Ref}}, maps:get(owners, State)),
    {reply, nil, change([Join | Leave], State#{owners => Owners})};

handle_call({untrack, Name, Topic, Key, Pid}, _From, State = #{owners := Owners}) ->
    Id = {Name, Topic, Key},
    case Owners of
        #{Pid := Owner = #{entries := #{Id := Ref} = Entries}} ->
            Rest = maps:remove(Id, Entries),
            Owners1 = case map_size(Rest) of
                0 ->
                    erlang:demonitor(maps:get(monitor, Owner), [flush]),
                    maps:remove(Pid, Owners);
                _ ->
                    Owners#{Pid => Owner#{entries => Rest}}
            end,
            {reply, nil, change([{leave, Name, Topic, Key, Ref}], State#{owners => Owners1})};
        _ ->
            {reply, nil, State}
    end;

handle_call({subscribe, Name, Topic}, {Pid, _}, State) ->
    #{subscribers := Subscribers, subscriptions := Subscriptions} = State,
    Topic1 = {Name, Topic},
    Subscription = case Subscriptions of
        #{Pid := Found} -> Found;
        _ -> #{monitor => erlang:monitor(process, Pid), topics => []}
    end,
    Topics = lists:usort([Topic1 | maps:get(topics, Subscription)]),
    Pids = maps:get(Topic1, Subscribers, #{}),
    State1 = State#{
        subscribers => Subscribers#{Topic1 => Pids#{Pid => true}},
        subscriptions => Subscriptions#{Pid => Subscription#{topics => Topics}}
    },
    {reply, list(Name, Topic), State1};

handle_call({subscriber_count, Name, Topic}, _From, State = #{subscribers := Subscribers}) ->
    {reply, map_size(maps:get({Name, Topic}, Subscribers, #{})), State};

handle_call(peer_count, _From, State = #{peers := Peers}) ->
    {reply, map_size(Peers), State}.

handle_cast(_Message, State) ->
    {noreply, State}.

%% A peer's snapshot replaces everything known of it. One from a tracker
%% not met yet means it found this one first, so meet it now.
handle_info({snapshot, Peer, Seq, Rows}, State) ->
    State1 = meet(Peer, State),
    Old = [{Ref, Row} || Row = {{_, _, _, Ref}, _, _, _, _} <- owned_by(Peer)],
    New = [{Ref, Row} || Row = {_, _, _, Ref, _, _, _} <- Rows],
    OldRefs = maps:from_list(Old),
    NewRefs = maps:from_list(New),
    Leaves = [{leave, Name, Topic, Key, Ref}
              || {Ref, {{Name, Topic, Key, _}, _, _, _, _}} <- Old,
                 not maps:is_key(Ref, NewRefs)],
    Joins = [{join, Name, Topic, Key, Ref, Pid, At, Meta}
             || {Ref, {Name, Topic, Key, _, Pid, At, Meta}} <- New,
                not maps:is_key(Ref, OldRefs)],
    notify(apply_ops(Peer, Joins ++ Leaves), State1),
    {noreply, set_peer_seq(Peer, Seq, State1)};

handle_info({delta, Peer, Seq, Ops}, State = #{peers := Peers}) ->
    case Peers of
        #{Peer := #{seq := Last}} when is_integer(Last), Seq =:= Last + 1 ->
            notify(apply_ops(Peer, Ops), State),
            {noreply, set_peer_seq(Peer, Seq, State)};
        #{Peer := #{seq := Last}} when is_integer(Last), Seq =< Last ->
            {noreply, State};
        #{Peer := #{seq := Last}} when is_integer(Last) ->
            % A delta went missing. Ignore the rest until a snapshot comes.
            Peer ! {resync, self()},
            {noreply, set_peer_seq(Peer, undefined, State)};
        _ ->
            % Not met, or its snapshot is still on its way.
            {noreply, State}
    end;

handle_info({resync, Peer}, State = #{peers := Peers}) ->
    case maps:is_key(Peer, Peers) of
        true -> send_snapshot(Peer, State);
        false -> ok
    end,
    {noreply, State};

handle_info({Ref, join, ?GROUP, Pids}, State = #{pg := Ref}) ->
    {noreply, lists:foldl(fun meet/2, State, Pids)};

%% A tracker that leaves the group is also seen going down; wait for that.
handle_info({Ref, leave, ?GROUP, _Pids}, State = #{pg := Ref}) ->
    {noreply, State};

handle_info({'DOWN', Monitor, process, Pid, _Reason}, State) ->
    #{peers := Peers, owners := Owners, subscriptions := Subscriptions} = State,
    case {Peers, Owners, Subscriptions} of
        {#{Pid := #{monitor := Monitor}}, _, _} ->
            Leaves = [{leave, Name, Topic, Key, Ref}
                      || {{Name, Topic, Key, Ref}, _, _, _, _} <- owned_by(Pid)],
            notify(apply_ops(Pid, Leaves), State),
            {noreply, State#{peers => maps:remove(Pid, Peers)}};
        {_, #{Pid := #{monitor := Monitor, entries := Entries}}, _} ->
            Leaves = [{leave, Name, Topic, Key, Ref}
                      || {{Name, Topic, Key}, Ref} <- maps:to_list(Entries)],
            {noreply, change(Leaves, State#{owners => maps:remove(Pid, Owners)})};
        {_, _, #{Pid := #{monitor := Monitor, topics := Topics}}} ->
            Subscribers = lists:foldl(
                fun(Topic, Acc) ->
                    Rest = maps:remove(Pid, maps:get(Topic, Acc, #{})),
                    case map_size(Rest) of
                        0 -> maps:remove(Topic, Acc);
                        _ -> Acc#{Topic => Rest}
                    end
                end,
                maps:get(subscribers, State),
                Topics
            ),
            {noreply, State#{subscribers => Subscribers,
                             subscriptions => maps:remove(Pid, Subscriptions)}};
        _ ->
            {noreply, State}
    end;

handle_info(_Message, State) ->
    {noreply, State}.

%% -- Internals ---------------------------------------------------------------

meet(Peer, State) when Peer =:= self() -> State;
meet(Peer, State = #{peers := Peers}) ->
    case maps:is_key(Peer, Peers) of
        true ->
            State;
        false ->
            Monitor = erlang:monitor(process, Peer),
            send_snapshot(Peer, State),
            State#{peers => Peers#{Peer => #{monitor => Monitor, seq => undefined}}}
    end.

send_snapshot(Peer, #{seq := Seq}) ->
    Rows = [{Name, Topic, Key, Ref, Pid, At, Meta}
            || {{Name, Topic, Key, Ref}, _, Pid, At, Meta} <- owned_by(self())],
    Peer ! {snapshot, self(), Seq, Rows}.

set_peer_seq(Peer, Seq, State = #{peers := Peers}) ->
    case Peers of
        #{Peer := Info} -> State#{peers => Peers#{Peer => Info#{seq => Seq}}};
        _ -> State
    end.

owned_by(Owner) ->
    ets:match_object(?TABLE, {'_', Owner, '_', '_', '_'}).

owner(Pid, #{owners := Owners}) ->
    case Owners of
        #{Pid := Owner} -> Owner;
        _ -> #{monitor => erlang:monitor(process, Pid), entries => #{}}
    end.

%% A change to this node's own presences: apply it, tell local subscribers
%% and send it on to every peer as the next delta.
change(Ops, State = #{seq := Seq, peers := Peers}) ->
    notify(apply_ops(self(), Ops), State),
    Next = Seq + 1,
    [Peer ! {delta, self(), Next, Ops} || Peer <- maps:keys(Peers)],
    State#{seq => Next}.

%% Apply ops owned by `Owner` to the table. Returns the diff per topic as
%% #{{Name, Topic} => {Joins, Leaves}}, with the entries in op order.
apply_ops(Owner, Ops) ->
    Diffs = lists:foldl(
        fun
            ({join, Name, Topic, Key, Ref, Pid, At, Meta}, Acc) ->
                ets:insert(?TABLE, {{Name, Topic, Key, Ref}, Owner, Pid, At, Meta}),
                add({Name, Topic}, join, {Key, Ref, At, Meta}, Acc);
            ({leave, Name, Topic, Key, Ref}, Acc) ->
                case ets:lookup(?TABLE, {Name, Topic, Key, Ref}) of
                    [{_, Owner, _, At, Meta}] ->
                        ets:delete(?TABLE, {Name, Topic, Key, Ref}),
                        add({Name, Topic}, leave, {Key, Ref, At, Meta}, Acc);
                    _ ->
                        Acc
                end
        end,
        #{},
        Ops
    ),
    maps:map(fun(_, {Joins, Leaves}) -> {lists:reverse(Joins), lists:reverse(Leaves)} end, Diffs).

add(Topic, Kind, Entry, Acc) ->
    {Joins, Leaves} = maps:get(Topic, Acc, {[], []}),
    case Kind of
        join -> Acc#{Topic => {[Entry | Joins], Leaves}};
        leave -> Acc#{Topic => {Joins, [Entry | Leaves]}}
    end.

notify(Diffs, #{subscribers := Subscribers}) ->
    maps:foreach(
        fun({Name, Topic} = Id, {Joins, Leaves}) ->
            [Pid ! {howdy_presence_diff, Name, Topic, by_key(Joins), by_key(Leaves)}
             || Pid <- maps:keys(maps:get(Id, Subscribers, #{}))]
        end,
        Diffs
    ).

%% Entries grouped as [{Key, [{Ref, Meta}]}], keys in order and each key's
%% metas oldest first.
by_key(Entries) ->
    Sorted = lists:sort(fun({K1, _, A1, _}, {K2, _, A2, _}) -> {K1, A1} =< {K2, A2} end, Entries),
    group(Sorted).

group([]) -> [];
group([{Key, _, _, _} | _] = Entries) ->
    {Same, Rest} = lists:splitwith(fun({K, _, _, _}) -> K =:= Key end, Entries),
    [{Key, [{Ref, Meta} || {_, Ref, _, Meta} <- Same]} | group(Rest)].

new_ref() ->
    base64:encode(crypto:strong_rand_bytes(9), #{mode => urlsafe, padding => false}).
