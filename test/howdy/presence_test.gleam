import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Pid}
import gleam/http/response
import gleam/json
import gleam/list
import gleam/string
import howdy
import howdy/testing
import howdy/websocket
import howdy/websocket/presence.{Diff, Entry}

type User {
  User(name: String, status: String)
}

fn encode(user: User) -> json.Json {
  json.object([
    #("name", json.string(user.name)),
    #("status", json.string(user.status)),
  ])
}

fn decoder() -> decode.Decoder(User) {
  use name <- decode.field("name", decode.string)
  use status <- decode.field("status", decode.string)
  decode.success(User(name:, status:))
}

fn users() {
  presence.new("users", encode:, decoder: decoder())
}

fn ada() {
  User("Ada", "online")
}

fn bob() {
  User("Bob", "online")
}

@external(erlang, "howdy_presence_test_ffi", "idle")
fn idle() -> Pid

@external(erlang, "howdy_presence_test_ffi", "stop")
fn stop(pid: Pid) -> Nil

@external(erlang, "howdy_presence_test_ffi", "eventually")
fn eventually_within(check: fn() -> Bool, timeout: Int) -> Nil

fn eventually(check: fn() -> Bool) -> Nil {
  eventually_within(check, 5000)
}

// -- One node ----------------------------------------------------------------

pub fn tracked_processes_are_listed_test() {
  let topic = "presence:listed"
  let a = idle()
  let b = idle()
  presence.track(users(), a, topic, key: "ada", meta: ada())
  presence.track(users(), b, topic, key: "bob", meta: bob())

  assert presence.list(users(), topic)
    == [Entry("ada", [ada()]), Entry("bob", [bob()])]
  assert presence.count(users(), topic) == 2
  stop(a)
  stop(b)
}

pub fn a_process_that_exits_leaves_test() {
  let topic = "presence:exits"
  let a = idle()
  presence.track(users(), a, topic, key: "ada", meta: ada())

  stop(a)

  eventually(fn() { presence.list(users(), topic) == [] })
}

pub fn a_key_stays_until_its_last_process_leaves_test() {
  let topic = "presence:tabs"
  let first = idle()
  let second = idle()
  presence.track(users(), first, topic, key: "ada", meta: ada())
  presence.track(users(), second, topic, key: "ada", meta: User("Ada", "away"))
  assert presence.list(users(), topic)
    == [Entry("ada", [ada(), User("Ada", "away")])]
  assert presence.count(users(), topic) == 1

  stop(first)
  eventually(fn() {
    presence.list(users(), topic) == [Entry("ada", [User("Ada", "away")])]
  })

  stop(second)
  eventually(fn() { presence.list(users(), topic) == [] })
}

pub fn tracking_again_replaces_the_meta_test() {
  let topic = "presence:update"
  let a = idle()
  presence.track(users(), a, topic, key: "ada", meta: ada())
  presence.track(users(), a, topic, key: "ada", meta: User("Ada", "typing"))

  assert presence.list(users(), topic)
    == [Entry("ada", [User("Ada", "typing")])]
  stop(a)
}

pub fn untrack_removes_one_presence_test() {
  let topic = "presence:untrack"
  let a = idle()
  presence.track(users(), a, topic, key: "ada", meta: ada())
  presence.track(users(), a, "presence:untrack-other", key: "ada", meta: ada())

  presence.untrack(users(), a, topic, key: "ada")
  presence.untrack(users(), a, topic, key: "nobody")

  assert presence.list(users(), topic) == []
  assert presence.count(users(), "presence:untrack-other") == 1
  stop(a)
}

pub fn names_and_topics_are_separate_test() {
  let cursors = presence.new("cursors", encode:, decoder: decoder())
  let a = idle()
  presence.track(users(), a, "presence:one", key: "ada", meta: ada())

  assert presence.list(cursors, "presence:one") == []
  assert presence.list(users(), "presence:two") == []
  stop(a)
}

pub fn metas_the_decoder_cannot_read_are_skipped_test() {
  let topic = "presence:decode"
  let names =
    presence.new(
      "users",
      encode: fn(name) { json.object([#("name", json.string(name))]) },
      decoder: decode.field("name", decode.string, decode.success),
    )
  let a = idle()
  let b = idle()
  presence.track(names, a, topic, key: "ada", meta: "Ada")
  presence.track(users(), b, topic, key: "bob", meta: bob())

  // Both decode as names; only Bob's has a status.
  assert presence.list(users(), topic) == [Entry("bob", [bob()])]
  assert presence.list(names, topic)
    == [Entry("ada", ["Ada"]), Entry("bob", ["Bob"])]
  assert presence.count(users(), topic) == 2
  stop(a)
  stop(b)
}

// -- Subscribing -------------------------------------------------------------

pub fn subscribers_get_the_current_list_then_diffs_test() {
  let topic = "presence:subscribe"
  let a = idle()
  presence.track(users(), a, topic, key: "ada", meta: ada())
  let diffs = process.new_subject()

  let current = presence.subscribe(users(), topic, diffs, fn(diff) { diff })
  assert current == [Entry("ada", [ada()])]

  let b = idle()
  presence.track(users(), b, topic, key: "bob", meta: bob())
  assert process.receive(diffs, 1000)
    == Ok(Diff(topic:, joins: [Entry("bob", [bob()])], leaves: []))

  presence.track(users(), b, topic, key: "bob", meta: User("Bob", "typing"))
  assert process.receive(diffs, 1000)
    == Ok(
      Diff(topic:, joins: [Entry("bob", [User("Bob", "typing")])], leaves: [
        Entry("bob", [bob()]),
      ]),
    )

  stop(a)
  assert process.receive(diffs, 1000)
    == Ok(Diff(topic:, joins: [], leaves: [Entry("ada", [ada()])]))

  // Other topics are not sent.
  let c = idle()
  presence.track(users(), c, "presence:elsewhere", key: "cy", meta: ada())
  assert process.receive(diffs, 100) == Error(Nil)
  stop(b)
  stop(c)
}

@external(erlang, "howdy_presence", "subscriber_count")
fn subscriber_count(name: String, topic: String) -> Int

pub fn a_subscription_ends_with_its_process_test() {
  let topic = "presence:unsubscribe"
  let done = process.new_subject()
  let subscriber =
    process.spawn_unlinked(fn() {
      let _ =
        presence.subscribe(users(), topic, process.new_subject(), fn(d) { d })
      process.send(done, Nil)
      process.sleep_forever()
    })
  let assert Ok(Nil) = process.receive(done, 1000)
  assert subscriber_count("users", topic) == 1

  process.kill(subscriber)

  eventually(fn() { subscriber_count("users", topic) == 0 })
}

// -- Watching from a socket --------------------------------------------------

@external(erlang, "howdy_channel_ffi", "tuple_second")
fn tuple_second(message: dynamic.Dynamic) -> websocket.Frame

/// A stand-in socket watching `topic`, passing its text frames to the test.
/// Stop it with `stop` so it does not outlive the test.
fn watcher(topic: String) -> #(Pid, process.Subject(String)) {
  let frames = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      presence.watch_pid(users(), process.self(), topic)
      relay(frames)
    })
  #(pid, frames)
}

fn relay(frames: process.Subject(String)) -> Nil {
  let frame =
    process.new_selector()
    |> process.select_record(
      atom.create(websocket.channel_tag),
      1,
      tuple_second,
    )
    |> process.selector_receive_forever
  case frame {
    websocket.Text(text) -> process.send(frames, text)
    websocket.Binary(_) -> Nil
  }
  relay(frames)
}

pub fn a_watching_socket_gets_state_then_diffs_test() {
  let topic = "presence:watch"
  let a = idle()
  presence.track(users(), a, topic, key: "ada", meta: ada())

  let #(watching, frames) = watcher(topic)

  let assert Ok(state) = process.receive(frames, 1000)
  let assert Ok(#("state", "users", "presence:watch", [#("ada", [ada_meta])])) =
    json.parse(state, frame_decoder("entries"))
  assert ada_meta == ada()

  let b = idle()
  presence.track(users(), b, topic, key: "bob", meta: bob())
  let assert Ok(diff) = process.receive(frames, 1000)
  assert json.parse(diff, frame_decoder("joins"))
    == Ok(#("diff", "users", topic, [#("bob", [bob()])]))
  assert json.parse(diff, frame_decoder("leaves"))
    == Ok(#("diff", "users", topic, []))

  stop(a)
  let assert Ok(diff) = process.receive(frames, 1000)
  assert json.parse(diff, frame_decoder("leaves"))
    == Ok(#("diff", "users", topic, [#("ada", [ada()])]))
  stop(b)
  stop(watching)
}

pub fn frames_carry_a_ref_per_meta_test() {
  let topic = "presence:refs"
  let a = idle()
  presence.track(users(), a, topic, key: "ada", meta: ada())
  let b = idle()
  presence.track(users(), b, topic, key: "ada", meta: ada())

  let #(watching, frames) = watcher(topic)

  let assert Ok(state) = process.receive(frames, 1000)
  let ref = decode.at(["ref"], decode.string)
  let refs =
    decode.at(["entries"], decode.list(decode.at(["metas"], decode.list(ref))))
  let assert Ok([[first, second]]) = json.parse(state, refs)
  assert first != second
  assert string.length(first) == 12
  stop(a)
  stop(b)
  stop(watching)
}

fn frame_decoder(
  field: String,
) -> decode.Decoder(#(String, String, String, List(#(String, List(User))))) {
  let meta = decode.at(["meta"], decoder())
  let entry = {
    use key <- decode.field("key", decode.string)
    use metas <- decode.field("metas", decode.list(meta))
    decode.success(#(key, metas))
  }
  use kind <- decode.field("presence", decode.string)
  use name <- decode.field("name", decode.string)
  use topic <- decode.field("topic", decode.string)
  use entries <- decode.field(field, decode.list(entry))
  decode.success(#(kind, name, topic, entries))
}

// -- The client script -------------------------------------------------------

pub fn the_client_script_is_served_with_an_etag_test() {
  let app =
    howdy.new() |> howdy.controller(presence.client(at: "/howdy/presence.js"))

  let res = testing.get("/howdy/presence.js") |> testing.send(app)
  assert res.status == 200
  assert response.get_header(res, "content-type")
    == Ok("text/javascript; charset=utf-8")
  assert string.contains(testing.text(res), "export class Presence")
  let assert Ok(etag) = response.get_header(res, "etag")

  let again =
    testing.get("/howdy/presence.js")
    |> testing.header("if-none-match", etag)
    |> testing.send(app)
  assert again.status == 304
  assert testing.text(again) == ""
}

// -- The tracker -------------------------------------------------------------

@external(erlang, "howdy_presence_test_ffi", "tracker_pid")
fn tracker_pid() -> Pid

pub fn the_tracker_is_restarted_test() {
  let first = tracker_pid()
  process.kill(first)
  eventually(fn() { tracker_pid() != first })

  let a = idle()
  presence.track(users(), a, "presence:restart", key: "ada", meta: ada())
  assert presence.count(users(), "presence:restart") == 1
  stop(a)
}

pub fn keys_are_listed_in_order_test() {
  let topic = "presence:order"
  let pids =
    list.map(["carol", "ada", "bob"], fn(key) {
      let pid = idle()
      presence.track(users(), pid, topic, key:, meta: ada())
      pid
    })

  assert list.map(presence.list(users(), topic), fn(entry) { entry.key })
    == ["ada", "bob", "carol"]
  list.each(pids, stop)
}
