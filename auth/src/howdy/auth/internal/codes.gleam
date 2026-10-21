//// Stable codes for the JSON API's answers, so a client can show its own
//// words instead of the English `error` or `message`.
////
//// Errors carry their codes themselves: the flows build user-facing
//// failures as `service.Coded`, and `service.error_response` sends every
//// error's code. Successful answers that tell the reader something carry a
//// code too, built here.

import gleam/json

/// The body of a successful answer that tells its reader something:
/// `{"code": ..., "message": ...}`.
pub fn message(code: String, message: String) -> json.Json {
  json.object([
    #("code", json.string(code)),
    #("message", json.string(message)),
  ])
}
