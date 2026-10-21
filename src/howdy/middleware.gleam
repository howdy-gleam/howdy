//// Middleware runs around a handler. It can reject a request before the
//// handler runs, change the context on the way in, or change the response
//// on the way out.
////
//// ```gleam
//// pub fn require_api_key(ctx: Context, next: Next) {
////   case request.get_header(ctx.request, "x-api-key") {
////     Ok("secret") -> next(ctx)
////     _ -> service.error_response(ctx, service.Unauthorized)
////   }
//// }
//// ```
////
//// Apply it at three levels:
////
//// ```gleam
//// howdy.new() |> howdy.middleware(request_logger)              // every request
//// controller.new("user") |> controller.middleware(require_api_key) // every route
//// controller.post("/", create |> middleware.wrap(rate_limit))   // one route
//// ```
////
//// App middleware wraps controller middleware, which wraps route middleware,
//// which wraps the handler. Within a level the first added is the outermost.

import gleam/http/response.{type Response}
import gleam/option.{None, Some}
import howdy/content.{type Content}
import howdy/controller.{type Context, type Handler}
import howdy/service
import howdy/trace
import logging

pub type Next =
  controller.Next

pub type Middleware =
  controller.Middleware

/// Wrap a handler in one middleware.
pub fn wrap(handler: Handler, middleware: Middleware) -> Handler {
  controller.wrap(handler, middleware)
}

/// Wrap a handler in several middleware. The first in the list is the
/// outermost.
pub fn wrap_all(handler: Handler, middleware: List(Middleware)) -> Handler {
  controller.wrap_all(handler, middleware)
}

/// Answer a crashed handler with a `500` in the same shape as every other
/// error, instead of dropping the connection.
///
/// Without it the server still replies `500` to a crash, but with an empty
/// body and, on HTTP/1, a closed connection, and the app gets no say. With
/// it the crash is logged with its stack trace and the current trace id, the
/// response is `service.Internal`'s JSON, and the connection stays open.
///
/// ```gleam
/// howdy.new() |> howdy.middleware(middleware.rescue)
/// ```
///
/// Add it first, so it wraps the rest of the app's middleware too.
pub fn rescue(ctx: Context, next: Next) -> Response(Content) {
  case rescue_crash(fn() { next(ctx) }) {
    Ok(response) -> response
    Error(reason) -> {
      let where = case trace.trace_id() {
        Some(id) -> " (trace " <> id <> ")"
        None -> ""
      }
      logging.log(logging.Error, "handler crashed" <> where <> ": " <> reason)
      service.error_response(ctx, service.Internal("handler crashed"))
    }
  }
}

@external(erlang, "howdy_ffi", "rescue")
fn rescue_crash(run: fn() -> a) -> Result(a, String)
