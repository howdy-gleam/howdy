//// What a response carries. Handlers return `Response(Content)`, usually
//// built with `controller.text`, `controller.json` and friends.
////
//// ```gleam
//// response.new(200)
//// |> response.set_header("content-type", "text/csv")
//// |> response.set_body(content.Text(csv))
//// ```

import ewe
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic.{type Dynamic}

/// The body of a response.
pub type Content {
  /// Text, sent as UTF-8.
  Text(String)
  /// Raw bytes.
  Bytes(BytesTree)
  /// No body at all.
  Empty
  /// A body only the server can send, such as a file from
  /// `howdy/static`, a socket upgrade from `howdy/websocket`, a stream from
  /// `howdy/sse` or a body written in chunks by `howdy/stream`. It cannot be
  /// built or read directly; middleware should pass it through unchanged.
  Native(Native)
}

/// See `Native` on `Content`.
pub opaque type Native {
  Wrapped(body: ewe.Body)
  /// A chunked body, with a way to write it out in full without a socket
  /// so that `howdy/testing` can read it.
  Chunked(body: ewe.Body, collect: fn() -> BitArray)
  /// An event stream, with a way to run it without a socket so that
  /// `howdy/testing` can read its events. `open` is a
  /// `howdy/sse.Rehearsal`; see `sse.rehearse`.
  Events(body: ewe.Body, open: Dynamic)
}

/// Why something could not be sent on an open connection: a WebSocket
/// frame, a server-sent event, or a chunk of a streamed body.
pub type SendError {
  /// The client is gone, so nothing further can be written.
  ConnectionClosed
  /// The client cancelled the HTTP/2 stream the response runs on.
  StreamReset
  /// The client stopped reading for long enough that the write gave up.
  SendTimedOut
  /// The socket refused the write for another reason, described by `reason`.
  SocketError(reason: String)
}

/// A send error from ewe, as a `SendError`.
@internal
pub fn send_error(error: ewe.SendError) -> SendError {
  case error {
    ewe.ConnectionClosed -> ConnectionClosed
    ewe.StreamReset -> StreamReset
    ewe.SendTimedOut -> SendTimedOut
    ewe.SocketError(reason:) ->
      SocketError(reason: ewe.socket_reason_to_string(reason))
  }
}

/// Wrap a body ewe built, such as a file or socket upgrade.
@internal
pub fn native(body: ewe.Body) -> Content {
  Native(Wrapped(body:))
}

/// A chunked body that `howdy/testing` can still read in full.
@internal
pub fn chunked(body: ewe.Body, collect: fn() -> BitArray) -> Content {
  Native(Chunked(body:, collect:))
}

/// An event stream that `howdy/testing` can still run.
@internal
pub fn events(body: ewe.Body, open: Dynamic) -> Content {
  Native(Events(body:, open:))
}

/// The whole of a chunked body, written out without a socket.
@internal
pub fn collect(content: Content) -> Result(BitArray, Nil) {
  case content {
    Native(Chunked(collect:, ..)) -> Ok(collect())
    _ -> Error(Nil)
  }
}

/// How to run an event stream without a socket.
@internal
pub fn rehearsal(content: Content) -> Result(Dynamic, Nil) {
  case content {
    Native(Events(open:, ..)) -> Ok(open)
    _ -> Error(Nil)
  }
}

/// The ewe body to send for `content`.
@internal
pub fn to_ewe(content: Content) -> ewe.Body {
  case content {
    Text(text) -> ewe.Text(text)
    Bytes(bytes) -> ewe.Bytes(bytes)
    Empty -> ewe.Empty
    Native(Wrapped(body:)) -> body
    Native(Chunked(body:, ..)) -> body
    Native(Events(body:, ..)) -> body
  }
}
