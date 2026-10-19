//// Every request from the README's curl list, run through the app without a
//// server. `howdy_example.app()` builds the app; `howdy/testing` sends
//// requests through it and reads the responses.

import gleam/dynamic/decode
import gleam/http
import gleam/http/response
import gleam/json
import gleam/list
import howdy/service.{FieldError}
import howdy/testing
import howdy_example.{app}
import user/user.{type User, User}

fn user_decoder() -> decode.Decoder(User) {
  use id <- decode.field("id", decode.int)
  use name <- decode.field("name", decode.string)
  use email <- decode.field("email", decode.string)
  use age <- decode.field("age", decode.int)
  decode.success(User(id:, name:, email:, age:))
}

fn new_user(name: String, email: String, age: Int) -> json.Json {
  json.object([
    #("name", json.string(name)),
    #("email", json.string(email)),
    #("age", json.int(age)),
  ])
}

pub fn all_users_test() {
  let res = testing.get("/user/all") |> testing.send(app())

  assert res.status == 200
  let assert Ok(users) = testing.json(res, decode.list(user_decoder()))
  assert list.map(users, fn(user) { user.name }) == ["Ada", "Grace", "Joe"]
  // Controller middleware ran.
  assert response.get_header(res, "x-powered-by") == Ok("howdy")
}

pub fn find_user_test() {
  let res = testing.get("/user/2") |> testing.send(app())

  assert res.status == 200
  assert testing.json(res, user_decoder())
    == Ok(User(2, "Grace", "grace@example.com", 45))
}

pub fn unchanged_user_is_not_modified_test() {
  let first = testing.get("/user/1") |> testing.send(app())
  let assert Ok(etag) = response.get_header(first, "etag")

  let again =
    testing.get("/user/1")
    |> testing.header("if-none-match", etag)
    |> testing.send(app())
  assert again.status == 304
  assert testing.text(again) == ""
}

pub fn unknown_user_is_not_found_test() {
  let res = testing.get("/user/9") |> testing.send(app())

  assert res.status == 404
  assert testing.error(res) == Ok("user 9")
}

pub fn id_must_be_an_integer_test() {
  let res = testing.get("/user/abc") |> testing.send(app())

  assert res.status == 400
  assert testing.error(res) == Ok("parameter id must be an integer")
}

pub fn create_user_test() {
  let res =
    testing.post("/user", new_user("Linus", "linus@example.com", 28))
    |> testing.send(app())

  assert res.status == 201
  assert testing.json(res, user_decoder())
    == Ok(User(4, "Linus", "linus@example.com", 28))
}

pub fn create_reports_every_invalid_field_test() {
  let res =
    testing.post("/user", new_user(" ", "nope", 5)) |> testing.send(app())

  assert res.status == 422
  assert testing.error(res) == Ok("validation failed")
  assert testing.field_errors(res)
    == Ok([
      FieldError("name", "must not be empty"),
      FieldError("email", "must be a valid email address"),
      FieldError("age", "must be at least 13"),
    ])
}

pub fn create_rejects_taken_email_test() {
  // Well formed, so it passes validation and fails in the service.
  let res =
    testing.post("/user", new_user("Ada", "ada@example.com", 36))
    |> testing.send(app())

  assert res.status == 422
  assert testing.field_errors(res)
    == Ok([FieldError("email", "is already taken")])
}

pub fn create_rejects_malformed_json_test() {
  let res =
    testing.request(http.Post, "/user")
    |> testing.text_body("not json")
    |> testing.send(app())

  assert res.status == 400
  assert testing.error(res) == Ok("request body is not valid JSON")
}

pub fn delete_requires_api_key_test() {
  let denied = testing.delete("/user/2") |> testing.send(app())
  assert denied.status == 401
  assert testing.error(denied) == Ok("unauthorized")

  let allowed =
    testing.delete("/user/2")
    |> testing.header("x-api-key", "secret")
    |> testing.send(app())
  assert allowed.status == 204
  assert testing.text(allowed) == ""
}

pub fn method_not_allowed_test() {
  let res = testing.request(http.Put, "/user/all") |> testing.send(app())

  assert res.status == 405
  // `/user/all` also matches the `/:id` delete route, so both are allowed
  // (plus HEAD, which GET routes answer too).
  assert response.get_header(res, "allow") == Ok("GET, HEAD, DELETE")
}

pub fn create_is_rate_limited_per_api_key_test() {
  // One app, so every request shares the controller's token bucket.
  let app = app()
  let create = fn() {
    testing.post("/user", new_user("A", "a@b.co", 20))
    |> testing.header("x-api-key", "secret")
    |> testing.send(app)
  }

  // A burst of three, then the bucket is empty.
  assert create().status == 201
  assert create().status == 201
  assert create().status == 201
  let limited = create()
  assert limited.status == 429
  assert testing.error(limited) == Ok("too many requests")
  assert response.get_header(limited, "retry-after") == Ok("1")
}

pub fn whole_app_is_rate_limited_per_ip_test() {
  let app = app()
  let from = fn(ip) {
    testing.get("/user/all") |> testing.from_ip(ip) |> testing.send(app)
  }

  list.each(list.repeat(Nil, 100), fn(_) {
    assert from("203.0.113.9").status == 200
  })
  assert from("203.0.113.9").status == 429
  // Another client is unaffected.
  assert from("203.0.113.10").status == 200
}
