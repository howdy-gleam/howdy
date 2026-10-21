//// Route annotations carried as `Dynamic`, tagged with the key they are
//// stored under so a value is only ever read back as the type that key
//// holds.

import gleam/dynamic.{type Dynamic}

/// Wrap `value` to store with `controller.annotate` under `key`.
@internal
pub fn wrap(key: String, value: a) -> Dynamic {
  tag(key, value)
}

/// The value `wrap` stored under `key`. Panics, naming the key, if the
/// annotation was not made by `wrap` for that key.
@internal
pub fn unwrap(annotation: Dynamic, key: String) -> a {
  case check(annotation, key) {
    Ok(value) -> value
    Error(Nil) ->
      panic as {
        "howdy/openapi: the route annotation "
        <> key
        <> " was not written by howdy/openapi"
      }
  }
}

@external(erlang, "howdy_openapi_ffi", "wrap")
fn tag(key: String, value: a) -> Dynamic

@external(erlang, "howdy_openapi_ffi", "unwrap")
fn check(annotation: Dynamic, key: String) -> Result(a, Nil)
