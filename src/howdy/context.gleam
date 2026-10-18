//// Request context shared by handlers and guards.

import ewe
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/http/request.{type Request}
import gleam/int
import gleam/option.{type Option, None, Some}

/// The body of an incoming request. Under ewe it wraps the live connection
/// and is read from the socket on demand. In tests it holds the bytes
/// directly, so handlers that read bodies run unchanged. Build test bodies
/// with `howdy/testing`.
pub opaque type Body {
  Live(connection: ewe.Connection)
  Fake(bits: BitArray, ip: Option(String))
}

/// Why a request body could not be read.
pub type BodyError {
  /// The body is larger than the limit given.
  BodyTooLarge
  /// The body was malformed, or the client stopped sending it.
  InvalidBody
}

/// `guard` holds the successful controller guard value, or `Nil` for an
/// ordinary controller. `version` is the API version resolved by
/// `howdy/version`, or `None` for routes outside a version group.
pub type Context(guarded) {
  Context(
    request: Request(Body),
    params: Dict(String, String),
    guard: guarded,
    version: Option(String),
  )
}

/// Wrap the connection of a request ewe handed us.
@internal
pub fn live(connection: ewe.Connection) -> Body {
  Live(connection:)
}

/// A body made of `bits`, appearing to come from `ip` if given.
@internal
pub fn fake(bits: BitArray, ip: Option(String)) -> Body {
  Fake(bits:, ip:)
}

/// Replace the bytes of a fake body. Live bodies are returned unchanged.
@internal
pub fn with_bits(body: Body, bits: BitArray) -> Body {
  case body {
    Fake(ip:, ..) -> Fake(bits:, ip:)
    Live(..) -> body
  }
}

/// Set the client address of a fake body. Live bodies are returned unchanged.
@internal
pub fn with_ip(body: Body, ip: String) -> Body {
  case body {
    Fake(bits:, ..) -> Fake(bits:, ip: Some(ip))
    Live(..) -> body
  }
}

/// The live connection behind a request, or `None` for a fake body.
@internal
pub fn connection(body: Body) -> Option(ewe.Connection) {
  case body {
    Live(connection:) -> Some(connection)
    Fake(..) -> None
  }
}

/// Read the whole request body, up to `limit` bytes.
pub fn read_body(
  request: Request(Body),
  limit limit: Int,
) -> Result(BitArray, BodyError) {
  case request.body {
    Live(connection:) ->
      case ewe.read_body(request.set_body(request, connection), limit:) {
        Ok(request) -> Ok(request.body)
        Error(ewe.BodyTooLarge) -> Error(BodyTooLarge)
        Error(ewe.InvalidBody) -> Error(InvalidBody)
      }
    Fake(bits:, ..) ->
      case bit_array.byte_size(bits) > limit {
        True -> Error(BodyTooLarge)
        False -> Ok(bits)
      }
  }
}

/// A request body being read a piece at a time, so that a large one need not
/// be held in memory.
@internal
pub opaque type Reader {
  LiveReader(request: Request(ewe.Connection), limit: Int)
  FakeReader(bits: BitArray)
  FakeTooLarge
}

/// Start reading the body of `request` in pieces, refusing one larger than
/// `limit` bytes in all.
@internal
pub fn reader(request: Request(Body), limit limit: Int) -> Reader {
  case request.body {
    Live(connection:) ->
      LiveReader(request: request.set_body(request, connection), limit:)
    Fake(bits:, ..) ->
      // Like ewe, refuse the body when a piece is asked for.
      case bit_array.byte_size(bits) > limit {
        True -> FakeTooLarge
        False -> FakeReader(bits)
      }
  }
}

/// The next piece of the body, of at most `max_bytes`, with the reader for
/// the piece after it, or `None` once the body has been read to the end.
@internal
pub fn read_chunk(
  reader: Reader,
  max_bytes max_bytes: Int,
) -> Result(Option(#(BitArray, Reader)), BodyError) {
  case reader {
    FakeTooLarge -> Error(BodyTooLarge)
    FakeReader(<<>>) -> Ok(None)
    FakeReader(bits) -> {
      let size = bit_array.byte_size(bits)
      let take = int.min(int.max(max_bytes, 1), size)
      let assert Ok(chunk) = bit_array.slice(bits, 0, take)
      let assert Ok(rest) = bit_array.slice(bits, take, size - take)
      Ok(Some(#(chunk, FakeReader(rest))))
    }
    LiveReader(request:, limit:) ->
      case ewe.read_body_chunk(request, max_chunk_bytes: max_bytes, limit:) {
        Ok(ewe.Chunk(data:, request:)) ->
          Ok(Some(#(data, LiveReader(request:, limit:))))
        Ok(ewe.Done(_)) -> Ok(None)
        Error(ewe.BodyTooLarge) -> Error(BodyTooLarge)
        Error(ewe.InvalidBody) -> Error(InvalidBody)
      }
  }
}

/// The address the request came from: an IP for TCP connections, the socket
/// path for Unix sockets, or `None` when it cannot be determined.
pub fn client_ip(request: Request(Body)) -> Option(String) {
  case request.body {
    Live(connection:) ->
      case ewe.get_client_info(connection) {
        ewe.TcpSocketAddress(ip_address:, ..) ->
          Some(ewe.ip_address_to_string(ip_address))
        ewe.UnixSocketAddress(path) -> Some(path)
      }
    Fake(ip:, ..) -> ip
  }
}
