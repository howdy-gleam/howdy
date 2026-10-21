%% Helpers for the cluster tests: peer nodes, controlled over their standard
%% io rather than distribution, so they are only connected when a test says
%% so, and a process on each that keeps what it hears about a user.
-module(howdy_notifications_cluster_test_ffi).
-export([start_distribution/0, start_peer/1, stop_peer/1, connect/2, peer_nodes/1,
         run/4, listen_as/1, heard/0, keep/1, kept/0, fan_out_running/0,
         eventually/2]).

start_distribution() ->
    _ = os:cmd("epmd -daemon"),
    case net_kernel:start('howdy_notifications_test@localhost', #{name_domain => shortnames}) of
        {ok, _} -> nil;
        {error, {already_started, _}} -> nil
    end.

%% A peer with this node's code, connected to this node if `Connect`.
start_peer(Connect) ->
    Paths = [P || P <- code:get_path(), string:find(P, "/build/") =/= nomatch],
    Name = list_to_atom("howdy_notifications_peer_" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, Peer, Node} = peer:start(#{
        name => Name,
        host => "localhost",
        connection => standard_io,
        args => ["-setcookie", atom_to_list(erlang:get_cookie())
                 | lists:append([["-pa", P] || P <- Paths])]
    }),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [howdy_notifications]),
    case Connect of
        true -> true = net_kernel:connect_node(Node);
        false -> ok
    end,
    {Peer, Node}.

stop_peer({Peer, _Node}) ->
    peer:stop(Peer),
    nil.

%% Connect two peers to each other.
connect({Peer, _}, {_, Other}) ->
    true = peer:call(Peer, net_kernel, connect_node, [Other]),
    nil.

peer_nodes({Peer, _}) ->
    peer:call(Peer, erlang, nodes, []).

run({Peer, _}, Module, Function, Args) ->
    peer:call(Peer, binary_to_atom(Module), binary_to_atom(Function), Args, 30000).

%% Subscribe a process to `Recipient`'s events, keeping each it hears.
listen_as(Recipient) ->
    Parent = self(),
    Pid = spawn(fun() ->
        Me = self(),
        _ = howdy_notifications_ffi:subscribe(Recipient, Me, fun(Event) -> Me ! {heard, Event} end),
        Parent ! {listening, Me},
        collect([])
    end),
    receive {listening, Pid} -> nil after 5000 -> erlang:error(listen_timeout) end.

collect(Heard) ->
    receive
        {heard, Event} ->
            persistent_term:put(howdy_notifications_heard, Heard ++ [Event]),
            collect(Heard ++ [Event])
    end.

heard() ->
    persistent_term:get(howdy_notifications_heard, []).

keep(Value) ->
    persistent_term:put(howdy_notifications_kept, Value),
    nil.

kept() ->
    persistent_term:get(howdy_notifications_kept).

fan_out_running() ->
    whereis(howdy_notifications_fan_out) =/= undefined.

%% Poll `Check` until it is true or `Timeout` ms pass.
eventually(Check, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    eventually_loop(Check, Deadline).

eventually_loop(Check, Deadline) ->
    case Check() of
        true -> nil;
        false ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> timer:sleep(10), eventually_loop(Check, Deadline);
                false -> erlang:error(eventually_timeout)
            end
    end.
