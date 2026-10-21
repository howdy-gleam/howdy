//// Demo credentials only: replace this lookup with session/token validation.

import gleam/http/request
import howdy/controller.{type GuardedContext}
import howdy/service

pub type CurrentUser {
  CurrentUser(id: Int, is_admin: Bool)
}

/// Works both as a controller guard and an endpoint guard.
pub fn authenticated(
  ctx: GuardedContext(existing),
) -> service.Result(CurrentUser) {
  case request.get_header(ctx.request, "authorization") {
    Ok("Bearer member-token") -> Ok(CurrentUser(id: 1, is_admin: False))
    Ok("Bearer admin-token") -> Ok(CurrentUser(id: 2, is_admin: True))
    _ -> Error(service.Unauthorized)
  }
}

/// Reuses the controller's authenticated identity, without validating again.
pub fn admin(ctx: GuardedContext(CurrentUser)) -> service.Result(Nil) {
  case ctx.guard.is_admin {
    True -> Ok(Nil)
    False -> Error(service.Forbidden)
  }
}
