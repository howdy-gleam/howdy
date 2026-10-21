//// Adds an `x-powered-by` header to every response it wraps.

import gleam/http/response
import howdy/controller.{type Context}
import howdy/middleware.{type Next}

pub fn header(ctx: Context, next: Next) {
  next(ctx)
  |> response.set_header("x-powered-by", "howdy")
}
