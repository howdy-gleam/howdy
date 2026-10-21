//// Server-sent events: a response that stays open so the server can push
//// messages to a browser as things happen.
////
//// An event stream is an ordinary `GET` route, so it goes through the same
//// middleware, guards and versioning as any other. The handler describes
//// the stream and finishes with `start`.
////
//// ```gleam
//// import howdy/sse
////
//// controller.new("orders")
//// |> controller.get("/events", fn(ctx) {
////   sse.new(fn(stream) {
////     sse.join(stream, "orders")
////     Nil
////   })
////   |> sse.start(ctx)
//// })
//// ```
////
//// and from anywhere else in the program:
////
//// ```gleam
//// sse.broadcast("orders", sse.json(order_json) |> sse.name("order.created"))
//// ```
////
//// In a browser, `new EventSource("/orders/events")` connects to it and
//// reconnects by itself if the connection drops, sending back the `id` of
//// the last event it saw; see `last_event_id`.
////
//// Server-sent events only go one way. When the client needs to talk back,
//// it sends ordinary requests, or the app uses `howdy/websocket` instead.
////
//// Each stream runs in its own process, like a WebSocket. Callbacks are
//// given the `Stream` to send on and the current state, and return what to
//// do next: `continue` with new state, or `stop`. Other processes reach a
//// stream through `subject`, and groups of streams through topics with
//// `join` and `broadcast`.

import ewe
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid, type Selector, type Subject}
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import howdy/content.{type Content, type SendError}
import howdy/controller.{type GuardedContext}
import howdy/trace

// -- Events ------------------------------------------------------------------

/// A message on the stream. Build one with `event` or `json`, then set the
/// other fields with `name`, `id` and `retry`.
pub type Event {
  Event(
    /// What the client receives as the event's `data`. Text spanning
    /// several lines arrives as it was sent.
    data: String,
    /// The event's type. Browsers deliver named events to listeners added
    /// with `addEventListener(name, ...)`, and unnamed ones to `onmessage`.
    name: Option(String),
    /// Sent back by a reconnecting client in the `last-event-id` header.
    id: Option(String),
    /// How long, in milliseconds, the client waits before reconnecting.
    retry: Option(Int),
  )
}

/// An unnamed event carrying `data`.
pub fn event(data: String) -> Event {
  Event(data:, name: None, id: None, retry: None)
}

/// An unnamed event carrying `body` as JSON.
pub fn json(body: Json) -> Event {
  event(json.to_string(body))
}

/// Give an event a type, for the client's `addEventListener`.
pub fn name(event: Event, name: String) -> Event {
  Event(..event, name: Some(name))
}

/// Give an event an ID. A client that reconnects sends the last ID it saw,
/// so the stream can pick up where it left off.
pub fn id(event: Event, id: String) -> Event {
  Event(..event, id: Some(id))
}

/// Tell the client how long to wait, in milliseconds, before reconnecting
/// if the connection drops.
pub fn retry(event: Event, milliseconds: Int) -> Event {
  Event(..event, retry: Some(milliseconds))
}

fn to_ewe(event: Event) -> ewe.SseEvent {
  let built = ewe.event(event.data)
  let built = case event.name {
    Some(name) -> ewe.event_name(built, name)
    None -> built
  }
  let built = case event.id {
    Some(id) -> ewe.event_id(built, id)
    None -> built
  }
  case event.retry {
    Some(retry) -> ewe.event_retry(built, retry)
    None -> built
  }
}

// -- Streams -----------------------------------------------------------------

/// A handle for one open stream. `msg` is the type of message other
/// processes may send it; see `subject`.
pub opaque type Stream(msg) {
  Stream(
    send: fn(Event) -> Result(Nil, SendError),
    comment: fn(String) -> Result(Nil, SendError),
    inbox: Subject(msg),
    last_event_id: Option(String),
  )
}

/// What a callback asks the stream to do once it is done.
pub opaque type Next(state) {
  Continue(state)
  Stop
}

/// Keep the stream open and handle the next message with `state`.
pub fn continue(state: state) -> Next(state) {
  Continue(state)
}

/// End the stream. `on_close` still runs. A browser's `EventSource`
/// reconnects after a stream ends; to stop it for good, close it from the
/// client, or answer the reconnect with a status other than `200`, such as
/// `204`.
pub fn stop() -> Next(state) {
  Stop
}

/// Send an event to this stream's client.
pub fn send(stream: Stream(msg), event: Event) -> Result(Nil, SendError) {
  stream.send(event)
}

/// Send a comment, which clients ignore. The heartbeat is one of these.
pub fn send_comment(
  stream: Stream(msg),
  text: String,
) -> Result(Nil, SendError) {
  stream.comment(text)
}

/// The ID of the last event the client saw before it reconnected, from the
/// `last-event-id` header. `None` on a first connection.
pub fn last_event_id(stream: Stream(msg)) -> Option(String) {
  stream.last_event_id
}

/// A subject other processes can send to. Each message arrives at the
/// `on_message` callback. Hand it to whatever needs to push to this client.
pub fn subject(stream: Stream(msg)) -> Subject(msg) {
  stream.inbox
}

fn pid(stream: Stream(msg)) -> Pid {
  let assert Ok(pid) = process.subject_owner(stream.inbox)
    as "howdy/sse: stream subject has no owner"
  pid
}

// -- Building ----------------------------------------------------------------

/// A stream description under construction. `state` is what the callbacks
/// carry between messages; `msg` is what `subject` accepts.
pub opaque type Builder(state, msg) {
  Builder(
    on_open: fn(Stream(msg)) -> state,
    on_message: fn(Stream(msg), state, msg) -> Next(state),
    on_close: fn(Stream(msg), state) -> Nil,
    heartbeat: Option(Int),
  )
}

/// Describe a stream. `on_open` runs once the response headers have been
/// sent and returns the starting state. It may send events straight away,
/// such as the ones a reconnecting client missed.
///
/// A comment is sent every 15 seconds so that proxies do not close an idle
/// stream; see `heartbeat`.
pub fn new(on_open: fn(Stream(msg)) -> state) -> Builder(state, msg) {
  Builder(
    on_open:,
    on_message: fn(_, state, _) { Continue(state) },
    on_close: fn(_, _) { Nil },
    heartbeat: Some(15_000),
  )
}

/// Handle messages sent to the stream's `subject` by other processes.
pub fn on_message(
  builder: Builder(state, msg),
  handler: fn(Stream(msg), state, msg) -> Next(state),
) -> Builder(state, msg) {
  Builder(..builder, on_message: handler)
}

/// Run once when the stream ends, however that happens. Nothing can be
/// sent to the client from here.
pub fn on_close(
  builder: Builder(state, msg),
  handler: fn(Stream(msg), state) -> Nil,
) -> Builder(state, msg) {
  Builder(..builder, on_close: handler)
}

/// Send a comment every `milliseconds` to keep an idle stream open. A
/// heartbeat that cannot be sent ends the stream, which is also how a
/// client that went away without a word is noticed.
pub fn heartbeat(
  builder: Builder(state, msg),
  milliseconds: Int,
) -> Builder(state, msg) {
  Builder(..builder, heartbeat: Some(milliseconds))
}

/// Send no heartbeat.
pub fn no_heartbeat(builder: Builder(state, msg)) -> Builder(state, msg) {
  Builder(..builder, heartbeat: None)
}

// -- Starting ----------------------------------------------------------------

/// Everything the stream process can receive.
type Inbound(msg) {
  /// A message from `subject`.
  User(msg)
  /// An event from `broadcast`, sent straight to the client.
  Deliver(Event)
  /// Time to send a heartbeat.
  Beat
  /// A test is done with the stream.
  Halt
}

/// A stream between messages.
type Running(state, msg) {
  Running(stream: Stream(msg), control: Subject(Inbound(msg)), state: state)
}

/// Respond with the stream. The response is `200` with the
/// `text/event-stream` content type, and the stream then runs until a
/// callback returns `stop`, the client goes away or the server shuts down.
pub fn start(
  builder: Builder(state, msg),
  ctx: GuardedContext(guarded),
) -> Response(Content) {
  let last_event_id =
    request.get_header(ctx.request, "last-event-id") |> option.from_result
  // `on_open` runs after the request's span has ended, so it gets a span
  // of its own that links back to the request.
  let opened_by =
    trace.traceparent()
    |> option.to_result(Nil)
    |> result.try(trace.link_to)
  let path = ctx.request.path
  let open = fn(stream) {
    let span =
      trace.new("sse open")
      |> trace.kind(trace.Server)
      |> trace.attributes([trace.string("url.path", path)])
    case opened_by {
      Ok(link) -> trace.link(span, link)
      Error(Nil) -> span
    }
    |> trace.run(fn() { builder.on_open(stream) })
  }

  let live =
    response.new(200)
    // Ask nginx and similar proxies to pass events on as they come.
    |> response.set_header("x-accel-buffering", "no")
    |> ewe.sse(
      on_init: fn(conn, selector) {
        let stream =
          Stream(
            send: fn(event) {
              ewe.send_event(conn, to_ewe(event))
              |> result.map_error(content.send_error)
            },
            comment: fn(text) {
              ewe.send_event(conn, ewe.comment(text))
              |> result.map_error(content.send_error)
            },
            inbox: process.new_subject(),
            last_event_id:,
          )
        let control = process.new_subject()
        schedule_beat(builder, control)
        let running = Running(stream:, control:, state: open(stream))
        #(running, inbound(selector, stream.inbox, control))
      },
      handler: fn(_conn, running, message) {
        case step(builder, running, message) {
          Continue(running) -> ewe.continue(running)
          Stop -> ewe.stop()
        }
      },
      on_close: fn(_conn, running) {
        builder.on_close(running.stream, running.state)
      },
    )
  response.map(live, content.events(
    _,
    to_dynamic(rehearse(builder, open, last_event_id)),
  ))
}

fn step(
  builder: Builder(state, msg),
  running: Running(state, msg),
  message: Inbound(msg),
) -> Next(Running(state, msg)) {
  case message {
    User(message) ->
      case builder.on_message(running.stream, running.state, message) {
        Continue(state) -> Continue(Running(..running, state:))
        Stop -> Stop
      }
    Deliver(event) ->
      case running.stream.send(event) {
        Ok(Nil) -> Continue(running)
        Error(_) -> Stop
      }
    Beat ->
      case running.stream.comment("") {
        Ok(Nil) -> {
          schedule_beat(builder, running.control)
          Continue(running)
        }
        Error(_) -> Stop
      }
    Halt -> Stop
  }
}

fn schedule_beat(
  builder: Builder(state, msg),
  control: Subject(Inbound(msg)),
) -> Nil {
  case builder.heartbeat {
    Some(milliseconds) -> {
      process.send_after(control, milliseconds, Beat)
      Nil
    }
    None -> Nil
  }
}

fn inbound(
  selector: Selector(Inbound(msg)),
  inbox: Subject(msg),
  control: Subject(Inbound(msg)),
) -> Selector(Inbound(msg)) {
  selector
  |> process.select_map(inbox, User)
  |> process.select(control)
  |> process.select_record(atom.create(tag), 1, fn(message) {
    Deliver(tuple_second(message))
  })
}

// -- Running without a socket ------------------------------------------------

/// How `howdy/testing` runs a stream with no socket: given where to put
/// the events it sends, it opens the stream in a new process and returns a
/// function that ends it, once `on_close` has run.
@internal
pub type Rehearsal =
  fn(fn(Event) -> Nil) -> fn() -> Nil

/// The rehearsal for a stream response, or `Error(Nil)` if `content` is not
/// one.
@internal
pub fn rehearsal(content: Content) -> Result(Rehearsal, Nil) {
  content.rehearsal(content) |> result.map(from_dynamic)
}

fn rehearse(
  builder: Builder(state, msg),
  open: fn(Stream(msg)) -> state,
  last_event_id: Option(String),
) -> Rehearsal {
  fn(sink) {
    let ready = process.new_subject()
    let pid =
      process.spawn(fn() {
        let stream =
          Stream(
            send: fn(event) {
              sink(event)
              Ok(Nil)
            },
            comment: fn(_) { Ok(Nil) },
            inbox: process.new_subject(),
            last_event_id:,
          )
        let control = process.new_subject()
        let running = Running(stream:, control:, state: open(stream))
        // Only now is the stream on its topics, so a test can broadcast.
        process.send(ready, control)
        let selector = inbound(process.new_selector(), stream.inbox, control)
        rehearsal_loop(builder, running, selector)
      })
    let assert Ok(control) = process.receive(ready, 5000)
      as "howdy/sse: the stream did not open within 5 seconds"
    fn() {
      let monitor = process.monitor(pid)
      process.send(control, Halt)
      let assert Ok(_) =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(down) { down })
        |> process.selector_receive(5000)
        as "howdy/sse: the stream did not close within 5 seconds"
      Nil
    }
  }
}

fn rehearsal_loop(
  builder: Builder(state, msg),
  running: Running(state, msg),
  selector: Selector(Inbound(msg)),
) -> Nil {
  case step(builder, running, process.selector_receive_forever(selector)) {
    Continue(running) -> rehearsal_loop(builder, running, selector)
    Stop -> builder.on_close(running.stream, running.state)
  }
}

// -- Topics ------------------------------------------------------------------

/// The tag `broadcast` puts on the events it sends to stream processes.
const tag = "howdy_sse"

@external(erlang, "howdy_channel_ffi", "channel_join")
fn join_pid(topic: #(Atom, String), pid: Pid) -> Nil

@external(erlang, "howdy_channel_ffi", "channel_leave")
fn leave_pid(topic: #(Atom, String), pid: Pid) -> Nil

@external(erlang, "howdy_channel_ffi", "channel_members")
fn members(topic: #(Atom, String)) -> List(Pid)

@external(erlang, "howdy_channel_ffi", "channel_broadcast")
fn send_all(topic: #(Atom, String), tag: Atom, event: Event) -> Nil

@external(erlang, "howdy_channel_ffi", "tuple_second")
fn tuple_second(message: a) -> Event

@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(value: a) -> Dynamic

@external(erlang, "gleam_stdlib", "identity")
fn from_dynamic(value: Dynamic) -> a

/// Event stream topics are kept apart from WebSocket channel topics of the
/// same name, since the two carry different messages.
fn group(topic: String) -> #(Atom, String) {
  #(atom.create(tag), topic)
}

/// Subscribe a stream to a topic. Joining a topic twice has no extra
/// effect. Membership ends when the stream does.
pub fn join(stream: Stream(msg), topic: String) -> Nil {
  join_pid(group(topic), pid(stream))
}

/// Unsubscribe a stream from a topic. Leaving a topic the stream is not on
/// does nothing.
pub fn leave(stream: Stream(msg), topic: String) -> Nil {
  leave_pid(group(topic), pid(stream))
}

/// Send an event to every stream on a topic, on every connected node. Each
/// stream sends it from its own process, so this returns at once and never
/// waits on a slow client.
pub fn broadcast(topic: String, event: Event) -> Nil {
  send_all(group(topic), atom.create(tag), event)
}

/// How many streams are on a topic.
pub fn size(topic: String) -> Int {
  members(group(topic)) |> list.unique |> list.length
}
