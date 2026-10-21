//// Who is on a topic right now, across every connected node.
////
//// A process tracks itself on a topic under a key, usually a user id, with
//// a meta value describing it, such as a name or a status. One key can be
//// tracked by several processes, as when someone has the page open in two
//// tabs: the key stays present until the last of them leaves.
////
//// ```gleam
//// import howdy/websocket
//// import howdy/websocket/presence
////
//// let users = presence.new("users", encode: user_to_json, decoder: user_decoder())
////
//// websocket.new(fn(socket) {
////   presence.track(users, process.self(), "room:" <> room, key: user.id, meta: user)
////   presence.watch(users, socket, "room:" <> room)
////   Nil
//// })
//// ```
////
//// A watching socket is sent the topic's presences as soon as it watches,
//// then a diff of joins and leaves after every change. The browser keeps the
//// list with the client script served by `client`:
////
//// ```js
//// import { Presence } from "/howdy/presence.js"
//// const users = new Presence({ name: "users", topic: "room:lobby" })
//// users.onSync((list) => render(list))
//// socket.onmessage = (event) => {
////   const message = JSON.parse(event.data)
////   if (users.receive(message)) return
////   // the app's own messages
//// }
//// ```
////
//// Server code, such as a live view, can `subscribe` instead and get the
//// same diffs as messages.
////
//// A presence lasts as long as the process that tracked it. Nothing needs
//// cleaning up when a socket closes or crashes. Each node runs a tracker
//// that owns its own processes' presences and shares them with the trackers
//// on the other nodes, so `list` answers for the whole cluster from local
//// memory. When a node goes away, its presences leave on the others; if it
//// comes back, they rejoin. A tracker that crashes forgets its node's
//// presences, as their processes are not told to track again.
////
//// Metas travel as JSON, so a node running different code can still read
//// them: a meta that `decoder` cannot read is skipped by `list` and
//// `subscribe`, and passed to the browser as it is.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http/request
import gleam/http/response
import gleam/json.{type Json}
import gleam/list
import gleam/string
import howdy/content
import howdy/controller.{type Controller}
import howdy/websocket.{type Socket}

/// One kind of presence, such as the users in a room or the cursors on a
/// document. `name` keeps kinds apart, so two kinds can share topics. Every
/// node must use the same name for the same kind.
pub opaque type Presence(meta) {
  Presence(name: String, encode: fn(meta) -> Json, decoder: Decoder(meta))
}

/// A key and the metas of the processes tracking it, oldest first.
pub type Entry(meta) {
  Entry(key: String, metas: List(meta))
}

/// What changed on a topic. Tracking an existing process again with a new
/// meta is a join of the new meta and a leave of the old one, so the key
/// can appear on both sides; it is only gone once no metas remain.
pub type Diff(meta) {
  Diff(topic: String, joins: List(Entry(meta)), leaves: List(Entry(meta)))
}

pub fn new(
  name: String,
  encode encode: fn(meta) -> Json,
  decoder decoder: Decoder(meta),
) -> Presence(meta) {
  Presence(name:, encode:, decoder:)
}

// -- Tracking ----------------------------------------------------------------

type Rows =
  List(#(String, List(#(String, String))))

@external(erlang, "howdy_presence", "track")
fn track_row(
  name: String,
  topic: String,
  key: String,
  pid: Pid,
  meta: String,
) -> Nil

@external(erlang, "howdy_presence", "untrack")
fn untrack_row(name: String, topic: String, key: String, pid: Pid) -> Nil

@external(erlang, "howdy_presence", "list")
fn rows(name: String, topic: String) -> Rows

/// Track `pid` on `topic` under `key` until the process exits or calls
/// `untrack`. In a socket callback, `pid` is `process.self()`. Tracking the
/// same process, topic and key again replaces its meta, which is how a
/// status such as "typing" is updated.
pub fn track(
  presence: Presence(meta),
  pid: Pid,
  topic: String,
  key key: String,
  meta meta: meta,
) -> Nil {
  track_row(
    presence.name,
    topic,
    key,
    pid,
    json.to_string(presence.encode(meta)),
  )
}

/// Stop tracking `pid` on `topic` under `key`. Does nothing if it was not.
pub fn untrack(
  presence: Presence(meta),
  pid: Pid,
  topic: String,
  key key: String,
) -> Nil {
  untrack_row(presence.name, topic, key, pid)
}

/// Everyone on a topic, ordered by key.
pub fn list(presence: Presence(meta), topic: String) -> List(Entry(meta)) {
  entries(presence, rows(presence.name, topic))
}

/// How many keys are on a topic. Someone with two tabs open counts once.
pub fn count(presence: Presence(meta), topic: String) -> Int {
  list.length(rows(presence.name, topic))
}

fn entries(presence: Presence(meta), rows: Rows) -> List(Entry(meta)) {
  list.filter_map(rows, fn(row) {
    let #(key, metas) = row
    let metas =
      list.filter_map(metas, fn(meta) { json.parse(meta.1, presence.decoder) })
    case metas {
      [] -> Error(Nil)
      _ -> Ok(Entry(key:, metas:))
    }
  })
}

// -- Following changes -------------------------------------------------------

@external(erlang, "howdy_presence", "subscribe")
fn subscribe_rows(name: String, topic: String) -> Rows

@external(erlang, "howdy_presence_ffi", "diff_parts")
fn diff_parts(message: Dynamic) -> #(Rows, Rows)

@external(erlang, "howdy_presence", "deliver")
fn deliver(pid: Pid, frame: websocket.Frame) -> Nil

type Forwarded {
  Changed(joins: Rows, leaves: Rows)
  OwnerDown
}

/// Send a message made by `map` to `subject` after every change to
/// `topic`, until the calling process exits. Returns the topic's entries at
/// the moment of subscribing, so no change falls between them and the first
/// diff.
///
/// The diffs come from a process linked to the caller, so a crash in `map`
/// takes the caller down with it.
pub fn subscribe(
  presence: Presence(meta),
  topic: String,
  subject: Subject(msg),
  map: fn(Diff(meta)) -> msg,
) -> List(Entry(meta)) {
  forward(presence, topic, process.self(), fn(_) { Nil }, fn(joins, leaves) {
    process.send(
      subject,
      map(Diff(
        topic:,
        joins: entries(presence, joins),
        leaves: entries(presence, leaves),
      )),
    )
  })
  |> entries(presence, _)
}

/// Keep `socket`'s client up to date with `topic`: it is sent every
/// presence at once, then a diff after every change, as JSON text frames
/// that the client script reads. Watching does not track the socket. Call
/// it from a socket callback.
pub fn watch(
  presence: Presence(meta),
  socket: Socket(msg),
  topic: String,
) -> Nil {
  watch_pid(presence, websocket.pid(socket), topic)
}

/// `watch` for any process that handles channel frames, such as a test.
@internal
pub fn watch_pid(presence: Presence(meta), pid: Pid, topic: String) -> Nil {
  let send = fn(kind, fields) {
    deliver(pid, websocket.Text(frame(presence, topic, kind, fields)))
  }
  let _ =
    forward(
      presence,
      topic,
      pid,
      fn(current) { send("state", [#("entries", rows_json(current))]) },
      fn(joins, leaves) {
        send("diff", [
          #("joins", rows_json(joins)),
          #("leaves", rows_json(leaves)),
        ])
      },
    )
  Nil
}

/// Start a process, linked to the caller, that subscribes to `topic`,
/// passes the topic's rows to `first`, then hands each diff to `on_diff`
/// until `owner` exits. Returns the rows `first` was given.
fn forward(
  presence: Presence(meta),
  topic: String,
  owner: Pid,
  first: fn(Rows) -> Nil,
  on_diff: fn(Rows, Rows) -> Nil,
) -> Rows {
  let reply = process.new_subject()
  process.spawn(fn() {
    let monitor = process.monitor(owner)
    let current = subscribe_rows(presence.name, topic)
    first(current)
    process.send(reply, current)
    process.new_selector()
    |> process.select_record(atom.create("howdy_presence_diff"), 4, fn(message) {
      let #(joins, leaves) = diff_parts(message)
      Changed(joins:, leaves:)
    })
    |> process.select_specific_monitor(monitor, fn(_) { OwnerDown })
    |> forward_loop(on_diff)
  })
  let assert Ok(current) = process.receive(reply, 5000)
    as "howdy/websocket/presence: the tracker did not answer"
  current
}

fn forward_loop(
  selector: process.Selector(Forwarded),
  on_diff: fn(Rows, Rows) -> Nil,
) -> Nil {
  case process.selector_receive_forever(selector) {
    Changed(joins:, leaves:) -> {
      on_diff(joins, leaves)
      forward_loop(selector, on_diff)
    }
    OwnerDown -> Nil
  }
}

fn frame(
  presence: Presence(meta),
  topic: String,
  kind: String,
  fields: List(#(String, String)),
) -> String {
  let fields = [
    #("presence", quoted(kind)),
    #("name", quoted(presence.name)),
    #("topic", quoted(topic)),
    ..fields
  ]
  "{"
  <> list.map(fields, fn(field) { quoted(field.0) <> ":" <> field.1 })
  |> string.join(",")
  <> "}"
}

// Metas are kept as JSON text, so they are spliced in rather than parsed and
// encoded again.
fn rows_json(rows: Rows) -> String {
  let entry = fn(row: #(String, List(#(String, String)))) {
    let metas =
      list.map(row.1, fn(meta) {
        "{\"ref\":" <> quoted(meta.0) <> ",\"meta\":" <> meta.1 <> "}"
      })
    "{\"key\":"
    <> quoted(row.0)
    <> ",\"metas\":["
    <> string.join(metas, ",")
    <> "]}"
  }
  "[" <> string.join(list.map(rows, entry), ",") <> "]"
}

fn quoted(text: String) -> String {
  json.to_string(json.string(text))
}

// -- The client script -------------------------------------------------------

@external(erlang, "howdy_presence_ffi", "client_source")
fn client_source() -> #(String, String)

/// A controller serving the browser half, a JavaScript module exporting
/// `Presence`, at `path`, such as `"/howdy/presence.js"`. Responses carry
/// an ETag, so browsers revalidate rather than download it again.
pub fn client(at path: String) -> Controller {
  controller.new(path)
  |> controller.get("/", fn(ctx) {
    let #(source, etag) = client_source()
    let headers = [
      #("content-type", "text/javascript; charset=utf-8"),
      #("cache-control", "no-cache"),
      #("etag", etag),
    ]
    let #(status, body) = case
      request.get_header(ctx.request, "if-none-match")
    {
      Ok(tag) if tag == etag -> #(304, content.Empty)
      _ -> #(200, content.Text(source))
    }
    list.fold(headers, response.new(status), fn(res, header) {
      response.set_header(res, header.0, header.1)
    })
    |> response.set_body(body)
  })
}

/// The client script's source.
pub fn client_script() -> String {
  client_source().0
}
