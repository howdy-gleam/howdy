//// Guards reject a request or provide a typed value to its continuation.

import gleam/http/response.{type Response}
import howdy/content.{type Content}
import howdy/context.{type Context}
import howdy/service

/// A request check. Checks without a useful output return `Ok(Nil)`.
pub type Guard(existing, value) =
  fn(Context(existing)) -> service.Result(value)

/// Run an endpoint guard. On success, pass its value to `next`; on failure,
/// return the service error response without calling `next`.
///
/// ```gleam
/// use user <- guard.require(ctx, authenticated)
/// user_service.find(user.id) |> service.respond(ctx, user.to_json)
/// ```
pub fn require(
  ctx: Context(existing),
  check: Guard(existing, value),
  next: fn(value) -> Response(Content),
) -> Response(Content) {
  case check(ctx) {
    Ok(value) -> next(value)
    Error(error) -> service.error_response(ctx, error)
  }
}
