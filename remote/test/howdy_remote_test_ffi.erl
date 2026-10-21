-module(howdy_remote_test_ffi).
-export([start_distribution/0, start_peer/0, start_named_peer/1, stop_peer/1, crash/0,
         scope_supervised/0, connector_supervised/0, connected_nodes/0, sys_aware/1,
         elapsed_ms/1]).

%% Turn this node into a distributed one so peers can connect to it. Both
%% nodes live on `localhost`: a bare shortname uses the machine's hostname,
%% which may resolve to an address the peer cannot reach (e.g. LAN IPv6 only).
start_distribution() ->
    _ = os:cmd("epmd -daemon"),
    case net_kernel:start('howdy_remote_test@localhost', #{name_domain => shortnames}) of
        {ok, _} -> nil;
        {error, {already_started, _}} -> nil
    end.

%% Start a connected peer node that can load this project's modules.
start_peer() ->
    Paths = [P || P <- code:get_path(), string:find(P, "/build/") =/= nomatch],
    {ok, Peer, Node} = peer:start(#{
        name => peer:random_name(howdy_remote_peer),
        host => "localhost",
        args => lists:append([["-pa", P] || P <- Paths])
    }),
    {Peer, atom_to_binary(Node)}.

%% A peer with a fixed name, so it can be stopped and started again as the
%% same node, controlled over its standard io rather than distribution:
%% then nothing but the code under test connects the two nodes.
start_named_peer(Name) ->
    Paths = [P || P <- code:get_path(), string:find(P, "/build/") =/= nomatch],
    {ok, Peer, Node} = peer:start(#{
        name => binary_to_atom(Name),
        host => "localhost",
        connection => standard_io,
        args => ["-setcookie", atom_to_list(erlang:get_cookie())
                 | lists:append([["-pa", P] || P <- Paths])]
    }),
    {Peer, atom_to_binary(Node)}.

connected_nodes() ->
    [atom_to_binary(Node) || Node <- nodes()].

%% Is the connector a child of the application's supervisor?
connector_supervised() ->
    lists:any(fun({Id, Pid, _, _}) -> Id =:= howdy_remote_connector andalso is_pid(Pid) end,
              supervisor:which_children(howdy_remote_supervisor)).

stop_peer(Peer) ->
    peer:stop(Peer),
    nil.

crash() ->
    erlang:error(deliberate).

%% Is the pg scope a child of the application's supervisor?
scope_supervised() ->
    Scope = whereis(howdy_remote),
    is_pid(Scope) andalso
        lists:member(Scope, [Pid || {_, Pid, _, _} <- supervisor:which_children(howdy_remote_supervisor)]).

%% Does the process answer the `sys` debug protocol?
sys_aware(Pid) ->
    try sys:get_state(Pid, 1000) of
        State -> is_map(State)
    catch
        exit:_ -> false
    end.

elapsed_ms(Run) ->
    {Micros, _} = timer:tc(Run),
    Micros div 1000.
