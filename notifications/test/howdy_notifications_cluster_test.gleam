//// Notifications across nodes. A cluster hears announcements through `pg`;
//// servers that are not clustered hear them through PostgreSQL, with
//// `across_servers`. The other servers are peer nodes, connected to this
//// one only when a test says so.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import gloo/adapter/sqlite
import howdy/database
import howdy/database/postgres
import howdy/jobs
import howdy/migration
import howdy/notifications.{type Event, type Notifier, Received, Unread}

type Peer

@external(erlang, "howdy_notifications_cluster_test_ffi", "start_distribution")
fn start_distribution() -> Nil

@external(erlang, "howdy_notifications_cluster_test_ffi", "start_peer")
fn start_peer(connect: Bool) -> Peer

@external(erlang, "howdy_notifications_cluster_test_ffi", "stop_peer")
fn stop_peer(peer: Peer) -> Nil

@external(erlang, "howdy_notifications_cluster_test_ffi", "connect")
fn connect(peer: Peer, to other: Peer) -> Nil

@external(erlang, "howdy_notifications_cluster_test_ffi", "peer_nodes")
fn peer_nodes(peer: Peer) -> List(Dynamic)

@external(erlang, "howdy_notifications_cluster_test_ffi", "run")
fn run(peer: Peer, module: String, function: String, args: List(a)) -> b

@external(erlang, "howdy_notifications_cluster_test_ffi", "keep")
fn keep(notifier: Notifier) -> Nil

@external(erlang, "howdy_notifications_cluster_test_ffi", "kept")
fn kept() -> Notifier

@external(erlang, "howdy_notifications_cluster_test_ffi", "fan_out_running")
fn fan_out_running() -> Bool

@external(erlang, "howdy_notifications_cluster_test_ffi", "eventually")
fn eventually_within(check: fn() -> Bool, timeout: Int) -> Nil

@external(erlang, "howdy_notifications_test_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

fn eventually(check: fn() -> Bool) -> Nil {
  eventually_within(check, 10_000)
}

/// Call one of this module's functions on a peer.
fn on(peer: Peer, function: String, args: List(a)) -> b {
  run(peer, "howdy_notifications_cluster_test", function, args)
}

fn listen_on(peer: Peer, recipient: String) -> Nil {
  run(peer, "howdy_notifications_cluster_test_ffi", "listen_as", [recipient])
}

fn heard_on(peer: Peer) -> List(String) {
  run(peer, "howdy_notifications_cluster_test_ffi", "heard", [])
  |> list.map(describe)
}

fn describe(event: Event) -> String {
  case event {
    Received(notification) ->
      "notification: "
      <> notification.title
      <> " ("
      <> int.to_string(string.length(notification.body))
      <> ")"
    Unread(count) -> "unread: " <> int.to_string(count)
  }
}

/// What `heard_on` gives, once it has it, checked again a moment later so
/// that nothing is heard twice.
fn hears(peer: Peer, expected: List(String)) -> Nil {
  eventually(fn() { heard_on(peer) == expected })
  process.sleep(200)
  assert heard_on(peer) == expected
}

fn recipient() -> String {
  "cluster_" <> int.to_string(int.random(1_000_000_000))
}

fn sqlite_notifier() -> Notifier {
  let assert Ok(db) = sqlite.start(sqlite.memory())
  let assert Ok(Nil) = database.sqlite_defaults(db)
  let assert Ok(Nil) =
    migration.run(db, [jobs.schema(), notifications.schema()])
  notifications.new(db)
}

// -- In a cluster --------------------------------------------------------------

pub fn a_node_of_the_cluster_hears_announcements_test() {
  start_distribution()
  let peer = start_peer(True)
  let user = recipient()
  listen_on(peer, user)
  eventually(fn() { notifications.subscribers(user) == 1 })
  let assert Ok(Some(_)) =
    notifications.draft("x", "Hi")
    |> notifications.send(sqlite_notifier(), to: user)
  hears(peer, ["notification: Hi (0)", "unread: 1"])
  stop_peer(peer)
}

pub fn across_servers_on_sqlite_announces_as_before_test() {
  let notifier = sqlite_notifier()
  let child = notifications.across_servers(notifier)
  let assert Ok(started) = child.start()
  assert fan_out_running()
  let user = recipient()
  let events = process.new_subject()
  notifications.subscribe(user, events)
  let assert Ok(Some(_)) =
    notifications.draft("x", "Hi") |> notifications.send(notifier, to: user)
  let assert Ok(Received(n)) = process.receive(events, 1000)
  assert n.title == "Hi"
  assert process.receive(events, 1000) == Ok(Unread(1))
  assert process.receive(events, 100) == Error(Nil)
  process.unlink(started.pid)
  process.kill(started.pid)
  eventually(fn() { !fan_out_running() })
}

// -- Across servers, through PostgreSQL ----------------------------------------

/// Run on a peer: open the database, start `across_servers`, and keep the
/// notifier for `send_here` and `read_here`.
pub fn serve(url: String) -> Nil {
  let ready = process.new_subject()
  process.spawn_unlinked(fn() {
    let assert Ok(db) = postgres.from_url(url) |> result.try(postgres.start)
    let assert Ok(Nil) =
      migration.run(db, [jobs.schema(), notifications.schema()])
    let notifier = notifications.new(db)
    let assert Ok(_) = notifications.across_servers(notifier).start()
    keep(notifier)
    process.send(ready, Nil)
    process.sleep_forever()
  })
  let assert Ok(Nil) = process.receive(ready, 20_000)
  Nil
}

pub fn send_here(recipient: String, title: String, body: String) -> Nil {
  let assert Ok(Some(_)) =
    notifications.draft("x", title)
    |> notifications.body(body)
    |> notifications.send(kept(), to: recipient)
  Nil
}

pub fn read_here(recipient: String) -> Nil {
  let assert Ok(Nil) = notifications.mark_all_read(kept(), recipient)
  Nil
}

fn two_servers(url: String, clustered: Bool) -> #(Peer, Peer) {
  let a = start_peer(False)
  let b = start_peer(False)
  case clustered {
    True -> connect(a, to: b)
    False -> Nil
  }
  on(a, "serve", [url])
  on(b, "serve", [url])
  #(a, b)
}

pub fn servers_that_are_not_clustered_hear_through_postgres_test() {
  case getenv("HOWDY_NOTIFICATIONS_TEST_POSTGRES_URL") {
    Error(Nil) -> Nil
    Ok(url) -> {
      let #(a, b) = two_servers(url, False)
      assert peer_nodes(a) == []
      assert peer_nodes(b) == []
      let user = recipient()
      listen_on(a, user)
      listen_on(b, user)
      on(a, "send_here", [user, "Hi", ""])
      // The server that sent it hears it once too.
      hears(a, ["notification: Hi (0)", "unread: 1"])
      hears(b, ["notification: Hi (0)", "unread: 1"])
      // Too long for a NOTIFY: it goes by ID and is read back.
      on(a, "send_here", [user, "Long", string.repeat("x", 9000)])
      hears(b, [
        "notification: Hi (0)", "unread: 1", "notification: Long (9000)",
        "unread: 2",
      ])
      on(b, "read_here", [user])
      hears(a, [
        "notification: Hi (0)", "unread: 1", "notification: Long (9000)",
        "unread: 2", "unread: 0",
      ])
      stop_peer(a)
      stop_peer(b)
    }
  }
}

pub fn clustered_servers_across_servers_hear_once_test() {
  case getenv("HOWDY_NOTIFICATIONS_TEST_POSTGRES_URL") {
    Error(Nil) -> Nil
    Ok(url) -> {
      let #(a, b) = two_servers(url, True)
      let assert [node] = peer_nodes(a)
      assert node == run(b, "erlang", "node", [])
      let user = recipient()
      listen_on(b, user)
      on(a, "send_here", [user, "Hi", ""])
      hears(b, ["notification: Hi (0)", "unread: 1"])
      stop_peer(a)
      stop_peer(b)
    }
  }
}
