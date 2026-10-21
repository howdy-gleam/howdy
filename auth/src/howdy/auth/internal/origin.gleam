//// The Origin check that protects cookie-authenticated writes against CSRF.
//// `howdy/auth` is the public face; `check_origin` there delegates here.

import gleam/list
import gleam/string
import howdy/context.{type Context}
import howdy/service

/// Require an exact, single Origin equal to the configured one. The
/// configured origin is never inferred from Host or forwarded headers.
pub fn check(origin: String, ctx: Context(a)) -> service.Result(Nil) {
  case
    list.filter(ctx.request.headers, fn(h) { string.lowercase(h.0) == "origin" })
  {
    [#(_, value)] if value == origin -> Ok(Nil)
    _ -> Error(service.Forbidden)
  }
}
