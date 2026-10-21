//// Response bodies written a piece at a time, so each piece reaches the
//// client as soon as it is ready: a large CSV export, a log being tailed,
//// the tokens of a language model as they arrive.
////
//// ```gleam
//// import howdy/stream
////
//// controller.get("/users.csv", fn(_ctx) {
////   response.new(200)
////   |> response.set_header("content-type", "text/csv")
////   |> stream.body(fn(writer) {
////     use writer <- result.try(stream.send_text(writer, "id,name\n"))
////     list.try_fold(users(), writer, fn(writer, user) {
////       stream.send_text(writer, user.id <> "," <> user.name <> "\n")
////     })
////   })
//// })
//// ```
////
//// The function runs once the headers have gone, in the connection's own
//// process. Each send hands back the writer for the next one. Returning
//// `Ok` ends the body. Returning `Error` stops writing and closes the
//// connection without ending the body, so the client can tell it was cut
//// short; the error is logged unless it came from a send that failed
//// because the client had gone.
////
//// For messages pushed to a browser over time, use `howdy/sse` instead.
//// In tests, `howdy/testing.text` and `testing.bytes` read a streamed body
//// in full.

import ewe
import gleam/bytes_tree
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/http/response.{type Response}
import gleam/string
import howdy/content.{type Content, type SendError}

/// Where the pieces of a streamed body are written. Given to the function
/// passed to `body`.
pub opaque type Writer {
  Live(ewe.ResponseWriter)
  /// In a test there is no socket: pieces are sent to the test's process.
  Collecting(Subject(BitArray))
}

/// Set the body of `response` to one written by `write`, a piece at a
/// time. Any body already set is replaced.
pub fn body(
  response: Response(a),
  write: fn(Writer) -> Result(Writer, e),
) -> Response(Content) {
  let collect = fn() {
    let pieces = process.new_subject()
    let _ = write(Collecting(pieces))
    drain(pieces, bytes_tree.new())
  }
  response
  |> ewe.stream_response(fn(writer) {
    // The connection process may have served an earlier request.
    let _ = put(gone_key, False)
    case write(Live(writer)) {
      Ok(Live(writer)) -> ewe.finish_response(writer)
      Ok(Collecting(_)) -> Ok(Nil)
      Error(error) ->
        case client_gone() {
          // The client is gone, so there is nothing left to cut short.
          True -> Ok(Nil)
          // Returning would have ewe end the body as if it were complete.
          // A crash closes the connection with the body unfinished.
          False ->
            panic as {
              "howdy/stream: body cut short: " <> string.inspect(error)
            }
        }
    }
  })
  |> response.map(content.chunked(_, collect))
}

// Whether a send has failed is kept in the connection process's
// dictionary: the writer that would carry it is dropped with the error.
const gone_key = "howdy_stream_client_gone"

@external(erlang, "erlang", "put")
fn put(key: String, value: Bool) -> Dynamic

@external(erlang, "erlang", "get")
fn get(key: String) -> Dynamic

fn mark_client_gone() -> Nil {
  let _ = put(gone_key, True)
  Nil
}

fn client_gone() -> Bool {
  get(gone_key) == dynamic.bool(True)
}

fn drain(pieces: Subject(BitArray), tree: bytes_tree.BytesTree) -> BitArray {
  case process.receive(pieces, 0) {
    Ok(piece) -> drain(pieces, bytes_tree.append(tree, piece))
    Error(Nil) -> bytes_tree.to_bit_array(tree)
  }
}

/// Send `bits` to the client now.
pub fn send(writer: Writer, bits: BitArray) -> Result(Writer, SendError) {
  case writer {
    Live(writer) ->
      case ewe.send_chunk(writer, bits) {
        Ok(writer) -> Ok(Live(writer))
        Error(error) -> {
          mark_client_gone()
          Error(content.send_error(error))
        }
      }
    Collecting(pieces) -> {
      process.send(pieces, bits)
      Ok(writer)
    }
  }
}

/// Send `text` to the client now, as UTF-8.
pub fn send_text(writer: Writer, text: String) -> Result(Writer, SendError) {
  send(writer, <<text:utf8>>)
}
