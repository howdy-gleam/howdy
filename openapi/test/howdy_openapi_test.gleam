import gleam/dict
import gleam/dynamic/decode
import gleam/http
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import howdy
import howdy/controller
import howdy/openapi
import howdy/openapi/endpoint.{type Endpoint}
import howdy/openapi/schema.{type Schema}
import howdy/problem
import howdy/service
import howdy/testing
import howdy/validate
import howdy/version

pub fn main() -> Nil {
  gleeunit.main()
}

// -- Fixtures ----------------------------------------------------------------

pub type Role {
  Admin
  Member
}

pub type User {
  User(id: Int, name: String, role: Role, nickname: Option(String))
}

pub type NewUser {
  NewUser(name: String, email: String, age: Int, tags: List(String))
}

fn role() -> Schema(Role) {
  schema.enum([Admin, Member], fn(role) {
    case role {
      Admin -> "admin"
      Member -> "member"
    }
  })
}

fn user() -> Schema(User) {
  {
    use id <- schema.field("id", schema.int(), fn(user: User) { user.id })
    use name <- schema.field("name", schema.string(), fn(user: User) {
      user.name
    })
    use role <- schema.field("role", role(), fn(user: User) { user.role })
    use nickname <- schema.optional_field(
      "nickname",
      schema.string(),
      fn(user: User) { user.nickname },
    )
    schema.success(User(id:, name:, role:, nickname:))
  }
  |> schema.named("User")
}

fn new_user() -> Schema(NewUser) {
  use name <- schema.field(
    "name",
    schema.string()
      |> schema.rule(validate.trim())
      |> schema.not_empty
      |> schema.max_length(50),
    fn(input: NewUser) { input.name },
  )
  use email <- schema.field(
    "email",
    schema.string() |> schema.email,
    fn(input: NewUser) { input.email },
  )
  use age <- schema.field(
    "age",
    schema.int() |> schema.minimum(13),
    fn(input: NewUser) { input.age },
  )
  use tags <- schema.field(
    "tags",
    schema.list(schema.string()),
    fn(input: NewUser) { input.tags },
  )
  schema.success(NewUser(name:, email:, age:, tags:))
}

fn by_id() -> Endpoint(Nil) {
  use <- endpoint.describe([
    endpoint.summary("Find a user"),
    endpoint.response(200, "The user", user()),
    endpoint.error(404, "No user has this id"),
  ])
  use id <- endpoint.path("id", schema.int() |> schema.minimum(1))
  use ctx <- endpoint.handle
  case id {
    1 -> Ok(User(id: 1, name: "Ada", role: Admin, nickname: None))
    _ -> Error(service.NotFound("no such user"))
  }
  |> service.respond(ctx, schema.to_json(_, user()))
}

fn search() -> Endpoint(Nil) {
  use page <- endpoint.query("page", schema.int())
  use tags <- endpoint.query("tag", schema.list(schema.string()))
  use role <- endpoint.optional_query("role", role())
  use trace <- endpoint.optional_header("X-Trace", schema.string())
  use ctx <- endpoint.handle
  let role = case role {
    Some(Admin) -> "admin"
    Some(Member) -> "member"
    None -> "any"
  }
  controller.text(
    ctx,
    string.join(
      [
        string.inspect(page),
        string.join(tags, ","),
        role,
        option.unwrap(trace, "-"),
      ],
      " ",
    ),
  )
}

fn create() -> Endpoint(Nil) {
  use <- endpoint.describe([
    endpoint.summary("Create a user"),
    endpoint.tag("People"),
    endpoint.security("bearer"),
    endpoint.response(201, "The new user", user()),
  ])
  use input <- endpoint.body(new_user())
  use ctx <- endpoint.handle
  User(id: 7, name: input.name, role: Member, nickname: None)
  |> schema.to_json(user())
  |> controller.json(ctx, _)
  |> controller.with_status(201)
}

fn users() -> controller.Controller {
  controller.new("user")
  |> endpoint.get("/search", search())
  |> endpoint.get("/:id", by_id())
  |> endpoint.post("/", create())
  |> controller.get("/plain", fn(ctx) { controller.text(ctx, "plain") })
}

fn app() -> howdy.App {
  howdy.new() |> howdy.controller(users())
}

fn spec() -> openapi.Spec {
  openapi.new(title: "Users", version: "1.0.0")
  |> openapi.bearer_auth("bearer")
}

fn document() -> decode.Dynamic {
  let text = json.to_string(openapi.document(spec(), app()))
  let assert Ok(data) = json.parse(text, decode.dynamic)
  data
}

/// The message of the panic `run` raises, or `Ok` with its result.
@external(erlang, "howdy_openapi_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, String)

fn ok(ctx: controller.Context) {
  controller.text(ctx, "ok")
}

fn document_of(
  spec: openapi.Spec,
  controller: controller.Controller,
) -> String {
  openapi.document(spec, howdy.new() |> howdy.controller(controller))
  |> json.to_string
}

fn at(
  data: decode.Dynamic,
  path: List(String),
  decoder: decode.Decoder(a),
) -> a {
  let assert Ok(value) = decode.run(data, decode.at(path, decoder))
  value
}

// -- Schemas -----------------------------------------------------------------

pub fn schema_round_trips_test() {
  let value = User(id: 1, name: "Ada", role: Admin, nickname: Some("ada"))
  let text = json.to_string(schema.to_json(value, user()))
  assert text
    == "{\"id\":1,\"name\":\"Ada\",\"role\":\"admin\",\"nickname\":\"ada\"}"
  assert json.parse(text, schema.decoder(user())) == Ok(value)
}

pub fn optional_field_is_left_out_test() {
  let value = User(id: 2, name: "Bo", role: Member, nickname: None)
  assert json.to_string(schema.to_json(value, user()))
    == "{\"id\":2,\"name\":\"Bo\",\"role\":\"member\"}"
  assert json.parse(
      "{\"id\":2,\"name\":\"Bo\",\"role\":\"member\",\"nickname\":null}",
      schema.decoder(user()),
    )
    == Ok(value)
}

pub fn rules_normalise_while_decoding_test() {
  let body = "{\"name\":\"  Ada \",\"email\":\"a@b.co\",\"age\":30,\"tags\":[]}"
  let assert Ok(input) = json.parse(body, schema.decoder(new_user()))
  assert input.name == "Ada"
}

pub fn map_changes_the_type_test() {
  let ids =
    schema.int() |> schema.map(to: fn(n) { #(n) }, from: fn(id) { id.0 })
  assert json.parse("5", schema.decoder(ids)) == Ok(#(5))
  assert json.to_string(schema.to_json(#(5), ids)) == "5"
}

pub fn dict_and_nullable_test() {
  let scores = schema.dict(schema.nullable(schema.int()))
  let assert Ok(value) =
    json.parse("{\"a\":1,\"b\":null}", schema.decoder(scores))
  assert value == dict.from_list([#("a", Some(1)), #("b", None)])
}

pub fn try_map_can_fail_test() {
  let switch =
    schema.string()
    |> schema.try_map(
      to: fn(text) {
        case text {
          "on" -> Ok(True)
          "off" -> Ok(False)
          _ -> Error("must be on or off")
        }
      },
      from: fn(on) {
        case on {
          True -> "on"
          False -> "off"
        }
      },
      placeholder: False,
    )
  assert json.parse("\"on\"", schema.decoder(switch)) == Ok(True)
  assert json.to_string(schema.to_json(False, switch)) == "\"off\""
  let assert Error(json.UnableToDecode([error])) =
    json.parse("\"maybe\"", schema.decoder(switch))
  assert error.expected == "must be on or off"

  // The message reaches the client, and the document keeps the string.
  let toggles =
    controller.new("toggle")
    |> endpoint.get("/", {
      use on <- endpoint.query("switch", switch)
      use ctx <- endpoint.handle
      controller.text(ctx, string.inspect(on))
    })
  let app = howdy.new() |> howdy.controller(toggles)
  let res =
    testing.get("/toggle")
    |> testing.query([#("switch", "maybe")])
    |> testing.send(app)
  assert res.status == 400
  assert testing.error(res) == Ok("query parameter switch must be on or off")
  assert string.contains(
    document_of(spec(), toggles),
    "{\"name\":\"switch\",\"in\":\"query\",\"required\":true,\"schema\":{\"type\":\"string\"}}",
  )
}

pub fn float_constraints_test() {
  let ratio =
    schema.float() |> schema.float_minimum(0.5) |> schema.float_maximum(9.5)
  assert json.parse("2.5", schema.decoder(ratio)) == Ok(2.5)
  let assert Error(json.UnableToDecode([error])) =
    json.parse("0.25", schema.decoder(ratio))
  assert schema.message(error) == "must be at least 0.5"
  let assert Error(json.UnableToDecode([error])) =
    json.parse("10", schema.decoder(ratio))
  assert schema.message(error) == "must be at most 9.5"

  let ratios =
    controller.new("ratio")
    |> endpoint.get("/", {
      use _ratio <- endpoint.query("ratio", ratio)
      use ctx <- endpoint.handle
      controller.text(ctx, "ok")
    })
  assert string.contains(
    document_of(spec(), ratios),
    "\"schema\":{\"type\":\"number\",\"minimum\":0.5,\"maximum\":9.5}",
  )
}

pub fn list_constraints_test() {
  let tags =
    schema.list(schema.string()) |> schema.min_items(1) |> schema.max_items(2)
  assert json.parse("[\"a\"]", schema.decoder(tags)) == Ok(["a"])
  let assert Error(json.UnableToDecode([error])) =
    json.parse("[]", schema.decoder(tags))
  assert schema.message(error) == "must have at least 1 item"
  let assert Error(json.UnableToDecode([error])) =
    json.parse("[\"a\",\"b\",\"c\"]", schema.decoder(tags))
  assert schema.message(error) == "must have at most 2 items"

  let tagged =
    controller.new("tagged")
    |> endpoint.get("/", {
      use _tags <- endpoint.query("tag", tags)
      use ctx <- endpoint.handle
      controller.text(ctx, "ok")
    })
  assert string.contains(
    document_of(spec(), tagged),
    "\"schema\":{\"type\":\"array\",\"minItems\":1,\"maxItems\":2,\"items\":{\"type\":\"string\"}}",
  )
}

pub type Shape {
  Circle(radius: Float)
  Square(side: Float)
}

fn circle() -> Schema(Float) {
  use radius <- schema.field("radius", schema.float(), fn(radius) { radius })
  schema.success(radius)
}

fn square() -> Schema(Float) {
  use side <- schema.field("side", schema.float(), fn(side) { side })
  schema.success(side)
}

fn shape() -> Schema(Shape) {
  schema.one_of(
    [schema.variant(circle(), Circle), schema.variant(square(), Square)],
    encode: fn(shape) {
      case shape {
        Circle(radius) -> schema.to_json(radius, circle())
        Square(side) -> schema.to_json(side, square())
      }
    },
  )
}

pub fn one_of_test() {
  assert json.parse("{\"radius\":1.5}", schema.decoder(shape()))
    == Ok(Circle(1.5))
  assert json.parse("{\"side\":2.0}", schema.decoder(shape()))
    == Ok(Square(2.0))
  assert json.to_string(schema.to_json(Square(2.0), shape()))
    == "{\"side\":2.0}"
  assert json.to_string(schema.to_json(Circle(1.5), shape()))
    == "{\"radius\":1.5}"
  // A body matching no variant reports the first variant's errors.
  let shapes =
    controller.new("shape")
    |> endpoint.post("/", {
      use shape <- endpoint.body(shape())
      use ctx <- endpoint.handle
      controller.text(ctx, string.inspect(shape))
    })
  let app = howdy.new() |> howdy.controller(shapes)
  let res =
    testing.post("/shape", json.object([#("side", json.float(2.0))]))
    |> testing.send(app)
  assert testing.text(res) == "Square(2.0)"
  let res = testing.post("/shape", json.object([])) |> testing.send(app)
  assert res.status == 422
  assert testing.field_errors(res)
    == Ok([service.FieldError("radius", problem.Required)])
  assert string.contains(
    document_of(spec(), shapes),
    "\"schema\":{\"anyOf\":[{\"type\":\"object\",\"properties\":{\"radius\":{\"type\":\"number\"}},\"required\":[\"radius\"]},{\"type\":\"object\",\"properties\":{\"side\":{\"type\":\"number\"}},\"required\":[\"side\"]}]}",
  )
}

pub fn example_format_and_deprecated_are_documented_test() {
  let day =
    schema.string()
    |> schema.format("date")
    |> schema.example("2024-01-31")
    |> schema.deprecated
  let days =
    controller.new("day")
    |> endpoint.get("/", {
      use <- endpoint.describe([endpoint.deprecated()])
      use _day <- endpoint.query("day", day)
      use _person <- endpoint.optional_query(
        "person",
        user() |> schema.description("Who asked"),
      )
      use ctx <- endpoint.handle
      controller.text(ctx, "ok")
    })
  let text = document_of(spec(), days)
  assert string.contains(
    text,
    "\"schema\":{\"type\":\"string\",\"format\":\"date\",\"examples\":[\"2024-01-31\"],\"deprecated\":true}",
  )
  // Keywords added after naming sit beside the reference.
  assert string.contains(
    text,
    "\"schema\":{\"$ref\":\"#/components/schemas/User\",\"description\":\"Who asked\"}",
  )
  assert string.contains(
    text,
    "\"responses\":{\"200\":{\"description\":\"Success\"}",
  )
  assert string.ends_with(
    text,
    "},\"deprecated\":true}}},\"components\":{\"schemas\":{\"User\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\"},\"name\":{\"type\":\"string\"},\"role\":{\"type\":\"string\",\"enum\":[\"admin\",\"member\"]},\"nickname\":{\"type\":\"string\"}},\"required\":[\"id\",\"name\",\"role\"]},\"FieldError\":{\"type\":\"object\",\"properties\":{\"field\":{\"type\":\"string\"},\"code\":{\"type\":\"string\"},\"message\":{\"type\":\"string\"},\"minimum\":{\"type\":\"integer\"},\"maximum\":{\"type\":\"integer\"},\"allowed\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}},\"required\":[\"field\",\"code\",\"message\"]},\"Error\":{\"type\":\"object\",\"properties\":{\"error\":{\"type\":\"string\"},\"code\":{\"type\":\"string\"},\"fields\":{\"type\":\"array\",\"items\":{\"$ref\":\"#/components/schemas/FieldError\"}}},\"required\":[\"error\",\"code\"]}},\"securitySchemes\":{\"bearer\":{\"type\":\"http\",\"scheme\":\"bearer\"}}}}",
  )
}

// -- Endpoints ---------------------------------------------------------------

pub fn path_parameter_test() {
  let res = testing.get("/user/1") |> testing.send(app())
  assert res.status == 200
  assert testing.text(res) == "{\"id\":1,\"name\":\"Ada\",\"role\":\"admin\"}"

  let res = testing.get("/user/abc") |> testing.send(app())
  assert res.status == 400
  assert testing.error(res) == Ok("parameter id must be an integer")

  let res = testing.get("/user/0") |> testing.send(app())
  assert res.status == 400
  assert testing.error(res) == Ok("parameter id must be at least 1")

  let res = testing.get("/user/2") |> testing.send(app())
  assert res.status == 404
}

pub fn query_and_header_parameters_test() {
  let res =
    testing.get("/user/search")
    |> testing.query([#("page", "2"), #("tag", "a"), #("tag", "b")])
    |> testing.header("x-trace", "t1")
    |> testing.send(app())
  assert testing.text(res) == "2 a,b any t1"

  let res =
    testing.get("/user/search")
    |> testing.query([#("page", "1"), #("role", "member")])
    |> testing.send(app())
  assert testing.text(res) == "1  member -"

  let res = testing.get("/user/search") |> testing.send(app())
  assert res.status == 400
  assert testing.error(res) == Ok("missing query parameter page")

  let res =
    testing.get("/user/search")
    |> testing.query([#("page", "1"), #("page", "2")])
    |> testing.send(app())
  assert testing.error(res) == Ok("query parameter page must occur only once")

  let res =
    testing.get("/user/search")
    |> testing.query([#("page", "1"), #("role", "owner")])
    |> testing.send(app())
  assert testing.error(res)
    == Ok("query parameter role must be one of admin, member")
}

pub fn body_is_decoded_and_checked_test() {
  let res =
    testing.post(
      "/user",
      json.object([
        #("name", json.string(" Ada ")),
        #("email", json.string("ada@example.com")),
        #("age", json.int(30)),
        #("tags", json.array([], json.string)),
      ]),
    )
    |> testing.send(app())
  assert res.status == 201
  assert testing.text(res) == "{\"id\":7,\"name\":\"Ada\",\"role\":\"member\"}"
}

pub fn body_errors_are_field_errors_test() {
  let res =
    testing.post(
      "/user",
      json.object([
        #("name", json.string("   ")),
        #("email", json.string("nope")),
        #("age", json.string("old")),
        #("tags", json.array([json.int(1)], fn(x) { x })),
      ]),
    )
    |> testing.send(app())
  assert res.status == 422
  assert testing.field_errors(res)
    == Ok([
      service.FieldError("name", problem.Blank),
      service.FieldError("email", problem.NotEmail),
      service.FieldError("age", problem.NotInteger),
      service.FieldError("tags.0", problem.Custom("type", "must be a string")),
    ])

  let res = testing.post("/user", json.object([])) |> testing.send(app())
  let assert Ok([service.FieldError("name", problem.Required), ..]) =
    testing.field_errors(res)

  let res = testing.post("/user", json.string("hi")) |> testing.send(app())
  assert testing.field_errors(res)
    == Ok([
      service.FieldError("body", problem.Custom("type", "must be an object")),
    ])

  let res =
    testing.request(http.Post, "/user")
    |> testing.text_body("{nope")
    |> testing.send(app())
  assert res.status == 400
  assert testing.error(res) == Ok("request body is not valid JSON")
}

pub fn required_header_test() {
  let tenants =
    controller.new("tenant")
    |> endpoint.get("/", {
      use tenant <- endpoint.header("X-Tenant", schema.string())
      use ctx <- endpoint.handle
      controller.text(ctx, tenant)
    })
  let app = howdy.new() |> howdy.controller(tenants)
  let res =
    testing.get("/tenant")
    |> testing.header("x-tenant", "acme")
    |> testing.send(app)
  assert testing.text(res) == "acme"

  let res = testing.get("/tenant") |> testing.send(app)
  assert res.status == 400
  assert testing.error(res) == Ok("missing header x-tenant")

  assert string.contains(
    document_of(spec(), tenants),
    "\"parameters\":[{\"name\":\"x-tenant\",\"in\":\"header\",\"required\":true,\"schema\":{\"type\":\"string\"}}]",
  )
}

pub fn body_with_limit_rejects_a_large_body_test() {
  let app =
    howdy.new()
    |> howdy.controller(
      controller.new("note")
      |> endpoint.post("/", {
        use text <- endpoint.body_with_limit(schema.string(), 8)
        use ctx <- endpoint.handle
        controller.text(ctx, text)
      }),
    )
  let res = testing.post("/note", json.string("hi")) |> testing.send(app)
  assert testing.text(res) == "hi"

  let res =
    testing.post("/note", json.string("far too long"))
    |> testing.send(app)
  assert res.status == 400
  assert testing.error(res) == Ok("request body too large")
}

pub fn wrap_runs_middleware_around_the_endpoint_test() {
  let stamp = fn(ctx, next) {
    next(ctx) |> response.set_header("x-wrapped", "yes")
  }
  let app =
    howdy.new()
    |> howdy.controller(
      controller.new("user")
      |> endpoint.get("/:id", by_id() |> endpoint.wrap(stamp)),
    )
  let res = testing.get("/user/1") |> testing.send(app)
  assert response.get_header(res, "x-wrapped") == Ok("yes")
  assert testing.text(res) == "{\"id\":1,\"name\":\"Ada\",\"role\":\"admin\"}"
  // Errors from the inputs pass through the middleware too.
  let res = testing.get("/user/abc") |> testing.send(app)
  assert res.status == 400
  assert response.get_header(res, "x-wrapped") == Ok("yes")
}

pub fn wrap_keeps_the_guard_test() {
  let stamp = fn(ctx, next) {
    next(ctx) |> response.set_header("x-wrapped", "yes")
  }
  let mine = {
    use ctx: controller.GuardedContext(String) <- endpoint.handle
    controller.text(ctx, ctx.guard)
  }
  let app =
    howdy.new()
    |> howdy.controller(
      controller.guarded("/me", fn(_ctx) { Ok("Ada") })
      |> endpoint.get("/", mine |> endpoint.wrap(stamp))
      |> controller.build,
    )
  let res = testing.get("/me") |> testing.send(app)
  assert response.get_header(res, "x-wrapped") == Ok("yes")
  assert testing.text(res) == "Ada"
}

// -- The document ------------------------------------------------------------

pub fn spec_details_are_documented_test() {
  let spec =
    openapi.new(title: "Users", version: "1.0.0")
    |> openapi.server("https://api.example.com")
    |> openapi.server("https://staging.example.com")
    |> openapi.api_key_cookie("session", cookie: "sid")
    |> openapi.require("session")
  assert json.to_string(openapi.document(spec, howdy.new()))
    == "{\"openapi\":\"3.1.0\",\"info\":{\"title\":\"Users\",\"version\":\"1.0.0\"},\"servers\":[{\"url\":\"https://api.example.com\"},{\"url\":\"https://staging.example.com\"}],\"security\":[{\"session\":[]}],\"paths\":{},\"components\":{\"securitySchemes\":{\"session\":{\"type\":\"apiKey\",\"in\":\"cookie\",\"name\":\"sid\"}}}}"
}

pub fn duplicate_operation_ids_panic_test() {
  let find = fn() {
    use <- endpoint.describe([endpoint.operation_id("find")])
    use ctx <- endpoint.handle
    ok(ctx)
  }
  let users =
    controller.new("user")
    |> endpoint.get("/a", find())
    |> endpoint.get("/b", find())
  assert rescue(fn() { document_of(spec(), users) })
    == Error(
      "howdy/openapi: GET /user/a and GET /user/b both have the operation id find; give one its own with endpoint.operation_id",
    )
}

pub fn duplicate_schema_names_panic_test() {
  let reply = fn(schema: Schema(String)) {
    use <- endpoint.describe([endpoint.response(200, "A thing", schema)])
    use ctx <- endpoint.handle
    ok(ctx)
  }
  let things =
    controller.new("thing")
    |> endpoint.get("/a", reply(schema.string() |> schema.named("Thing")))
    |> endpoint.get(
      "/b",
      reply(schema.string() |> schema.max_length(3) |> schema.named("Thing")),
    )
  assert rescue(fn() { document_of(spec(), things) })
    == Error("howdy/openapi: two different schemas are named Thing")
  // The same schema under one name is fine.
  let same =
    controller.new("thing")
    |> endpoint.get("/a", reply(schema.string() |> schema.named("Thing")))
    |> endpoint.get("/b", reply(schema.string() |> schema.named("Thing")))
  let assert Ok(_) = rescue(fn() { document_of(spec(), same) })
}

pub fn undeclared_path_parameters_panic_test() {
  let users =
    controller.new("user")
    |> endpoint.get("/", {
      use _id <- endpoint.path("id", schema.int())
      use ctx <- endpoint.handle
      ok(ctx)
    })
  assert rescue(fn() { document_of(spec(), users) })
    == Error(
      "howdy/openapi: GET /user reads path parameter id, which its route does not capture",
    )
}

pub fn document_lists_only_endpoints_test() {
  let doc = document()
  assert at(doc, ["openapi"], decode.string) == "3.1.0"
  assert at(doc, ["info", "title"], decode.string) == "Users"
  let paths = at(doc, ["paths"], decode.dict(decode.string, decode.dynamic))
  assert dict.keys(paths) |> list.sort(string.compare)
    == ["/user", "/user/search", "/user/{id}"]
}

pub fn document_describes_path_parameters_and_responses_test() {
  let doc = document()
  let op = at(doc, ["paths", "/user/{id}", "get"], decode.dynamic)
  assert at(op, ["summary"], decode.string) == "Find a user"
  assert at(op, ["tags"], decode.list(decode.string)) == ["user"]
  assert at(op, ["operationId"], decode.string) == "get_user_by_id"
  let assert Ok([param]) =
    decode.run(op, decode.at(["parameters"], decode.list(decode.dynamic)))
  assert at(param, ["in"], decode.string) == "path"
  assert at(param, ["schema", "minimum"], decode.int) == 1
  assert at(
      op,
      ["responses", "200", "content", "application/json", "schema", "$ref"],
      decode.string,
    )
    == "#/components/schemas/User"
  assert at(
      op,
      ["responses", "404", "content", "application/json", "schema", "$ref"],
      decode.string,
    )
    == "#/components/schemas/Error"
  assert at(op, ["responses", "400", "description"], decode.string)
    == "The request is malformed"
}

pub fn document_describes_bodies_test() {
  let doc = document()
  let op = at(doc, ["paths", "/user", "post"], decode.dynamic)
  assert at(op, ["tags"], decode.list(decode.string)) == ["People"]
  assert at(
      op,
      ["security"],
      decode.list(decode.dict(decode.string, decode.list(decode.string))),
    )
    == [dict.from_list([#("bearer", [])])]
  let body =
    at(
      op,
      ["requestBody", "content", "application/json", "schema"],
      decode.dynamic,
    )
  assert at(body, ["required"], decode.list(decode.string))
    == ["name", "email", "age", "tags"]
  assert at(body, ["properties", "name", "maxLength"], decode.int) == 50
  assert at(body, ["properties", "email", "format"], decode.string) == "email"
  assert at(body, ["properties", "tags", "items", "type"], decode.string)
    == "string"
  assert at(op, ["responses", "422", "description"], decode.string)
    == "The request body failed validation"
}

pub fn document_describes_query_parameters_test() {
  let doc = document()
  let params =
    at(
      doc,
      ["paths", "/user/search", "get", "parameters"],
      decode.list({
        use name <- decode.field("name", decode.string)
        use location <- decode.field("in", decode.string)
        use required <- decode.field("required", decode.bool)
        decode.success(#(name, location, required))
      }),
    )
  assert params
    == [
      #("page", "query", True),
      #("tag", "query", False),
      #("role", "query", False),
      #("x-trace", "header", False),
    ]
}

pub fn document_collects_components_test() {
  let doc = document()
  let user = at(doc, ["components", "schemas", "User"], decode.dynamic)
  assert at(user, ["required"], decode.list(decode.string))
    == ["id", "name", "role"]
  assert at(user, ["properties", "role", "enum"], decode.list(decode.string))
    == ["admin", "member"]
  assert at(
      doc,
      [
        "components",
        "schemas",
        "Error",
        "properties",
        "fields",
        "items",
        "$ref",
      ],
      decode.string,
    )
    == "#/components/schemas/FieldError"
  assert at(
      doc,
      ["components", "securitySchemes", "bearer", "scheme"],
      decode.string,
    )
    == "bearer"
}

pub fn undeclared_path_parameters_are_strings_test() {
  let files =
    controller.new("org/:org")
    |> endpoint.get("/files/*path", {
      use ctx <- endpoint.handle
      controller.text(ctx, "ok")
    })
  let text =
    openapi.document(spec(), howdy.new() |> howdy.controller(files))
    |> json.to_string
  assert string.contains(text, "\"/org/{org}/files/{path}\"")
  assert string.contains(
    text,
    "{\"name\":\"org\",\"in\":\"path\",\"required\":true,\"schema\":{\"type\":\"string\"}}",
  )
}

pub fn serve_and_reference_test() {
  let app =
    app()
    |> openapi.serve(spec(), at: "/openapi.json")
    |> openapi.reference(at: "/docs", document: "/openapi.json")
  let res = testing.get("/openapi.json") |> testing.send(app)
  assert res.status == 200
  assert string.contains(testing.text(res), "\"openapi\":\"3.1.0\"")
  // The document's own route is not in the document.
  assert !string.contains(testing.text(res), "/openapi.json")

  let res = testing.get("/docs") |> testing.send(app)
  assert string.contains(testing.text(res), "{\"url\":\"/openapi.json\"}")
}

// -- Versions ----------------------------------------------------------------

fn listing(label: String) -> Endpoint(Nil) {
  use <- endpoint.describe([
    endpoint.summary(label),
    endpoint.response(200, "The users", schema.list(schema.string())),
  ])
  use ctx <- endpoint.handle
  controller.text(ctx, label)
}

fn versioned_app(resolver: version.Resolver) -> howdy.App {
  let health =
    controller.new("health")
    |> endpoint.get("/", listing("health"))
  let v1 =
    controller.new("users")
    |> endpoint.get("/", listing("v1 list"))
    |> endpoint.get("/:id", by_id())
  let v2 =
    controller.new("users")
    |> endpoint.get("/", listing("v2 list"))
  let group =
    version.new(resolver)
    |> version.default("v1")
    |> version.add("v1", [v1])
    |> version.add("v2", [v2])
  howdy.new()
  |> howdy.controller(health)
  |> howdy.versions(group)
}

fn version_doc(app: howdy.App, name: String) -> decode.Dynamic {
  let assert Ok(document) = openapi.version_document(spec(), app, name)
  let assert Ok(data) = json.parse(json.to_string(document), decode.dynamic)
  data
}

fn path_keys(doc: decode.Dynamic) -> List(String) {
  at(doc, ["paths"], decode.dict(decode.string, decode.dynamic))
  |> dict.keys
  |> list.sort(string.compare)
}

pub fn path_versions_are_prefixed_test() {
  let app = versioned_app(version.path())
  assert openapi.versions(app) == ["v1", "v2"]

  let v2 = version_doc(app, "v2")
  // The spec's version is kept, with the version's name beside it.
  assert at(v2, ["info", "version"], decode.string) == "1.0.0 (v2)"
  // v2 overrides the list and falls back to v1 for the rest; unversioned
  // routes answer in every version, unprefixed.
  assert path_keys(v2) == ["/health", "/v2/users", "/v2/users/{id}"]
  assert at(v2, ["paths", "/v2/users", "get", "summary"], decode.string)
    == "v2 list"
  assert at(v2, ["paths", "/v2/users/{id}", "get", "summary"], decode.string)
    == "Find a user"
  // Tags and ids come from the route, not the version prefix.
  assert at(v2, ["paths", "/v2/users", "get", "operationId"], decode.string)
    == "get_users"

  let v1 = version_doc(app, "v1")
  assert at(v1, ["paths", "/v1/users", "get", "summary"], decode.string)
    == "v1 list"
  assert openapi.version_document(spec(), app, "v3") == Error(Nil)
}

pub fn no_fallback_leaves_out_earlier_versions_test() {
  let app =
    howdy.new()
    |> howdy.versions(
      version.new(version.path())
      |> version.no_fallback
      |> version.add("v1", [
        controller.new("a") |> endpoint.get("/", listing("a")),
      ])
      |> version.add("v2", [
        controller.new("b") |> endpoint.get("/", listing("b")),
      ]),
    )
  assert path_keys(version_doc(app, "v2")) == ["/v2/b"]
}

pub fn header_versions_take_the_header_test() {
  let app = versioned_app(version.header("X-API-Version"))
  let parameter = fn(doc, path) {
    let assert [first, ..] =
      at(
        doc,
        ["paths", path, "get", "parameters"],
        decode.list({
          use name <- decode.field("name", decode.string)
          use location <- decode.field("in", decode.string)
          use required <- decode.field("required", decode.bool)
          use values <- decode.subfield(
            ["schema", "enum"],
            decode.list(decode.string),
          )
          decode.success(#(name, location, required, values))
        }),
      )
    first
  }
  let v2 = version_doc(app, "v2")
  assert path_keys(v2) == ["/health", "/users", "/users/{id}"]
  assert parameter(v2, "/users") == #("x-api-version", "header", True, ["v2"])
  // An unknown version is a 400.
  assert at(
      v2,
      ["paths", "/users", "get", "responses", "400", "description"],
      decode.string,
    )
    == "The request is malformed"
  // The default version may be asked for without the header.
  assert parameter(version_doc(app, "v1"), "/users")
    == #("x-api-version", "header", False, ["v1"])
  // Unversioned routes do not take it.
  let assert Error(_) =
    decode.run(
      v2,
      decode.at(["paths", "/health", "get", "parameters"], decode.dynamic),
    )
}

pub fn accept_versions_have_vendor_media_types_test() {
  let app = versioned_app(version.accept("vnd.howdy"))
  let v2 = version_doc(app, "v2")
  let content =
    at(
      v2,
      ["paths", "/users", "get", "responses", "200", "content"],
      decode.dict(decode.string, decode.dynamic),
    )
  assert dict.keys(content) == ["application/vnd.howdy.v2+json"]
  let health =
    at(
      v2,
      ["paths", "/health", "get", "responses", "200", "content"],
      decode.dict(decode.string, decode.dynamic),
    )
  assert dict.keys(health) == ["application/json"]
}

pub fn custom_versions_are_documented_as_they_are_test() {
  let app = versioned_app(version.custom(fn(_) { Some("v2") }))
  let v2 = version_doc(app, "v2")
  assert at(v2, ["info", "version"], decode.string) == "1.0.0 (v2)"
  assert path_keys(v2) == ["/health", "/users", "/users/{id}"]
  // Nothing can be said about how the version is chosen: no prefix, no
  // header and plain JSON.
  let assert Error(_) =
    decode.run(
      v2,
      decode.at(["paths", "/users", "get", "parameters"], decode.dynamic),
    )
  let content =
    at(
      v2,
      ["paths", "/users", "get", "responses", "200", "content"],
      decode.dict(decode.string, decode.dynamic),
    )
  assert dict.keys(content) == ["application/json"]
}

pub fn serve_serves_every_version_test() {
  let app =
    versioned_app(version.path())
    |> openapi.serve(spec(), at: "/openapi.json")
    |> openapi.reference(at: "/docs", document: "/openapi.json")
  let version_of = fn(path) {
    let res = testing.get(path) |> testing.send(app)
    assert res.status == 200
    let assert Ok(name) =
      json.parse(
        testing.text(res),
        decode.at(["info", "version"], decode.string),
      )
    name
  }
  // The main document is the default version's.
  assert version_of("/openapi.json") == "1.0.0 (v1)"
  assert version_of("/openapi/v1.json") == "1.0.0 (v1)"
  assert version_of("/openapi/v2.json") == "1.0.0 (v2)"

  let page = testing.get("/docs") |> testing.send(app) |> testing.text
  assert string.contains(
    page,
    "{\"title\":\"v1\",\"slug\":\"v1\",\"url\":\"/openapi/v1.json\",\"default\":true}",
  )
  assert string.contains(page, "\"url\":\"/openapi/v2.json\",\"default\":false")
}

pub fn main_document_is_the_newest_without_a_default_test() {
  let app =
    howdy.new()
    |> howdy.versions(
      version.new(version.header("x-v"))
      |> version.add("v1", [
        controller.new("a") |> endpoint.get("/", listing("a")),
      ])
      |> version.add("v2", [
        controller.new("b") |> endpoint.get("/", listing("b")),
      ]),
    )
  let text = json.to_string(openapi.document(spec(), app))
  assert string.contains(text, "\"version\":\"1.0.0 (v2)\"")
}

pub fn served_lists_the_documents_test() {
  assert openapi.served(app()) == []
  let single = app() |> openapi.serve(spec(), at: "/openapi.json")
  let assert [
    openapi.Served(path: "/openapi.json", version: None, main: True, document:),
  ] = openapi.served(single)
  assert string.contains(document, "\"openapi\":\"3.1.0\"")

  let versioned =
    versioned_app(version.path()) |> openapi.serve(spec(), at: "/openapi.json")
  let found =
    openapi.served(versioned)
    |> list.map(fn(served) { #(served.path, served.version, served.main) })
  assert found
    == [
      #("/openapi.json", Some("v1"), True),
      #("/openapi/v1.json", Some("v1"), False),
      #("/openapi/v2.json", Some("v2"), False),
    ]
}
