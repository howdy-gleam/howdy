//// Request logging middleware.
////
//// ```gleam
//// import howdy
//// import howdy/logger
//// import logging
////
//// logging.configure()
////
//// howdy.new()
//// |> howdy.middleware(logger.log)
//// ```
////
//// Add the logger first to include responses from middleware that rejects
//// requests or answers them directly, such as authentication or CORS.
//// Unmatched routes bypass middleware and are not logged.

import gleam/http
import gleam/http/response.{type Response}
import gleam/int
import howdy/content.{type Content}
import howdy/controller.{type Context}
import howdy/middleware.{type Next}
import logging

/// Log the method, path and returned status at `Info`, for example
/// `GET /user/2 -> 200`. Returns the response unchanged.
///
/// Configure logging in your application's startup code; this middleware
/// does not change the global logging configuration. Query strings, headers
/// and bodies are not included. If the next handler panics, no entry is logged.
pub fn log(ctx: Context, next: Next) -> Response(Content) {
  let response = next(ctx)
  logging.log(
    logging.Info,
    http.method_to_string(ctx.request.method)
      <> " "
      <> ctx.request.path
      <> " -> "
      <> int.to_string(response.status),
  )
  response
}
