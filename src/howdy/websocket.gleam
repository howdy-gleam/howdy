//// WebSockets as ordinary routes.
////
//// A WebSocket starts life as a `GET` request, so it is added to a
//// controller like any other route and goes through the same middleware,
//// guard and versioning. The handler builds a socket description and
//// finishes with `upgrade`.
////
//// ```gleam
//// import howdy/websocket
////
//// controller.new("echo")
//// |> controller.get("/", fn(ctx) {
////   websocket.new(fn(_socket) { 0 })
////   |> websocket.on_text(fn(socket, count, text) {
////     let _ = websocket.send_text(socket, text)
////     websocket.continue(count + 1)
////   })
////   |> websocket.upgrade(ctx)
//// })
//// ```
////
//// Every callback runs in the connection's own process and receives the
//// `Socket` to send frames on, the current state, and returns what to do
//// next: `continue` with new state, or `close`.
////
//// Other processes can reach a socket through `subject`, and groups of
//// sockets through `howdy/websocket/channel`.
////
//// Browsers cannot set headers on a WebSocket handshake, so guards for
//// socket routes usually read a cookie or a query parameter instead.

import ewe
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/atom
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/json.{type Json}
import gleam/option.{None, Some}
import gleam/result
import howdy/content.{type Content, type SendError}
import howdy/context
import howdy/controller.{type GuardedContext}
import howdy/service
import howdy/trace
import howdy/websocket/origin

/// A handle for one open connection. `msg` is the type of message other
/// processes may send it; see `subject`.
pub opaque type Socket(msg) {
  Socket(conn: ewe.WebsocketConnection, inbox: Subject(msg))
}

/// A frame to send to a client, as used by `howdy/websocket/channel`.
pub type Frame {
  Text(String)
  Binary(BitArray)
}

/// What a callback asks the socket to do once it is done.
pub opaque type Next(state) {
  Continue(state)
  Stop
}

/// Keep the connection open and handle the next message with `state`.
pub fn continue(state: state) -> Next(state) {
  Continue(state)
}

/// Send a close frame with the given code and reason, then end the
/// connection. `on_close` still runs. Nothing can be sent afterwards.
pub fn close(
  socket: Socket(msg),
  code: CloseCode,
  reason: String,
) -> Next(state) {
  let _ =
    ewe.send_close_frame(
      socket.conn,
      ewe.CloseReason(to_ewe_close_code(code), reason),
    )
  Stop
}

/// End the connection without telling the client why.
pub fn stop() -> Next(state) {
  Stop
}

/// The status code a close frame carries. `NormalClosure` is the usual
/// choice.
pub type CloseCode {
  /// The connection did what it was for and is closing normally (1000).
  NormalClosure
  /// The server is going away, such as shutting down (1001).
  GoingAway
  /// The client broke the protocol (1002).
  ProtocolError
  /// Data arrived that the server cannot accept (1003).
  UnsupportedData
  /// A message did not match the type it declared, such as a text frame
  /// that is not UTF-8 (1007).
  InvalidPayloadData
  /// The client broke your rules when no more specific code applies (1008).
  PolicyViolation
  /// A message was larger than the server will handle (1009).
  MessageTooBig
  /// Something went wrong on the server (1011).
  InternalError
  /// The server is restarting and clients may reconnect shortly (1012).
  ServiceRestart
  /// The server is overloaded and the client should retry later (1013).
  TryAgainLater
  /// An upstream server answered badly (1014).
  BadGateway
  /// An application specific code, between 3000 and 4999.
  ApplicationCode(code: Int)
}

fn to_ewe_close_code(code: CloseCode) -> ewe.CloseCode {
  case code {
    NormalClosure -> ewe.NormalClosure
    GoingAway -> ewe.GoingAway
    ProtocolError -> ewe.ProtocolError
    UnsupportedData -> ewe.UnsupportedData
    InvalidPayloadData -> ewe.InvalidPayloadData
    PolicyViolation -> ewe.PolicyViolation
    MessageTooBig -> ewe.MessageTooBig
    InternalError -> ewe.InternalError
    ServiceRestart -> ewe.ServiceRestart
    TryAgainLater -> ewe.TryAgainLater
    BadGateway -> ewe.BadGateway
    ApplicationCode(code:) -> ewe.ApplicationCode(code:)
  }
}

// -- Building ----------------------------------------------------------------

/// A socket description under construction. `state` is what the callbacks
/// carry between messages; `msg` is what `subject` accepts.
pub opaque type Builder(state, msg) {
  Builder(
    on_open: fn(Socket(msg)) -> state,
    on_text: fn(Socket(msg), state, String) -> Next(state),
    on_binary: fn(Socket(msg), state, BitArray) -> Next(state),
    on_message: fn(Socket(msg), state, msg) -> Next(state),
    on_close: fn(Socket(msg), state) -> Nil,
    origins: origin.Policy,
    origin_required: Bool,
    traced: Bool,
  )
}

/// Describe a socket. `on_open` runs once the handshake is done and returns
/// the starting state. Frames and messages are ignored until a callback for
/// them is added.
pub fn new(on_open: fn(Socket(msg)) -> state) -> Builder(state, msg) {
  Builder(
    on_open:,
    on_text: fn(_, state, _) { Continue(state) },
    on_binary: fn(_, state, _) { Continue(state) },
    on_message: fn(_, state, _) { Continue(state) },
    on_close: fn(_, _) { Nil },
    origins: origin.SameOrigin,
    origin_required: False,
    traced: True,
  )
}

/// Do not open a span per frame. `howdy/ui/live` uses this: its frames are
/// handed straight to a Lustre runtime, whose work happens in another
/// process, so the spans would record nothing but noise.
@internal
pub fn untraced(builder: Builder(state, msg)) -> Builder(state, msg) {
  Builder(..builder, traced: False)
}

/// Replace the default same-origin policy with an exact HTTP(S) allowlist,
/// for pages served from somewhere else, such as a separate frontend. A
/// proxy that ends TLS needs none: the default follows it (see `upgrade`).
/// Invalid entries panic as configuration errors.
pub fn allow_origins(
  builder: Builder(state, msg),
  origins: List(String),
) -> Builder(state, msg) {
  Builder(..builder, origins: origin.allowlist(origins))
}

/// Require Origin even for non-browser clients. By default, absent Origin is
/// accepted for CLI clients; supplied, malformed or duplicate origins are
/// always checked. Origin policy is not a substitute for authentication.
pub fn require_origin(builder: Builder(state, msg)) -> Builder(state, msg) {
  Builder(..builder, origin_required: True)
}

/// Handle text frames from the client.
pub fn on_text(
  builder: Builder(state, msg),
  handler: fn(Socket(msg), state, String) -> Next(state),
) -> Builder(state, msg) {
  Builder(..builder, on_text: handler)
}

/// Handle binary frames from the client.
pub fn on_binary(
  builder: Builder(state, msg),
  handler: fn(Socket(msg), state, BitArray) -> Next(state),
) -> Builder(state, msg) {
  Builder(..builder, on_binary: handler)
}

/// Handle text frames by decoding them as JSON. Frames that fail to decode
/// go to `on_invalid`, which by default ignores them. Replaces any `on_text`
/// handler.
pub fn on_json(
  builder: Builder(state, msg),
  decoder: Decoder(a),
  handler: fn(Socket(msg), state, a) -> Next(state),
) -> Builder(state, msg) {
  on_json_or(builder, decoder, handler, fn(_, state, _) { Continue(state) })
}

/// Like `on_json`, but with a handler for frames that fail to decode. A
/// common choice is to close with `InvalidPayloadData`:
///
/// ```gleam
/// |> websocket.on_json_or(decoder, handle, fn(socket, _state, _error) {
///   websocket.close(socket, websocket.InvalidPayloadData, "expected json")
/// })
/// ```
pub fn on_json_or(
  builder: Builder(state, msg),
  decoder: Decoder(a),
  handler: fn(Socket(msg), state, a) -> Next(state),
  on_invalid: fn(Socket(msg), state, json.DecodeError) -> Next(state),
) -> Builder(state, msg) {
  on_text(builder, fn(socket, state, text) {
    case json.parse(text, decoder) {
      Ok(value) -> handler(socket, state, value)
      Error(error) -> on_invalid(socket, state, error)
    }
  })
}

/// Handle messages sent to the socket's `subject` by other processes.
pub fn on_message(
  builder: Builder(state, msg),
  handler: fn(Socket(msg), state, msg) -> Next(state),
) -> Builder(state, msg) {
  Builder(..builder, on_message: handler)
}

/// Run once when the connection ends, however that happens. Nothing can be
/// sent to the client from here.
pub fn on_close(
  builder: Builder(state, msg),
  handler: fn(Socket(msg), state) -> Nil,
) -> Builder(state, msg) {
  Builder(..builder, on_close: handler)
}

// -- Upgrading ---------------------------------------------------------------

/// Everything the connection process can receive.
type Inbound(msg) {
  /// A frame from `howdy/websocket/channel`, sent straight to the client.
  Deliver(Frame)
  /// A message from `subject`.
  User(msg)
}

/// The tag `channel` puts on the messages it sends to socket processes.
@internal
pub const channel_tag = "howdy_websocket"

@external(erlang, "howdy_channel_ffi", "tuple_second")
fn tuple_second(message: Dynamic) -> Frame

/// Upgrade the request. The connection then runs until a callback returns
/// `close` or `stop`, or the client goes away.
///
/// A request that is not a valid handshake is answered with `400`. In tests
/// there is no connection to upgrade, so the answer is `426 Upgrade
/// Required`.
/// Disallowed origins receive `403` before the handshake or `on_open`. By
/// default the browser's origin must be the one it reached the app at:
/// the request's scheme, host and port, or, behind a proxy, the scheme in
/// `x-forwarded-proto` and the host in `x-forwarded-host`. A hostile page
/// cannot set those on a browser's handshake, so trusting them for this
/// check gives nothing away.
pub fn upgrade(
  builder: Builder(state, msg),
  ctx: GuardedContext(guarded),
) -> Response(Content) {
  case origin.allowed(ctx.request, builder.origins, builder.origin_required) {
    False -> service.error_response(ctx, service.Forbidden)
    True -> upgrade_allowed(builder, ctx)
  }
}

fn upgrade_allowed(
  builder: Builder(state, msg),
  ctx: GuardedContext(guarded),
) -> Response(Content) {
  case context.connection(ctx.request.body) {
    None ->
      response.new(426)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(content.Text("upgrade required"))
    Some(connection) -> {
      // Each frame is traced on its own, as a trace of its own that links
      // back to the request that opened the socket.
      let opened_by =
        trace.traceparent()
        |> option.to_result(Nil)
        |> result.try(trace.link_to)
      let path = ctx.request.path
      let traced = fn(kind: String, run: fn() -> Next(state)) -> Next(state) {
        case builder.traced {
          False -> run()
          True -> {
            let span =
              trace.new("websocket " <> kind)
              |> trace.kind(trace.Server)
              |> trace.attributes([trace.string("url.path", path)])
            case opened_by {
              Ok(link) -> trace.link(span, link)
              Error(Nil) -> span
            }
            |> trace.run(run)
          }
        }
      }
      ewe.websocket(
        request: request.set_body(ctx.request, connection),
        on_init: fn(conn, selector) {
          let inbox = process.new_subject()
          let socket = Socket(conn:, inbox:)
          let state = builder.on_open(socket)
          #(#(socket, state), inbound(selector, inbox))
        },
        handler: fn(_conn, pair, message) {
          let #(socket, state) = pair
          let next = case message {
            ewe.TextFrame(text) ->
              traced("text", fn() { builder.on_text(socket, state, text) })
            ewe.BinaryFrame(data) ->
              traced("binary", fn() { builder.on_binary(socket, state, data) })
            ewe.UserMessage(User(message)) ->
              builder.on_message(socket, state, message)
            ewe.UserMessage(Deliver(frame)) ->
              case send_frame(socket, frame) {
                Ok(Nil) -> Continue(state)
                Error(_) -> Stop
              }
          }
          case next {
            Continue(state) -> ewe.continue(#(socket, state))
            Stop -> ewe.stop()
          }
        },
        on_close: fn(_conn, pair) { builder.on_close(pair.0, pair.1) },
      )
      |> response.map(content.native)
    }
  }
}

fn inbound(
  selector: Selector(Inbound(msg)),
  inbox: Subject(msg),
) -> Selector(Inbound(msg)) {
  selector
  |> process.select_map(inbox, User)
  |> process.select_record(atom.create(channel_tag), 1, fn(message) {
    Deliver(tuple_second(message))
  })
}

// -- Sending -----------------------------------------------------------------

/// Send a text frame.
pub fn send_text(socket: Socket(msg), text: String) -> Result(Nil, SendError) {
  ewe.send_text_frame(socket.conn, text)
  |> result.map_error(content.send_error)
}

/// Send a binary frame.
pub fn send_binary(
  socket: Socket(msg),
  data: BitArray,
) -> Result(Nil, SendError) {
  ewe.send_binary_frame(socket.conn, data)
  |> result.map_error(content.send_error)
}

/// Send JSON as a text frame.
pub fn send_json(socket: Socket(msg), body: Json) -> Result(Nil, SendError) {
  send_text(socket, json.to_string(body))
}

/// Send a `Frame`.
pub fn send_frame(socket: Socket(msg), frame: Frame) -> Result(Nil, SendError) {
  case frame {
    Text(text) -> send_text(socket, text)
    Binary(data) -> send_binary(socket, data)
  }
}

// -- Reaching a socket from elsewhere ---------------------------------------

/// A subject other processes can send to. Each message arrives at the
/// `on_message` callback. Hand it to whatever needs to push to this client.
pub fn subject(socket: Socket(msg)) -> Subject(msg) {
  socket.inbox
}

/// The process running the connection. Used by `howdy/websocket/channel`.
@internal
pub fn pid(socket: Socket(msg)) -> process.Pid {
  let assert Ok(pid) = process.subject_owner(socket.inbox)
    as "howdy/websocket: socket subject has no owner"
  pid
}
