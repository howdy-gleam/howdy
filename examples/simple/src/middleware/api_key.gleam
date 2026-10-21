//// Rejects requests that do not carry the expected `x-api-key` header.

import gleam/http/request
import howdy/controller.{type Context}
import howdy/middleware.{type Next}
import howdy/service

const expected = "secret"

pub fn require(ctx: Context, next: Next) {
  case request.get_header(ctx.request, "x-api-key") {
    Ok(key) if key == expected -> next(ctx)
    _ -> service.error_response(ctx, service.Unauthorized)
  }
}
