//// The API pages: finding the OpenAPI documents an app serves, and calling
//// its endpoints through the app, anonymously and as a signed-in user.

import gleam/http/request
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/uri
import gloo/adapter/sqlite
import gloo/repo
import howdy
import howdy/admin
import howdy/admin/internal/api_spec
import howdy/auth
import howdy/auth/secret
import howdy/auth/user.{type Principal}
import howdy/controller
import howdy/database
import howdy/migration
import howdy/openapi
import howdy/openapi/endpoint.{type Endpoint}
import howdy/openapi/schema.{type Schema}
import howdy/service
import howdy/testing
import howdy/version

// -- Fixtures ----------------------------------------------------------------

pub type Note {
  Note(id: Int, title: String)
}

fn note() -> Schema(Note) {
  {
    use id <- schema.field("id", schema.int(), fn(note: Note) { note.id })
    use title <- schema.field(
      "title",
      schema.string() |> schema.not_empty,
      fn(note: Note) { note.title },
    )
    schema.success(Note(id:, title:))
  }
  |> schema.named("Note")
}

fn find() -> Endpoint(Nil) {
  use <- endpoint.describe([
    endpoint.summary("Find a note"),
    endpoint.response(200, "The note", note()),
  ])
  use id <- endpoint.path("id", schema.int())
  use ctx <- endpoint.handle
  Ok(Note(id:, title: "Note " <> string.inspect(id)))
  |> service.respond(ctx, schema.to_json(_, note()))
}

fn create() -> Endpoint(Nil) {
  use <- endpoint.describe([
    endpoint.summary("Create a note"),
    endpoint.response(201, "The note", note()),
  ])
  use input <- endpoint.body(note())
  use ctx <- endpoint.handle
  Ok(input) |> service.created(ctx, schema.to_json(_, note()))
}

fn mine() -> Endpoint(Principal) {
  use <- endpoint.describe([
    endpoint.summary("Who am I"),
    endpoint.security("session"),
    endpoint.response(200, "Your email address", schema.string()),
    endpoint.error(401, "Not signed in"),
  ])
  use ctx: controller.GuardedContext(Principal) <- endpoint.handle
  controller.json(ctx, schema.to_json(ctx.guard.user.email, schema.string()))
}

fn spec() -> openapi.Spec {
  openapi.new(title: "Notes", version: "1.0.0")
  |> openapi.bearer_auth("session")
}

fn api_app(identity: auth.Auth) -> howdy.App {
  let notes =
    controller.new("notes")
    |> endpoint.get("/:id", find())
    |> endpoint.post("/", create())
  let me =
    controller.guarded("me", auth.required(identity))
    |> endpoint.get("/", mine())
    |> controller.build
  howdy.new()
  |> howdy.controller(notes)
  |> howdy.controller(me)
  |> openapi.serve(spec(), at: "/openapi.json")
  |> admin.mount(admin.new() |> admin.auth(identity))
}

fn with_identity(run: fn(auth.Auth) -> a) -> a {
  let assert Ok(db) = sqlite.start(sqlite.memory())
  let assert Ok(Nil) = database.sqlite_defaults(db)
  let assert Ok(Nil) = migration.run(db, [auth.schema()])
  let assert Ok(identity) =
    auth.new_without_email(repo: db, origin: "http://localhost:8787")
  let value = run(identity)
  let assert Ok(_) = repo.close(db)
  value
}

fn get(app: howdy.App, path: String) -> String {
  let res =
    testing.get(path) |> request.set_host("localhost") |> testing.send(app)
  assert res.status == 200
    as { "GET " <> path <> " gave " <> string.inspect(res.status) }
  testing.text(res)
}

fn operation(version: String, method: String, path: String) -> String {
  "/_howdy/api/operation?"
  <> uri.query_to_string([
    #("version", version),
    #("method", method),
    #("path", path),
  ])
}

fn call(app: howdy.App, at: String, fields: List(#(String, String))) -> String {
  let res =
    testing.post_form(at, fields)
    |> request.set_host("localhost")
    |> testing.header("sec-fetch-site", "same-origin")
    |> testing.send(app)
  assert res.status == 200
  testing.text(res)
}

fn new_user(app: howdy.App, email: String) -> String {
  let res =
    testing.post_form("/_howdy/users", [#("email", email)])
    |> request.set_host("localhost")
    |> testing.header("sec-fetch-site", "same-origin")
    |> testing.send(app)
  let assert Ok("/_howdy/users/" <> id) = list.key_find(res.headers, "location")
  id
}

// -- Detection ---------------------------------------------------------------

pub fn nothing_is_shown_without_a_document_test() {
  let app = howdy.new() |> admin.mount(admin.new())
  let page = get(app, "/_howdy")
  assert string.contains(page, "No OpenAPI document found")
  assert !string.contains(page, "/_howdy/api")
  let res =
    testing.get("/_howdy/api")
    |> request.set_host("localhost")
    |> testing.send(app)
  assert res.status == 404
}

pub fn finds_the_document_the_app_serves_test() {
  use identity <- with_identity
  let app = api_app(identity)
  let overview = get(app, "/_howdy")
  assert string.contains(overview, "3 endpoints")
  assert string.contains(overview, "href=\"/_howdy/api\"")

  let page = get(app, "/_howdy/api")
  assert string.contains(page, "Notes")
  assert string.contains(page, "/notes/{id}")
  assert string.contains(page, "Create a note")
  assert string.contains(page, "needs session")
}

pub fn the_operation_page_offers_a_form_test() {
  use identity <- with_identity
  let app = api_app(identity)
  let page = get(app, operation("", "post", "/notes"))
  assert string.contains(page, "Try it")
  // An example body, made from the schema.
  assert string.contains(page, "&quot;title&quot;: &quot;string&quot;")
  assert string.contains(page, "Send as")
  // The Note schema's fields, from the responses.
  assert string.contains(page, "at least 1 character")
}

// -- Calling -----------------------------------------------------------------

pub fn calls_an_endpoint_through_the_app_test() {
  use identity <- with_identity
  let app = api_app(identity)
  let page =
    call(app, operation("", "get", "/notes/{id}"), [
      #("as", ""),
      #("path:id", "7"),
    ])
  assert string.contains(page, "Note 7")
  assert string.contains(page, "anonymously")
  assert string.contains(page, "curl -X GET &#39;http://localhost/notes/7&#39;")

  // The app's own validation answers, as it would anyone.
  let page =
    call(app, operation("", "post", "/notes"), [
      #("as", ""),
      #("body", "{\"id\": 1, \"title\": \"\"}"),
    ])
  assert string.contains(page, ">422<")
  assert string.contains(page, "must not be empty")
}

pub fn calls_a_guarded_endpoint_as_a_user_test() {
  use identity <- with_identity
  let app = api_app(identity)
  let id = new_user(app, "ada@example.com")
  let at = operation("", "get", "/me")

  let page = call(app, at, [#("as", "")])
  assert string.contains(page, ">401<")

  let page = call(app, at, [#("as", id)])
  assert string.contains(page, ">200<")
  assert string.contains(page, "&quot;ada@example.com&quot;")
  assert string.contains(page, "as ada@example.com")

  // The session is kept for the next call rather than opening another.
  let _ = call(app, at, [#("as", id)])
  let assert Ok(sessions) = auth.sessions_of(identity, id)
  assert list.length(sessions) == 1

  // Revoked behind the admin's back, the kept token gets 401: it is
  // forgotten, a fresh session opened, and the call sent again with that,
  // so the page shows 200 rather than the 401.
  let assert Ok(stale) = cached_token(identity, id)
  let assert [session] = sessions
  let assert Ok(Nil) =
    auth.revoke_session_of(identity, id, session.id, by: user.System)
  let page = call(app, at, [#("as", id)])
  assert string.contains(page, ">200<")
  assert string.contains(page, "as ada@example.com")
  let assert Ok(fresh) = cached_token(identity, id)
  assert fresh != stale
  let assert Ok([replacement]) = auth.sessions_of(identity, id)
  assert replacement.id != session.id
  // The fresh token is the one kept for the call after that.
  let _ = call(app, at, [#("as", id)])
  assert cached_token(identity, id) == Ok(fresh)
  let assert Ok([_]) = auth.sessions_of(identity, id)
}

@external(erlang, "howdy_admin_ffi", "cached_token")
fn cached_token(identity: auth.Auth, user_id: String) -> Result(String, Nil)

pub fn revoking_through_the_admin_drops_the_kept_token_test() {
  use identity <- with_identity
  let identity = auth.with_account_deletion(identity, fn(_, _) { Ok(Nil) })
  let app = api_app(identity)
  let id = new_user(app, "ada@example.com")
  let at = operation("", "get", "/me")
  let page = call(app, at, [#("as", id)])
  assert string.contains(page, ">200<")
  let assert Ok(token) = cached_token(identity, id)

  // Another auth over the same users never sees this one's token.
  let assert Ok(other) =
    auth.new_without_email(
      repo: auth.repo(identity),
      origin: "http://127.0.0.1:1",
    )
  assert cached_token(other, id) == Error(Nil)

  // Signing the user out everywhere forgets the token straight away.
  let res =
    testing.post_form("/_howdy/users/" <> id <> "/revoke", [])
    |> request.set_host("localhost")
    |> testing.header("sec-fetch-site", "same-origin")
    |> testing.send(app)
  assert res.status == 303
  assert cached_token(identity, id) == Error(Nil)
  let assert Ok([]) = auth.sessions_of(identity, id)

  // The next call opens a new session rather than sending the old token.
  let page = call(app, at, [#("as", id)])
  assert string.contains(page, ">200<")
  let assert Ok(fresh) = cached_token(identity, id)
  assert fresh != token
  let assert Ok([_]) = auth.sessions_of(identity, id)

  // So does revoking one session, and deleting the user.
  let assert Ok([session]) = auth.sessions_of(identity, id)
  let res =
    testing.post_form("/_howdy/users/" <> id <> "/sessions/revoke", [
      #("session", session.id),
    ])
    |> request.set_host("localhost")
    |> testing.header("sec-fetch-site", "same-origin")
    |> testing.send(app)
  assert res.status == 303
  assert cached_token(identity, id) == Error(Nil)
  let _ = call(app, at, [#("as", id)])
  let assert Ok(_) = cached_token(identity, id)
  let res =
    testing.post_form("/_howdy/users/" <> id <> "/delete", [
      #("confirm", "ada@example.com"),
    ])
    |> request.set_host("localhost")
    |> testing.header("sec-fetch-site", "same-origin")
    |> testing.send(app)
  assert res.status == 303
  assert cached_token(identity, id) == Error(Nil)
}

pub fn sends_a_typed_bearer_token_test() {
  use identity <- with_identity
  let app = api_app(identity)
  let id = new_user(app, "grace@example.com")
  let assert Ok(session) = auth.impersonate(identity, id, by: user.System)
  let token = secret.reveal(session.token)
  let page =
    call(app, operation("", "get", "/me"), [
      #("as", ""),
      #("scheme:session", token),
    ])
  assert string.contains(page, "&quot;grace@example.com&quot;")
}

// -- Versions ----------------------------------------------------------------

pub fn offers_each_version_test() {
  use identity <- with_identity
  let v1 = controller.new("notes") |> endpoint.get("/:id", find())
  let v2 =
    controller.new("notes")
    |> endpoint.post("/", create())
  let app =
    howdy.new()
    |> howdy.versions(
      version.new(version.header("x-api-version"))
      |> version.default("v1")
      |> version.add("v1", [v1])
      |> version.add("v2", [v2]),
    )
    |> openapi.serve(spec(), at: "/openapi.json")
    |> admin.mount(admin.new() |> admin.auth(identity))

  let index = get(app, "/_howdy/api")
  assert string.contains(index, "href=\"/_howdy/api?version=v2\"")
  let v2_index = get(app, "/_howdy/api?version=v2")
  assert string.contains(v2_index, "Create a note")
  // v2 falls back to v1 for finding a note.
  assert string.contains(v2_index, "/notes/{id}")

  // The version header starts filled in, so the call reaches v2.
  let at = operation("v2", "get", "/notes/{id}")
  let page = get(app, at)
  assert string.contains(page, "value=\"v2\"")
  let page =
    call(app, at, [
      #("as", ""),
      #("header:x-api-version", "v2"),
      #("path:id", "3"),
    ])
  assert string.contains(page, "Note 3")
}

// -- Samples -----------------------------------------------------------------

const sample_document = "{
  \"openapi\": \"3.1.0\",
  \"info\": {\"title\": \"Samples\", \"version\": \"1\"},
  \"paths\": {
    \"/orders\": {
      \"post\": {
        \"requestBody\": {\"content\": {\"application/json\": {
          \"schema\": {\"$ref\": \"#/components/schemas/Order\"}
        }}},
        \"responses\": {\"201\": {\"description\": \"Made\"}}
      }
    }
  },
  \"components\": {\"schemas\": {
    \"Order\": {
      \"type\": \"object\",
      \"properties\": {
        \"id\": {\"type\": \"string\", \"format\": \"uuid\"},
        \"email\": {\"type\": \"string\", \"format\": \"email\"},
        \"placed\": {\"type\": \"string\", \"format\": \"date-time\"},
        \"day\": {\"type\": \"string\", \"format\": \"date\"},
        \"note\": {\"type\": \"string\", \"examples\": [\"gift wrap\"]},
        \"status\": {\"type\": \"string\", \"enum\": [\"open\", \"paid\"]},
        \"quantity\": {\"type\": \"integer\", \"minimum\": 1},
        \"count\": {\"type\": \"integer\"},
        \"total\": {\"type\": \"number\"},
        \"rush\": {\"type\": \"boolean\"},
        \"coupon\": {\"anyOf\": [{\"type\": \"null\"}, {\"type\": \"string\"}]},
        \"lines\": {\"type\": \"array\", \"items\": {\"$ref\": \"#/components/schemas/Line\"}},
        \"tags\": {\"type\": \"array\"},
        \"parent\": {\"$ref\": \"#/components/schemas/Order\"},
        \"anything\": {}
      }
    },
    \"Line\": {
      \"type\": \"object\",
      \"properties\": {\"sku\": {\"type\": \"string\"}}
    }
  }}
}"

pub fn a_sample_body_is_made_from_the_schema_test() {
  let assert Ok(document) = api_spec.parse(sample_document)
  let assert [operation] = document.operations
  let assert Some(schema) = operation.body
  let assert api_spec.Object(fields) = api_spec.example(document, schema)
  let field = fn(name) { list.key_find(fields, name) }
  // Formats, an example given, the first enum value, the minimum, and the
  // plain kinds.
  assert field("id")
    == Ok(api_spec.String("00000000-0000-0000-0000-000000000000"))
  assert field("email") == Ok(api_spec.String("user@example.com"))
  assert field("placed") == Ok(api_spec.String("2026-01-01T00:00:00Z"))
  assert field("day") == Ok(api_spec.String("2026-01-01"))
  assert field("note") == Ok(api_spec.String("gift wrap"))
  assert field("status") == Ok(api_spec.String("open"))
  assert field("quantity") == Ok(api_spec.Int(1))
  assert field("count") == Ok(api_spec.Int(0))
  assert field("total") == Ok(api_spec.Float(0.0))
  assert field("rush") == Ok(api_spec.Bool(False))
  // anyOf picks the first non-null option; an untyped schema is null.
  assert field("coupon") == Ok(api_spec.String("string"))
  assert field("anything") == Ok(api_spec.Null)
  // Arrays hold one sample item, or nothing without a schema for them.
  assert field("lines")
    == Ok(
      api_spec.Array([api_spec.Object([#("sku", api_spec.String("string"))])]),
    )
  assert field("tags") == Ok(api_spec.Array([]))
  // A schema that refers to itself is followed a few levels, then given
  // up on with null rather than recursing forever.
  let assert Ok(parent) = field("parent")
  assert ancestors(parent, 0) > 1
  assert string.contains(
    api_spec.pretty(api_spec.example(document, schema)),
    "\"sku\": \"string\"",
  )
}

/// How many nested `parent` objects `value` holds before ending in null.
fn ancestors(value: api_spec.Value, depth: Int) -> Int {
  case value {
    api_spec.Object(fields) ->
      case list.key_find(fields, "parent") {
        Ok(inner) -> ancestors(inner, depth + 1)
        Error(Nil) -> panic as "an Order sample always has a parent"
      }
    api_spec.Null -> depth
    _ -> panic as "a parent is an object or null"
  }
}
