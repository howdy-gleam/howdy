//// Typed query string extraction with automatic JSON `400` responses.
//// Required helpers reject missing values; `optional_*` helpers return `None`;
//// `*_or` helpers use their default only when the key is absent.
//// Invalid values and duplicate singular keys always fail.
//// Empty strings are preserved. Booleans accept only `true` and `false`.
//// Repeated values are available through `strings`, in request order.
////
//// ```gleam
//// use page <- query.int_or(ctx, "page", default: 1)
//// use search <- query.optional_string(ctx, "search")
//// ```

import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import howdy/content.{type Content}
import howdy/controller.{type GuardedContext}
import howdy/service

/// Extract a required string. Missing or invalid input returns `400`.
pub fn string(
  ctx: GuardedContext(guarded),
  name: String,
  next: fn(String) -> Response(Content),
) -> Response(Content) {
  use value <- optional_string(ctx, name)
  case value {
    Some(value) -> next(value)
    None -> invalid(ctx, "missing query parameter " <> name)
  }
}

/// Extract an optional string. Invalid input still returns `400`.
pub fn optional_string(
  ctx: GuardedContext(guarded),
  name: String,
  next: fn(Option(String)) -> Response(Content),
) -> Response(Content) {
  optional(ctx, name, parse_string, next)
}

/// Extract a string, using `default` only when the key is absent.
pub fn string_or(
  ctx: GuardedContext(guarded),
  name: String,
  default default: String,
  next next: fn(String) -> Response(Content),
) -> Response(Content) {
  use value <- optional_string(ctx, name)
  next(option.unwrap(value, default))
}

/// Extract a required integer. Missing or invalid input returns `400`.
pub fn int(
  ctx: GuardedContext(guarded),
  name: String,
  next: fn(Int) -> Response(Content),
) -> Response(Content) {
  use value <- optional_int(ctx, name)
  case value {
    Some(value) -> next(value)
    None -> invalid(ctx, "missing query parameter " <> name)
  }
}

/// Extract an optional integer. Invalid input still returns `400`.
pub fn optional_int(
  ctx: GuardedContext(guarded),
  name: String,
  next: fn(Option(Int)) -> Response(Content),
) -> Response(Content) {
  optional(ctx, name, parse_int, next)
}

/// Extract a integer, using `default` only when the key is absent.
pub fn int_or(
  ctx: GuardedContext(guarded),
  name: String,
  default default: Int,
  next next: fn(Int) -> Response(Content),
) -> Response(Content) {
  use value <- optional_int(ctx, name)
  next(option.unwrap(value, default))
}

/// Extract a required boolean. Missing or invalid input returns `400`.
pub fn bool(
  ctx: GuardedContext(guarded),
  name: String,
  next: fn(Bool) -> Response(Content),
) -> Response(Content) {
  use value <- optional_bool(ctx, name)
  case value {
    Some(value) -> next(value)
    None -> invalid(ctx, "missing query parameter " <> name)
  }
}

/// Extract an optional boolean. Invalid input still returns `400`.
pub fn optional_bool(
  ctx: GuardedContext(guarded),
  name: String,
  next: fn(Option(Bool)) -> Response(Content),
) -> Response(Content) {
  optional(ctx, name, parse_bool, next)
}

/// Extract a boolean, using `default` only when the key is absent.
pub fn bool_or(
  ctx: GuardedContext(guarded),
  name: String,
  default default: Bool,
  next next: fn(Bool) -> Response(Content),
) -> Response(Content) {
  use value <- optional_bool(ctx, name)
  next(option.unwrap(value, default))
}

/// Extract all values for a key, preserving order and empty strings.
/// An absent key gives `[]`; invalid query encoding returns `400`.
pub fn strings(
  ctx: GuardedContext(guarded),
  name: String,
  next: fn(List(String)) -> Response(Content),
) -> Response(Content) {
  case get_query(ctx.request) {
    Ok(pairs) ->
      pairs
      |> list.filter(fn(pair) { pair.0 == name })
      |> list.map(fn(pair) { pair.1 })
      |> next
    Error(Nil) -> invalid(ctx, "query string has invalid encoding")
  }
}

/// Decode the query string. Same results as `request.get_query`, a few
/// times faster; every field read decodes, so this is the hot path.
@internal
pub fn get_query(
  request: request.Request(body),
) -> Result(List(#(String, String)), Nil) {
  case request.query {
    Some(query) -> parse_query(query)
    None -> Ok([])
  }
}

/// Decode `key=value&...` pairs. `howdy/form` shares it, since urlencoded
/// form bodies use the same grammar.
@external(erlang, "howdy_query_ffi", "parse_query")
@internal
pub fn parse_query(query: String) -> Result(List(#(String, String)), Nil)

fn optional(
  ctx: GuardedContext(guarded),
  name: String,
  parse: fn(String) -> Result(a, String),
  next: fn(Option(a)) -> Response(Content),
) -> Response(Content) {
  use values <- strings(ctx, name)
  case values {
    [] -> next(None)
    [value] ->
      case parse(value) {
        Ok(value) -> next(Some(value))
        Error(expected) ->
          invalid(ctx, "query parameter " <> name <> " must be " <> expected)
      }
    _ -> invalid(ctx, "query parameter " <> name <> " must occur only once")
  }
}

fn parse_string(value: String) -> Result(String, String) {
  Ok(value)
}

fn parse_int(value: String) -> Result(Int, String) {
  case int.parse(value) {
    Ok(value) -> Ok(value)
    Error(Nil) -> Error("an integer")
  }
}

fn parse_bool(value: String) -> Result(Bool, String) {
  case value {
    "true" -> Ok(True)
    "false" -> Ok(False)
    _ -> Error("true or false")
  }
}

fn invalid(ctx: GuardedContext(guarded), message: String) -> Response(Content) {
  service.error_response(ctx, service.Invalid(message))
}
