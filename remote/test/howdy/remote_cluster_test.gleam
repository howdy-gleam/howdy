//// Calls between two real nodes. The test node becomes distributed and
//// starts a peer node that loads the same code, as a second service would.

import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/otp/static_supervisor
import gleam/string
import howdy/remote
import howdy/service
import howdy_remote_fixtures.{User} as fixtures

@external(erlang, "howdy_remote_test_ffi", "start_distribution")
fn start_distribution() -> Nil

@external(erlang, "howdy_remote_test_ffi", "start_peer")
fn start_peer() -> #(Pid, String)

@external(erlang, "howdy_remote_test_ffi", "stop_peer")
fn stop_peer(peer: Pid) -> Nil

@external(erlang, "howdy_remote_test_ffi", "start_named_peer")
fn start_named_peer(name: String) -> #(Pid, String)

@external(erlang, "howdy_remote_test_ffi", "connected_nodes")
fn connected_nodes() -> List(String)

@external(erlang, "howdy_remote_test_ffi", "connector_supervised")
fn connector_supervised() -> Bool

fn await(attempts: Int, every: Int, check: fn() -> Bool) -> Bool {
  case check(), attempts {
    True, _ -> True
    False, 0 -> False
    False, _ -> {
      process.sleep(every)
      await(attempts - 1, every, check)
    }
  }
}

fn with_peer(prefix: String, test_body: fn(String) -> Nil) -> Nil {
  start_distribution()
  let #(peer, node) = start_peer()
  // Start the server on the peer with a plain Erlang call.
  let assert Ok(True) =
    remote.apply(
      on: node,
      module: "howdy_remote_fixtures",
      function: "serve_users",
      args: [dynamic.string(prefix)],
      decoder: decode.bool,
      timeout: 5000,
    )
  assert fixtures.await_provider(fixtures.whoami(prefix), node, 100)
  test_body(node)
  stop_peer(peer)
}

pub fn cluster_call_reaches_another_node_test() {
  use node <- with_peer("peer_cluster")
  assert remote.call(
      remote.cluster(),
      fixtures.whoami("peer_cluster"),
      Nil,
      timeout: 2000,
    )
    == Ok(node)
  assert remote.call(
      remote.cluster(),
      fixtures.get_user("peer_cluster"),
      2,
      timeout: 2000,
    )
    == Error(remote.Failed(service.NotFound("user not found")))
}

pub fn node_target_test() {
  use node <- with_peer("peer_node")
  assert remote.call(
      remote.node(node),
      fixtures.get_user("peer_node"),
      1,
      timeout: 2000,
    )
    == Ok(User(id: 1, name: "Ada"))
}

pub fn cluster_prefers_this_node_test() {
  use node <- with_peer("peer_local")
  let assert Ok(_) = remote.start(fixtures.users_server("peer_local"))
  assert remote.providers(fixtures.whoami("peer_local"))
    == list.sort([node, remote.self()], string.compare)
  assert remote.call(
      remote.cluster(),
      fixtures.whoami("peer_local"),
      Nil,
      timeout: 2000,
    )
    == Ok(remote.self())
  assert remote.multicall(fixtures.whoami("peer_local"), Nil, timeout: 2000)
    == list.sort(
      [#(node, Ok(node)), #(remote.self(), Ok(remote.self()))],
      fn(a, b) { string.compare(a.0, b.0) },
    )
}

pub fn first_call_from_a_fresh_node_test() {
  start_distribution()
  let assert Ok(_) = remote.start(fixtures.users_server("fresh"))
  let #(peer, node) = start_peer()
  // The peer has never touched howdy_remote, so its scope starts during
  // this very call and knows no members yet.
  assert remote.apply(
      on: node,
      module: "howdy_remote_fixtures",
      function: "first_call_via_cluster",
      args: [dynamic.string("fresh")],
      decoder: decode.string,
      timeout: 5000,
    )
    == Ok(remote.self())
  stop_peer(peer)
}

pub fn stopped_node_test() {
  start_distribution()
  let #(peer, node) = start_peer()
  let assert Ok(True) =
    remote.apply(
      on: node,
      module: "howdy_remote_fixtures",
      function: "serve_users",
      args: [dynamic.string("peer_gone")],
      decoder: decode.bool,
      timeout: 5000,
    )
  assert fixtures.await_provider(fixtures.whoami("peer_gone"), node, 100)
  stop_peer(peer)
  assert fixtures.await_no_provider(fixtures.whoami("peer_gone"), node, 100)
  assert remote.providers(fixtures.whoami("peer_gone")) == []
  assert remote.call(
      remote.cluster(),
      fixtures.whoami("peer_gone"),
      Nil,
      timeout: 1000,
    )
    == Error(remote.NoHandler("peer_gone.whoami"))
  let assert Error(remote.Unavailable(_)) =
    remote.call(
      remote.node(node),
      fixtures.whoami("peer_gone"),
      Nil,
      timeout: 1000,
    )
}

pub fn a_connector_keeps_a_node_connected_test() {
  start_distribution()
  // Controlled over standard io, so only the connector links the nodes.
  let #(peer, node) = start_named_peer("howdy_remote_kept")
  assert !list.contains(connected_nodes(), node)
  assert remote.connect_to([node]) == Ok(Nil)
  assert connector_supervised()
  assert await(100, 20, fn() { list.contains(connected_nodes(), node) })
  // Naming it again is fine; so is adding another.
  assert remote.connect_to([node, "howdy_remote_absent@localhost"]) == Ok(Nil)

  stop_peer(peer)
  assert await(100, 20, fn() { !list.contains(connected_nodes(), node) })

  // Back under the same name: the connector notices and reconnects, after
  // its first backoff of a second.
  let #(peer, again) = start_named_peer("howdy_remote_kept")
  assert again == node
  assert await(100, 50, fn() { list.contains(connected_nodes(), node) })
  stop_peer(peer)
}

pub fn a_connector_can_live_in_the_apps_own_tree_test() {
  start_distribution()
  let #(peer, node) = start_named_peer("howdy_remote_own_tree")
  let assert Ok(supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(remote.connector_supervised([node]))
    |> static_supervisor.start
  assert await(100, 20, fn() { list.contains(connected_nodes(), node) })
  process.unlink(supervisor.pid)
  process.send_exit(supervisor.pid)
  stop_peer(peer)
}
