%% Helpers for the presence tests: idle processes to track, a fake peer
%% tracker driven by the test, and peer nodes for the cluster tests.
-module(howdy_presence_test_ffi).
-export([idle/0, stop/1, tracker_pid/0, as_peer/0, send_to_tracker/1, peer_received/1,
         snapshot/3, delta/3, join_op/6, leave_op/4,
         start_distribution/0, start_peer/1, stop_peer/1, connect/1, disconnect/1,
         remote_track/5, remote_list/3, remote_count/3, remote_kill_tracker/1,
         remote_peer_count/1, node_name/1, eventually/2]).
-export([spawn_tracked/4, kill_tracker/0]).

%% A process that does nothing until stopped.
idle() ->
    spawn(fun() -> receive stop -> ok end end).

%% Stop a process and wait until it has exited.
stop(Pid) ->
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, _} -> nil after 5000 -> erlang:error(timeout) end.

tracker_pid() ->
    howdy_presence:tracker().

%% A stand-in for another node's tracker: a process that passes everything
%% the real tracker sends it on to the test process.
as_peer() ->
    Test = self(),
    spawn(fun Loop() ->
        receive
            stop -> ok;
            Message -> Test ! {peer_received, Message}, Loop()
        end
    end).

send_to_tracker(Message) ->
    howdy_presence:tracker() ! Message,
    nil.

%% The next message the fake peer got from the tracker, by its tag.
peer_received(Tag) ->
    receive
        {peer_received, Message} when element(1, Message) =:= Tag -> {ok, Message}
    after 1000 ->
        {error, nil}
    end.

snapshot(Peer, Seq, Rows) -> {snapshot, Peer, Seq, Rows}.
delta(Peer, Seq, Ops) -> {delta, Peer, Seq, Ops}.

join_op(Name, Topic, Key, Ref, Pid, Meta) ->
    {join, Name, Topic, Key, Ref, Pid, erlang:system_time(microsecond), Meta}.
leave_op(Name, Topic, Key, Ref) ->
    {leave, Name, Topic, Key, Ref}.

%% -- Peer nodes --------------------------------------------------------------

%% Make this node distributed so peers can connect. Both live on localhost:
%% a bare short name uses the machine's hostname, which may resolve to an
%% address the peer cannot reach.
start_distribution() ->
    _ = os:cmd("epmd -daemon"),
    case net_kernel:start('howdy_presence_test@localhost', #{name_domain => shortnames}) of
        {ok, _} -> nil;
        {error, {already_started, _}} -> nil
    end.

%% A peer controlled over its standard io rather than distribution, so the
%% only distribution link between the nodes is the one under test.
start_peer(Name) ->
    Paths = [P || P <- code:get_path(), string:find(P, "/build/") =/= nomatch],
    {ok, Peer, Node} = peer:start(#{
        name => binary_to_atom(<<Name/binary, "_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>),
        host => "localhost",
        connection => standard_io,
        args => ["-setcookie", atom_to_list(erlang:get_cookie())
                 | lists:append([["-pa", P] || P <- Paths])]
    }),
    peer:call(Peer, application, ensure_all_started, [howdy]),
    connect({Peer, Node}),
    {Peer, Node}.

stop_peer({Peer, _Node}) ->
    peer:stop(Peer),
    nil.

connect({_Peer, Node}) ->
    true = net_kernel:connect_node(Node),
    nil.

disconnect({_Peer, Node}) ->
    erlang:disconnect_node(Node),
    nil.

node_name({_Peer, Node}) ->
    atom_to_binary(Node).

%% Spawn a process on the peer that tracks itself, and return it.
remote_track({Peer, _}, Name, Topic, Key, Meta) ->
    peer:call(Peer, howdy_presence_test_ffi, spawn_tracked, [Name, Topic, Key, Meta]).

remote_list({Peer, _}, Name, Topic) ->
    peer:call(Peer, howdy_presence, list, [Name, Topic]).

remote_count({Peer, _}, Name, Topic) ->
    length(remote_list({Peer, ignored}, Name, Topic)).

remote_peer_count({Peer, _}) ->
    peer:call(Peer, howdy_presence, peer_count, []).

remote_kill_tracker({Peer, _}) ->
    peer:call(Peer, howdy_presence_test_ffi, kill_tracker, []).

spawn_tracked(Name, Topic, Key, Meta) ->
    Parent = self(),
    Pid = spawn(fun() ->
        howdy_presence:track(Name, Topic, Key, self(), Meta),
        Parent ! {tracked, self()},
        receive stop -> ok end
    end),
    receive {tracked, Pid} -> Pid after 5000 -> erlang:error(track_timeout) end.

%% Kill the tracker and wait for the supervisor to start another.
kill_tracker() ->
    Old = whereis(howdy_presence),
    exit(Old, kill),
    eventually(fun() ->
        case whereis(howdy_presence) of
            undefined -> false;
            Old -> false;
            _ -> true
        end
    end, 5000).

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
