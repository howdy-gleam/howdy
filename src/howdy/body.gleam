//// Reading and decoding request bodies. Each function takes a continuation
//// so it can be used with `use`. When the body cannot be read or decoded a
//// `400` response is returned and the continuation never runs.
////
//// ```gleam
//// fn create(ctx: GuardedContext(guarded)) {
////   use input <- body.json(ctx, user.new_user_decoder())
////   ...
//// }
//// ```

import gleam/dynamic/decode.{type Decoder}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/string
import howdy/content.{type Content}
import howdy/context
import howdy/controller.{type GuardedContext}
import howdy/service
import howdy/validate

/// The largest body `json` will read, in bytes. One mebibyte.
pub const default_limit = 1_048_576

/// Read the request body and decode it as JSON with `decoder`.
pub fn json(
  ctx: GuardedContext(guarded),
  decoder: Decoder(a),
  next: fn(a) -> Response(Content),
) -> Response(Content) {
  json_with_limit(ctx, default_limit, decoder, next)
}

/// Read the request body, decode it as JSON, then validate it. Decode
/// failures return `400`; validation failures return `422` with every field
/// error. The continuation only runs with a validated value.
pub fn validated(
  ctx: GuardedContext(guarded),
  decoder: Decoder(a),
  validator: fn(a) -> validate.Result(b),
  next: fn(b) -> Response(Content),
) -> Response(Content) {
  use input <- json(ctx, decoder)
  validate.check(ctx, validator(input), next)
}

/// Like `json` but with a custom size limit in bytes.
pub fn json_with_limit(
  ctx: GuardedContext(guarded),
  limit: Int,
  decoder: Decoder(a),
  next: fn(a) -> Response(Content),
) -> Response(Content) {
  case controller.read_body(ctx, limit:) {
    Ok(bits) -> json_from(ctx, bits, decoder, next)
    Error(context.BodyTooLarge) ->
      service.error_response(ctx, service.Invalid("request body too large"))
    Error(context.InvalidBody) ->
      service.error_response(
        ctx,
        service.Invalid("request body could not be read"),
      )
  }
}

/// Decode an already-read body as JSON. `json` calls this after reading; use
/// it directly when you have read the body yourself with `controller.read_body`.
pub fn json_from(
  ctx: GuardedContext(guarded),
  bits: BitArray,
  decoder: Decoder(a),
  next: fn(a) -> Response(Content),
) -> Response(Content) {
  case json.parse_bits(bits, decoder) {
    Ok(value) -> next(value)
    Error(error) ->
      service.error_response(ctx, service.Invalid(describe(error)))
  }
}

fn describe(error: json.DecodeError) -> String {
  case error {
    json.UnableToDecode(errors) ->
      "invalid request body: "
      <> errors
      |> list.map(fn(e) {
        let path = case e.path {
          [] -> "body"
          path -> string.join(path, ".")
        }
        path <> " expected " <> e.expected <> ", found " <> e.found
      })
      |> string.join("; ")
    _ -> "request body is not valid JSON"
  }
}
