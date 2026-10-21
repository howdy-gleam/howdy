import gleam/dict
import gleam/dynamic/decode
import gleam/http
import gleam/http/response
import gleam/json
import gleam/option.{None}
import howdy
import howdy/body
import howdy/context.{Context}
import howdy/controller.{type Context}
import howdy/param
import howdy/service
import howdy/testing

/// A bare context for calling helpers directly, outside any route.
fn ctx(params: List(#(String, String))) -> Context {
  Context(
    request: testing.get("/"),
    params: dict.from_list(params),
    guard: Nil,
    version: None,
  )
}

fn encode(value: String) -> json.Json {
  json.object([#("value", json.string(value))])
}

pub fn respond_ok_test() {
  let res = service.respond(Ok("hi"), ctx([]), encode)
  assert res.status == 200
  assert testing.json(res, decode.at(["value"], decode.string)) == Ok("hi")
}

pub fn respond_not_found_test() {
  let res = service.respond(Error(service.NotFound("user 9")), ctx([]), encode)
  assert res.status == 404
  assert testing.error(res) == Ok("user 9")
}

pub fn respond_error_codes_test() {
  let status = fn(error) {
    service.respond(Error(error), ctx([]), encode).status
  }
  assert status(service.Invalid("x")) == 400
  assert status(service.Conflict("x")) == 409
  assert status(service.Unauthorized) == 401
  assert status(service.Forbidden) == 403
  assert status(service.Internal("secret detail")) == 500
}

pub fn every_error_has_a_code_test() {
  let code_of = fn(error) {
    service.respond(Error(error), ctx([]), encode)
    |> testing.json(decode.at(["code"], decode.string))
  }
  assert code_of(service.NotFound("user 9")) == Ok("not_found")
  assert code_of(service.Invalid("bad")) == Ok("invalid")
  assert code_of(service.TooManyRequests(5)) == Ok("too_many_requests")
  assert code_of(service.Validation([])) == Ok("validation")
}

pub fn coded_errors_answer_as_the_error_inside_test() {
  let taken = service.Coded("email_taken", service.Conflict("already taken"))
  let res = service.respond(Error(taken), ctx([]), encode)
  assert res.status == 409
  assert testing.error(res) == Ok("already taken")
  assert testing.json(res, decode.at(["code"], decode.string))
    == Ok("email_taken")
  assert service.code(taken) == "email_taken"
  assert service.message(taken) == "already taken"
  assert service.uncoded(taken) == service.Conflict("already taken")
  assert service.uncoded(service.Forbidden) == service.Forbidden
  // A coded rate limit still says when to retry.
  let res =
    service.respond(
      Error(service.Coded("slow_down", service.TooManyRequests(30))),
      ctx([]),
      encode,
    )
  assert res.status == 429
  assert response.get_header(res, "retry-after") == Ok("30")
}

pub fn internal_error_hides_detail_test() {
  let res = service.respond(Error(service.Internal("db down")), ctx([]), encode)
  assert testing.error(res) == Ok("internal server error")
}

pub fn created_test() {
  let res = service.created(Ok("hi"), ctx([]), encode)
  assert res.status == 201
}

pub fn no_content_test() {
  let res = service.no_content(Ok(Nil), ctx([]))
  assert res.status == 204
  assert testing.text(res) == ""

  let res = service.no_content(Error(service.NotFound("gone")), ctx([]))
  assert res.status == 404
}

pub fn error_is_nil_for_other_bodies_test() {
  assert testing.error(controller.text(ctx([]), "plain")) == Error(Nil)
  assert testing.field_errors(service.respond(Ok("hi"), ctx([]), encode))
    == Error(Nil)
}

// -- param -------------------------------------------------------------------

pub fn param_int_test() {
  let res = {
    use id <- param.int(ctx([#("id", "42")]), "id")
    assert id == 42
    controller.text(ctx([]), "ran")
  }
  assert testing.text(res) == "ran"
}

pub fn param_int_not_a_number_test() {
  let res = {
    use _ <- param.int(ctx([#("id", "abc")]), "id")
    panic as "continuation must not run"
  }
  assert res.status == 400
  assert testing.error(res) == Ok("parameter id must be an integer")
}

pub fn param_missing_test() {
  let res = {
    use _ <- param.string(ctx([]), "id")
    panic as "continuation must not run"
  }
  assert res.status == 400
  assert testing.error(res) == Ok("missing parameter id")
}

// -- body --------------------------------------------------------------------

fn name_decoder() -> decode.Decoder(String) {
  use name <- decode.field("name", decode.string)
  decode.success(name)
}

fn app(handler: controller.Handler) -> howdy.App {
  howdy.new()
  |> howdy.controller(controller.new("/") |> controller.post("/", handler))
}

pub fn body_json_reads_the_request_test() {
  let app =
    app(fn(ctx) {
      use name <- body.json(ctx, name_decoder())
      controller.text(ctx, name)
    })
  let res =
    testing.post("/", json.object([#("name", json.string("Ada"))]))
    |> testing.send(app)
  assert res.status == 200
  assert testing.text(res) == "Ada"
}

pub fn body_json_wrong_shape_test() {
  let app =
    app(fn(ctx) {
      use _ <- body.json(ctx, name_decoder())
      panic as "continuation must not run"
    })
  let res =
    testing.post("/", json.object([#("name", json.int(1))]))
    |> testing.send(app)
  assert res.status == 400
  assert testing.error(res)
    == Ok("invalid request body: name expected String, found Int")
}

pub fn body_json_not_json_test() {
  let app =
    app(fn(ctx) {
      use _ <- body.json(ctx, name_decoder())
      panic as "continuation must not run"
    })
  let res =
    testing.request(http.Post, "/")
    |> testing.text_body("nope")
    |> testing.send(app)
  assert res.status == 400
  assert testing.error(res) == Ok("request body is not valid JSON")
}

pub fn body_json_too_large_test() {
  let app =
    app(fn(ctx) {
      use _ <- body.json_with_limit(ctx, 8, name_decoder())
      panic as "continuation must not run"
    })
  let res =
    testing.post("/", json.object([#("name", json.string("Ada"))]))
    |> testing.send(app)
  assert res.status == 400
  assert testing.error(res) == Ok("request body too large")
}

pub fn body_json_from_test() {
  let res = {
    use name <- body.json_from(
      ctx([]),
      <<"{\"name\":\"Ada\"}">>,
      name_decoder(),
    )
    controller.text(ctx([]), name)
  }
  assert testing.text(res) == "Ada"
}
