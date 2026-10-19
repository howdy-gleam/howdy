import gleam/json
import gleam/string
import gleeunit
import howdy/problem
import howdy/service
import howdy/testing
import howdy_openapi_example as example

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn list_users_test() {
  let res =
    testing.get("/user")
    |> testing.query([#("min_age", "40")])
    |> testing.send(example.app())
  assert testing.text(res)
    == "[{\"id\":2,\"name\":\"Grace\",\"email\":\"grace@example.com\",\"age\":45}]"
}

pub fn create_user_test() {
  let res =
    testing.post(
      "/user",
      json.object([
        #("name", json.string(" Linus ")),
        #("email", json.string("linus@example.com")),
        #("age", json.int(28)),
      ]),
    )
    |> testing.send(example.app())
  assert res.status == 201
  assert string.contains(testing.text(res), "\"name\":\"Linus\"")
}

pub fn rejects_bad_input_test() {
  let res =
    testing.post(
      "/user",
      json.object([
        #("name", json.string(" ")),
        #("email", json.string("nope")),
        #("age", json.int(5)),
      ]),
    )
    |> testing.send(example.app())
  assert res.status == 422
  assert testing.field_errors(res)
    == Ok([
      service.FieldError("name", problem.Blank),
      service.FieldError("email", problem.NotEmail),
      service.FieldError("age", problem.TooSmall(13)),
    ])
}

pub fn serves_the_document_test() {
  let res = testing.get("/openapi.json") |> testing.send(example.app())
  let text = testing.text(res)
  assert string.contains(text, "\"/v1/user/{id}\"")
  assert string.contains(text, "\"NewUser\"")
}

pub fn version_two_wraps_the_list_test() {
  let res =
    testing.get("/v2/user")
    |> testing.query([#("min_age", "40")])
    |> testing.send(example.app())
  assert testing.text(res)
    == "{\"users\":[{\"id\":2,\"name\":\"Grace\",\"email\":\"grace@example.com\",\"age\":45}],\"count\":1}"
  // Routes v2 does not change fall back to v1.
  assert { testing.get("/v2/user/2") |> testing.send(example.app()) }.status
    == 200
}

pub fn serves_a_document_per_version_test() {
  let v2 = testing.get("/openapi/v2.json") |> testing.send(example.app())
  assert string.contains(testing.text(v2), "\"/v2/user/{id}\"")
  assert string.contains(testing.text(v2), "\"UserPage\"")
  let v1 = testing.get("/openapi/v1.json") |> testing.send(example.app())
  assert !string.contains(testing.text(v1), "UserPage")
}
