//// Typed extraction of path parameters. Each function takes a continuation
//// so it can be used with `use`. When the parameter is missing or has the
//// wrong shape a `400` response is returned and the continuation never runs.
////
//// ```gleam
//// fn by_id(ctx: Context) {
////   use id <- param.int(ctx, "id")
////   ...
//// }
//// ```

import gleam/http/response.{type Response}
import gleam/int
import howdy/content.{type Content}
import howdy/controller.{type GuardedContext}
import howdy/service

/// Extract a string parameter.
pub fn string(
  ctx: GuardedContext(guarded),
  name: String,
  next: fn(String) -> Response(Content),
) -> Response(Content) {
  case controller.param(ctx, name) {
    Ok(value) -> next(value)
    Error(Nil) -> missing(ctx, name)
  }
}

/// Extract an integer parameter.
pub fn int(
  ctx: GuardedContext(guarded),
  name: String,
  next: fn(Int) -> Response(Content),
) -> Response(Content) {
  use value <- string(ctx, name)
  case int.parse(value) {
    Ok(value) -> next(value)
    Error(Nil) -> invalid(ctx, name, "an integer")
  }
}

fn missing(ctx: GuardedContext(guarded), name: String) -> Response(Content) {
  service.error_response(ctx, service.Invalid("missing parameter " <> name))
}

fn invalid(
  ctx: GuardedContext(guarded),
  name: String,
  expected: String,
) -> Response(Content) {
  service.error_response(
    ctx,
    service.Invalid("parameter " <> name <> " must be " <> expected),
  )
}
