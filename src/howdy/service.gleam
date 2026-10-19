//// Services hold application logic and return plain results. This module
//// turns those results into HTTP responses so controllers stay lean.
////
//// ```gleam
//// fn by_id(ctx: Context) {
////   use id <- param.int(ctx, "id")
////   user_service.find(id)
////   |> service.respond(ctx, user.to_json)
//// }
//// ```

import gleam
import gleam/http/response.{type Response}
import gleam/int
import gleam/json.{type Json}
import howdy/content.{type Content}
import howdy/context.{type Context}
import howdy/problem.{type Problem}
import logging

/// The ways a service call can fail. Each variant maps to a status code.
pub type Error {
  /// 404. The message names what was not found.
  NotFound(String)
  /// 400. The message explains what was wrong with the input.
  Invalid(String)
  /// 409. The message explains the conflict.
  Conflict(String)
  /// 401.
  Unauthorized
  /// 403.
  Forbidden
  /// 415. The message names the content type that was expected. Usually
  /// produced by `howdy/form`.
  UnsupportedMediaType(String)
  /// 500. The message is logged and never sent to the client.
  Internal(String)
  /// 422. Input was well formed but failed validation. Usually produced by
  /// `howdy/validate`, but a service can return it too, for example for a
  /// duplicate email.
  Validation(List(FieldError))
  /// 429 with a `retry-after` header. Usually produced by `howdy/rate_limit`,
  /// but a service can return it too, for example for password resets.
  TooManyRequests(retry_after_seconds: Int)
  /// Another error with a stable code for clients, which answers as `error`
  /// does with `code` in its body. A client that shows errors in other
  /// languages translates by code, since the message is English:
  /// `Coded("email_taken", Conflict("an account already exists"))`.
  /// `uncoded` gives the error inside, for matching on its kind.
  Coded(code: String, error: Error)
}

/// One problem with one field. The same type as `validate.FieldError`.
pub type FieldError {
  FieldError(field: String, problem: Problem)
}

/// The result type every service function returns.
pub type Result(a) =
  gleam.Result(a, Error)

/// `Ok` becomes `200` with the encoded value. `Error` becomes the matching
/// status with a JSON body of `{"error": "...", "code": "..."}`.
pub fn respond(
  result: Result(a),
  ctx: Context(guarded),
  encode: fn(a) -> Json,
) -> Response(Content) {
  case result {
    Ok(value) -> json_response(encode(value))
    Error(error) -> error_response(ctx, error)
  }
}

/// Like `respond` but `Ok` becomes `201`.
pub fn created(
  result: Result(a),
  ctx: Context(guarded),
  encode: fn(a) -> Json,
) -> Response(Content) {
  case result {
    Ok(value) -> json_response(encode(value)) |> with_status(201)
    Error(error) -> error_response(ctx, error)
  }
}

/// `Ok` becomes `204` with no body. Useful for deletes.
pub fn no_content(
  result: Result(Nil),
  ctx: Context(guarded),
) -> Response(Content) {
  case result {
    Ok(Nil) -> response.new(204) |> response.set_body(content.Empty)
    Error(error) -> error_response(ctx, error)
  }
}

/// The status code an error maps to.
pub fn status_code(error: Error) -> Int {
  case error {
    NotFound(_) -> 404
    Invalid(_) -> 400
    Conflict(_) -> 409
    Unauthorized -> 401
    Forbidden -> 403
    UnsupportedMediaType(_) -> 415
    Internal(_) -> 500
    Validation(_) -> 422
    TooManyRequests(_) -> 429
    Coded(error:, ..) -> status_code(error)
  }
}

/// The message sent to the client for an error.
pub fn message(error: Error) -> String {
  case error {
    NotFound(message) -> message
    Invalid(message) -> message
    Conflict(message) -> message
    Unauthorized -> "unauthorized"
    Forbidden -> "forbidden"
    UnsupportedMediaType(message) -> message
    Internal(_) -> "internal server error"
    Validation(_) -> "validation failed"
    TooManyRequests(_) -> "too many requests"
    Coded(error:, ..) -> message(error)
  }
}

/// The code sent to the client for an error: a `Coded` error's own, or one
/// for its kind, such as `not_found` or `too_many_requests`.
pub fn code(error: Error) -> String {
  case error {
    NotFound(_) -> "not_found"
    Invalid(_) -> "invalid"
    Conflict(_) -> "conflict"
    Unauthorized -> "unauthorized"
    Forbidden -> "forbidden"
    UnsupportedMediaType(_) -> "unsupported_media_type"
    Internal(_) -> "internal"
    Validation(_) -> "validation"
    TooManyRequests(_) -> "too_many_requests"
    Coded(code:, ..) -> code
  }
}

/// The error without any `Coded` around it.
pub fn uncoded(error: Error) -> Error {
  case error {
    Coded(error:, ..) -> uncoded(error)
    _ -> error
  }
}

/// Build the response for an error. Used by `respond` and by the extractors
/// in `howdy/param` and `howdy/body` so every error has the same shape.
pub fn error_response(
  _ctx: Context(guarded),
  error: Error,
) -> Response(Content) {
  let kind = uncoded(error)
  case kind {
    Internal(detail) -> logging.log(logging.Error, detail)
    _ -> Nil
  }

  let fields = case kind {
    Validation(errors) -> [
      #(
        "fields",
        json.array(errors, fn(e) {
          json.object([
            #("field", json.string(e.field)),
            ..problem.to_json_fields(e.problem)
          ])
        }),
      ),
    ]
    _ -> []
  }

  let response =
    json_response(
      json.object([
        #("error", json.string(message(error))),
        #("code", json.string(code(error))),
        ..fields
      ]),
    )
    |> with_status(status_code(error))

  case kind {
    TooManyRequests(seconds) ->
      response.set_header(response, "retry-after", int.to_string(seconds))
    _ -> response
  }
}

fn json_response(body: Json) -> Response(Content) {
  response.new(200)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_body(content.Text(json.to_string(body)))
}

fn with_status(res: Response(Content), code: Int) -> Response(Content) {
  response.Response(..res, status: code)
}
