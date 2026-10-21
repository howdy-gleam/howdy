//// Presence across nodes. The first tests drive the tracker's peer protocol
//// by hand, standing in for another node's tracker; the rest start real
//// peer nodes.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/json
import gleam/list
import howdy/websocket/presence.{Diff, Entry}

fn names() {
  presence.new(
    "cluster",
    encode: fn(name) { json.object([#("name", json.string(name))]) },
    decoder: decode.field("name", decode.string, decode.success),
  )
}

fn meta(name: String) -> String {
  json.to_string(json.object([#("name", json.string(name))]))
}

@external(erlang, "howdy_presence_test_ffi", "idle")
fn idle() -> Pid

@external(erlang, "howdy_presence_test_ffi", "stop")
fn stop(pid: Pid) -> Nil

@external(erlang, "howdy_presence_test_ffi", "eventually")
fn eventually_within(check: fn() -> Bool, timeout: Int) -> Nil

fn eventually(check: fn() -> Bool) -> Nil {
  eventually_within(check, 10_000)
}

// -- The peer protocol -------------------------------------------------------

@external(erlang, "howdy_presence_test_ffi", "as_peer")
fn fake_peer() -> Pid

@external(erlang, "howdy_presence_test_ffi", "send_to_tracker")
fn send_to_tracker(message: Dynamic) -> Nil

@external(erlang, "howdy_presence_test_ffi", "peer_received")
fn peer_received(tag: Atom) -> Result(Dynamic, Nil)

@external(erlang, "howdy_presence_test_ffi", "snapshot")
fn snapshot(
  peer: Pid,
  seq: Int,
  rows: List(#(String, String, String, String, Pid, Int, String)),
) -> Dynamic

@external(erlang, "howdy_presence_test_ffi", "delta")
fn delta(peer: Pid, seq: Int, ops: List(Dynamic)) -> Dynamic

@external(erlang, "howdy_presence_test_ffi", "join_op")
fn join_op(
  name: String,
  topic: String,
  key: String,
  ref: String,
  pid: Pid,
  meta: String,
) -> Dynamic

@external(erlang, "howdy_presence_test_ffi", "leave_op")
fn leave_op(name: String, topic: String, key: String, ref: String) -> Dynamic

fn row(topic: String, key: String, ref: String, pid: Pid) {
  #("cluster", topic, key, ref, pid, 1, meta(key))
}

fn keys(topic: String) -> List(String) {
  presence.list(names(), topic) |> list.map(fn(entry) { entry.key })
}

/// The sequence number of a snapshot or delta, its third element.
fn seq_of(message: Dynamic) -> Int {
  let assert Ok(seq) = decode.run(message, decode.at([2], decode.int))
  seq
}

pub fn a_peer_snapshot_adds_its_presences_and_gets_ours_back_test() {
  let topic = "cluster:snapshot"
  let peer = fake_peer()
  let remote = idle()

  send_to_tracker(snapshot(peer, 0, [row(topic, "ada", "r1", remote)]))

  // Meeting a new peer, the tracker answers with its own snapshot.
  let assert Ok(_) = peer_received(atom.create("snapshot"))
  eventually(fn() { keys(topic) == ["ada"] })
  stop(peer)
  eventually(fn() { keys(topic) == [] })
  stop(remote)
}

pub fn deltas_apply_in_order_and_a_gap_asks_for_a_snapshot_test() {
  let topic = "cluster:deltas"
  let peer = fake_peer()
  let remote = idle()
  send_to_tracker(snapshot(peer, 5, []))
  let assert Ok(_) = peer_received(atom.create("snapshot"))

  send_to_tracker(
    delta(peer, 6, [join_op("cluster", topic, "ada", "r1", remote, meta("ada"))]),
  )
  eventually(fn() { keys(topic) == ["ada"] })

  // A repeat of an applied delta changes nothing.
  send_to_tracker(
    delta(peer, 6, [join_op("cluster", topic, "bob", "r2", remote, meta("bob"))]),
  )
  // Skipping 7 is a gap: the tracker asks for a snapshot and ignores
  // deltas until it comes.
  send_to_tracker(
    delta(peer, 8, [join_op("cluster", topic, "cy", "r3", remote, meta("cy"))]),
  )
  let assert Ok(_) = peer_received(atom.create("resync"))
  send_to_tracker(
    delta(peer, 9, [join_op("cluster", topic, "dee", "r4", remote, meta("dee"))]),
  )
  assert keys(topic) == ["ada"]

  // The snapshot replaces whatever the peer had: Ada left, Eve arrived.
  send_to_tracker(snapshot(peer, 9, [row(topic, "eve", "r5", remote)]))
  eventually(fn() { keys(topic) == ["eve"] })
  send_to_tracker(delta(peer, 10, [leave_op("cluster", topic, "eve", "r5")]))
  eventually(fn() { keys(topic) == [] })
  stop(peer)
  stop(remote)
}

pub fn local_changes_reach_peers_as_numbered_deltas_test() {
  let topic = "cluster:outbound"
  let peer = fake_peer()
  send_to_tracker(snapshot(peer, 0, []))
  let assert Ok(ours) = peer_received(atom.create("snapshot"))
  let local = idle()

  presence.track(names(), local, topic, key: "ada", meta: "Ada")

  let assert Ok(next) = peer_received(atom.create("delta"))
  assert seq_of(next) == seq_of(ours) + 1
  stop(local)
  let assert Ok(after) = peer_received(atom.create("delta"))
  assert seq_of(after) == seq_of(ours) + 2
  stop(peer)
}

pub fn subscribers_hear_of_a_peer_going_down_test() {
  let topic = "cluster:down"
  let peer = fake_peer()
  let remote = idle()
  send_to_tracker(snapshot(peer, 0, [row(topic, "ada", "r1", remote)]))
  eventually(fn() { keys(topic) == ["ada"] })
  let diffs = process.new_subject()
  let _ = presence.subscribe(names(), topic, diffs, fn(diff) { diff })

  stop(peer)

  assert process.receive(diffs, 1000)
    == Ok(Diff(topic:, joins: [], leaves: [Entry("ada", ["ada"])]))
  stop(remote)
}

// -- Real peer nodes ---------------------------------------------------------

type Peer

@external(erlang, "howdy_presence_test_ffi", "start_distribution")
fn start_distribution() -> Nil

@external(erlang, "howdy_presence_test_ffi", "start_peer")
fn start_peer(name: String) -> Peer

@external(erlang, "howdy_presence_test_ffi", "stop_peer")
fn stop_peer(peer: Peer) -> Nil

@external(erlang, "howdy_presence_test_ffi", "connect")
fn connect(peer: Peer) -> Nil

@external(erlang, "howdy_presence_test_ffi", "disconnect")
fn disconnect(peer: Peer) -> Nil

@external(erlang, "howdy_presence_test_ffi", "remote_track")
fn remote_track(
  peer: Peer,
  name: String,
  topic: String,
  key: String,
  meta: String,
) -> Pid

@external(erlang, "howdy_presence_test_ffi", "remote_count")
fn remote_count(peer: Peer, name: String, topic: String) -> Int

@external(erlang, "howdy_presence", "list")
fn local_rows(name: String, topic: String) -> Dynamic

@external(erlang, "howdy_presence_test_ffi", "remote_list")
fn remote_rows(peer: Peer, name: String, topic: String) -> Dynamic

@external(erlang, "howdy_presence_test_ffi", "remote_kill_tracker")
fn remote_kill_tracker(peer: Peer) -> Nil

@external(erlang, "howdy_presence", "peer_count")
fn peer_count() -> Int

fn with_peer(run: fn(Peer) -> a) -> a {
  start_distribution()
  let peer = start_peer("howdy_presence_peer")
  let value = run(peer)
  stop_peer(peer)
  value
}

pub fn presences_are_shared_both_ways_test() {
  use peer <- with_peer
  let topic = "cluster:both-ways"
  let local = idle()
  presence.track(names(), local, topic, key: "ada", meta: "Ada")

  let remote = remote_track(peer, "cluster", topic, "bob", meta("Bob"))

  eventually(fn() { keys(topic) == ["ada", "bob"] })
  eventually(fn() { remote_count(peer, "cluster", topic) == 2 })

  // A remote process that exits leaves everywhere.
  stop(remote)
  eventually(fn() { keys(topic) == ["ada"] })
  stop(local)
  eventually(fn() { remote_count(peer, "cluster", topic) == 0 })
}

pub fn a_stopped_node_leaves_test() {
  start_distribution()
  let peer = start_peer("howdy_presence_stopped")
  let topic = "cluster:stopped"
  let _ = remote_track(peer, "cluster", topic, "bob", meta("Bob"))
  eventually(fn() { keys(topic) == ["bob"] })
  let diffs = process.new_subject()
  let _ = presence.subscribe(names(), topic, diffs, fn(diff) { diff })

  stop_peer(peer)

  assert process.receive(diffs, 10_000)
    == Ok(Diff(topic:, joins: [], leaves: [Entry("bob", ["Bob"])]))
  assert keys(topic) == []
}

pub fn a_partition_drops_then_restores_presences_test() {
  use peer <- with_peer
  let topic = "cluster:partition"
  let _ = remote_track(peer, "cluster", topic, "bob", meta("Bob"))
  let local = idle()
  presence.track(names(), local, topic, key: "ada", meta: "Ada")
  eventually(fn() { keys(topic) == ["ada", "bob"] })

  disconnect(peer)
  eventually(fn() { keys(topic) == ["ada"] })
  eventually(fn() { remote_count(peer, "cluster", topic) == 1 })

  connect(peer)
  eventually(fn() { keys(topic) == ["ada", "bob"] })
  eventually(fn() { remote_count(peer, "cluster", topic) == 2 })
  stop(local)
}

pub fn a_restarted_tracker_is_met_again_test() {
  use peer <- with_peer
  let topic = "cluster:restart"
  let _ = remote_track(peer, "cluster", topic, "bob", meta("Bob"))
  eventually(fn() { keys(topic) == ["bob"] })

  // The new tracker knows nothing of Bob, whose process is not told to
  // track again, so Bob leaves; the new tracker is then met like any peer.
  remote_kill_tracker(peer)
  eventually(fn() { keys(topic) == [] })
  eventually(fn() { peer_count() == 1 })
  let _ = remote_track(peer, "cluster", topic, "cy", meta("Cy"))
  eventually(fn() { keys(topic) == ["cy"] })
}

pub fn both_nodes_converge_under_churn_test() {
  use peer <- with_peer
  let topic = "cluster:churn"
  let remote =
    int.range(from: 40, to: 0, with: [], run: list.prepend)
    |> list.map(fn(n) {
      remote_track(peer, "cluster", topic, "r" <> int.to_string(n), meta("r"))
    })
  let local =
    int.range(from: 40, to: 0, with: [], run: list.prepend)
    |> list.map(fn(n) {
      let pid = idle()
      presence.track(
        names(),
        pid,
        topic,
        key: "l" <> int.to_string(n),
        meta: "l",
      )
      pid
    })
  // Kill every other process on both sides while changes are still
  // arriving.
  list.index_map(list.append(remote, local), fn(pid, index) {
    case index % 2 {
      0 -> stop(pid)
      _ -> Nil
    }
  })

  eventually(fn() { list.length(keys(topic)) == 40 })
  eventually(fn() {
    remote_rows(peer, "cluster", topic) == local_rows("cluster", topic)
  })
  list.each(local, fn(pid) { process.kill(pid) })
}
