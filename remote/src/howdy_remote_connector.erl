-module(howdy_remote_connector).
-behaviour(gen_server).

%% Keeps a set of nodes connected. Erlang connects to a node once and does
%% not try again when the connection drops, so a service that depends on
%% another node needs something that does. This process connects to each
%% node it is given, watches `nodeup` and `nodedown`, and retries a lost
%% one with a backoff that doubles from a second to half a minute. Each
%% connection and each loss is logged once.

-export([start_link/1, child_spec/1, track/2, tracked/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(MIN_BACKOFF, 1000).
-define(MAX_BACKOFF, 30000).

%% Each node is `#{connected => boolean(), backoff => milliseconds()}`.

start_link(Nodes) ->
    gen_server:start_link(?MODULE, Nodes, []).

%% The child under `howdy_remote_supervisor`, restarted whatever happens.
child_spec(Nodes) ->
    #{id => howdy_remote_connector,
      start => {?MODULE, start_link, [Nodes]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [?MODULE]}.

%% Keep more nodes connected as well.
track(Pid, Nodes) ->
    gen_server:call(Pid, {track, Nodes}).

%% The nodes being kept connected, with whether each is now.
tracked(Pid) ->
    gen_server:call(Pid, tracked).

init(Nodes) ->
    ok = net_kernel:monitor_nodes(true),
    {ok, lists:foldl(fun add/2, #{}, Nodes)}.

add(Node, State) when is_map_key(Node, State) ->
    State;
add(Node, State) ->
    self() ! {retry, Node},
    State#{Node => #{connected => false, backoff => ?MIN_BACKOFF}}.

handle_call({track, Nodes}, _From, State) ->
    {reply, ok, lists:foldl(fun add/2, State, Nodes)};
handle_call(tracked, _From, State) ->
    {reply, [{Node, Connected} || {Node, #{connected := Connected}} <- maps:to_list(State)], State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({retry, Node}, State) ->
    case State of
        #{Node := #{connected := false} = Entry} ->
            case net_kernel:connect_node(Node) of
                true ->
                    {noreply, State#{Node := up(Node, Entry)}};
                _ ->
                    #{backoff := Backoff} = Entry,
                    erlang:send_after(Backoff, self(), {retry, Node}),
                    {noreply, State#{Node := Entry#{backoff := min(Backoff * 2, ?MAX_BACKOFF)}}}
            end;
        _ ->
            {noreply, State}
    end;
handle_info({nodeup, Node}, State) ->
    case State of
        #{Node := #{connected := false} = Entry} -> {noreply, State#{Node := up(Node, Entry)}};
        _ -> {noreply, State}
    end;
handle_info({nodedown, Node}, State) ->
    case State of
        #{Node := #{connected := true} = Entry} ->
            logger:warning("howdy_remote: lost ~ts, reconnecting", [Node]),
            erlang:send_after(?MIN_BACKOFF, self(), {retry, Node}),
            {noreply, State#{Node := Entry#{connected := false, backoff := ?MIN_BACKOFF}}};
        _ ->
            {noreply, State}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

%% Both a successful connect and the `nodeup` it causes land here; the
%% first marks the node connected, so the second says nothing.
up(Node, Entry) ->
    logger:info("howdy_remote: connected to ~ts", [Node]),
    Entry#{connected := true, backoff := ?MIN_BACKOFF}.
