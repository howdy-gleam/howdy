import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{None, Some}
import howdy
import howdy/content.{type Content}
import howdy/context.{type Body}
import howdy/controller.{type Context}
import howdy/testing
import howdy/version.{type Group}

fn users_v1() -> controller.Controller {
  controller.new("users")
  |> controller.get("/", fn(ctx: Context) {
    controller.text(ctx, "v1 users " <> ctx.request.path)
  })
  |> controller.post("/", fn(ctx: Context) { controller.text(ctx, "v1 create") })
}

fn users_v2() -> controller.Controller {
  controller.new("users")
  |> controller.get("/", fn(ctx: Context) {
    controller.text(ctx, "v2 users " <> ctx.request.path)
  })
}

fn orders() -> controller.Controller {
  controller.new("orders")
  |> controller.get("/", fn(ctx: Context) {
    let version = case ctx.version {
      Some(version) -> version
      None -> "none"
    }
    controller.text(ctx, "orders from " <> version)
  })
}

fn health() -> controller.Controller {
  controller.new("health")
  |> controller.get("/", fn(ctx: Context) {
    let version = case ctx.version {
      Some(version) -> version
      None -> "none"
    }
    controller.text(ctx, "ok " <> version)
  })
}

fn group(resolver: version.Resolver) -> Group {
  version.new(resolver)
  |> version.add("v1", [users_v1(), orders()])
  |> version.add("v2", [users_v2()])
}

fn app(group: Group) -> howdy.App {
  howdy.new()
  |> howdy.controller(health())
  |> howdy.versions(group)
}

fn get(
  app: howdy.App,
  path: String,
  headers: List(#(String, String)),
) -> Response(Content) {
  send(app, http.Get, path, headers)
}

fn send(
  app: howdy.App,
  method: http.Method,
  path: String,
  headers: List(#(String, String)),
) -> Response(Content) {
  list.fold(headers, testing.request(method, path), fn(req, header) {
    testing.header(req, header.0, header.1)
  })
  |> testing.send(app)
}

// -- path strategy -----------------------------------------------------------

pub fn path_routes_to_own_version_test() {
  let app = app(group(version.path()))
  let res = get(app, "/v1/users", [])
  assert res.status == 200
  assert testing.text(res) == "v1 users /v1/users"

  let res = get(app, "/v2/users", [])
  assert res.status == 200
  assert testing.text(res) == "v2 users /v2/users"
}

pub fn path_falls_back_to_earlier_version_test() {
  let app = app(group(version.path()))
  let res = get(app, "/v2/orders", [])
  assert res.status == 200
  assert testing.text(res) == "orders from v2"
}

pub fn fallback_is_per_route_test() {
  let app = app(group(version.path()))
  let res = send(app, http.Post, "/v2/users", [])
  assert res.status == 200
  assert testing.text(res) == "v1 create"
}

pub fn earlier_versions_do_not_see_later_routes_test() {
  let only_v2 = controller.new("reports") |> controller.get("/", ok)
  let app =
    version.new(version.path())
    |> version.add("v1", [users_v1()])
    |> version.add("v2", [only_v2])
    |> app
  assert get(app, "/v2/reports", []).status == 200
  assert get(app, "/v1/reports", []).status == 404
}

pub fn no_fallback_answers_only_own_routes_test() {
  let app = app(group(version.path()) |> version.no_fallback)
  assert get(app, "/v2/users", []).status == 200
  assert get(app, "/v2/orders", []).status == 404
}

pub fn default_version_applies_to_unversioned_path_test() {
  let app = app(group(version.path()) |> version.default("v2"))
  let res = get(app, "/users", [])
  assert res.status == 200
  assert testing.text(res) == "v2 users /users"

  let res = get(app, "/orders", [])
  assert testing.text(res) == "orders from v2"
}

pub fn path_without_default_is_not_found_test() {
  let app = app(group(version.path()))
  assert get(app, "/users", []).status == 404
  assert get(app, "/v9/users", []).status == 404
}

pub fn path_method_not_allowed_test() {
  let app = app(group(version.path()))
  let res = send(app, http.Delete, "/v2/users", [])
  assert res.status == 405
  assert response.get_header(res, "allow") == Ok("GET, HEAD, POST")
}

pub fn path_adds_no_vary_header_test() {
  let app = app(group(version.path()))
  assert response.get_header(get(app, "/v1/users", []), "vary") == Error(Nil)
}

pub fn unversioned_controllers_win_test() {
  let app = app(group(version.path()) |> version.default("v1"))
  let res = get(app, "/health", [])
  assert res.status == 200
  assert testing.text(res) == "ok none"
}

// -- header strategy ---------------------------------------------------------

pub fn header_resolves_version_test() {
  let app = app(group(version.header("X-API-Version")))
  let res = get(app, "/users", [#("x-api-version", "v2")])
  assert res.status == 200
  assert testing.text(res) == "v2 users /users"
  assert response.get_header(res, "vary") == Ok("x-api-version")

  let res = get(app, "/orders", [#("x-api-version", "v2")])
  assert testing.text(res) == "orders from v2"
}

pub fn header_unknown_version_is_bad_request_test() {
  let app = app(group(version.header("x-api-version")))
  let res = get(app, "/users", [#("x-api-version", "v9")])
  assert res.status == 400
  assert testing.error(res) == Ok("unknown API version v9")
  assert response.get_header(res, "vary") == Ok("x-api-version")
}

pub fn header_missing_without_default_is_bad_request_test() {
  let app = app(group(version.header("x-api-version")))
  let res = get(app, "/users", [])
  assert res.status == 400
  assert testing.error(res) == Ok("missing API version")
}

pub fn header_missing_uses_default_test() {
  let app = app(group(version.header("x-api-version")) |> version.default("v1"))
  let res = get(app, "/users", [])
  assert res.status == 200
  assert testing.text(res) == "v1 users /users"
}

pub fn header_not_found_keeps_vary_test() {
  let app = app(group(version.header("x-api-version")))
  let res = get(app, "/nope", [#("x-api-version", "v1")])
  assert res.status == 404
  assert response.get_header(res, "vary") == Ok("x-api-version")
}

// -- accept strategy ---------------------------------------------------------

pub fn accept_resolves_vendor_media_type_test() {
  let app = app(group(version.accept("vnd.howdy")))
  let res = get(app, "/users", [#("accept", "application/vnd.howdy.v2+json")])
  assert res.status == 200
  assert testing.text(res) == "v2 users /users"
  assert response.get_header(res, "vary") == Ok("accept")
}

pub fn accept_parses_without_suffix_and_with_parameters_test() {
  let app = app(group(version.accept("vnd.howdy")))
  let res = get(app, "/users", [#("accept", "application/vnd.howdy.v1")])
  assert testing.text(res) == "v1 users /users"

  let res =
    get(app, "/users", [
      #("accept", "text/html, application/vnd.howdy.v2; q=0.9"),
    ])
  assert testing.text(res) == "v2 users /users"
}

pub fn accept_without_vendor_type_is_missing_test() {
  let app = app(group(version.accept("vnd.howdy")))
  let res = get(app, "/users", [#("accept", "application/json")])
  assert res.status == 400
  assert testing.error(res) == Ok("missing API version")
}

// -- custom strategy ---------------------------------------------------------

pub fn custom_resolver_test() {
  let from_query = fn(request: Request(Body)) {
    case request.query {
      Some("v=" <> name) -> Some(name)
      _ -> None
    }
  }
  let app = app(group(version.custom(from_query)))
  let with_query = fn(query) {
    testing.get("/users")
    |> testing.query([#("v", query)])
    |> testing.send(app)
  }
  let res = with_query("v2")
  assert res.status == 200
  assert testing.text(res) == "v2 users /users"
  assert response.get_header(res, "vary") == Error(Nil)

  assert with_query("v9").status == 400
  assert get(app, "/users", []).status == 400
}

// -- middleware and configuration --------------------------------------------

pub fn app_middleware_sees_version_test() {
  let tag = fn(ctx: Context, next: controller.Next) {
    let version = case ctx.version {
      Some(version) -> version
      None -> "none"
    }
    next(ctx) |> response.set_header("x-seen-version", version)
  }
  let app =
    howdy.new()
    |> howdy.middleware(tag)
    |> howdy.controller(health())
    |> howdy.versions(group(version.path()))
  assert response.get_header(get(app, "/v2/users", []), "x-seen-version")
    == Ok("v2")
  assert response.get_header(get(app, "/health", []), "x-seen-version")
    == Ok("none")
}

pub fn app_without_group_still_404s_test() {
  let app = howdy.new() |> howdy.controller(health())
  assert get(app, "/v1/users", []).status == 404
}

@external(erlang, "howdy_test_ffi", "catch_panic")
fn catch_panic(f: fn() -> a) -> Result(a, String)

pub fn duplicate_version_panics_test() {
  let assert Error(_) =
    catch_panic(fn() {
      version.new(version.path())
      |> version.add("v1", [])
      |> version.add("v1", [])
    })
}

pub fn empty_version_name_panics_test() {
  let assert Error(_) =
    catch_panic(fn() { version.new(version.path()) |> version.add("", []) })
}

pub fn unknown_default_panics_when_built_test() {
  let assert Error(_) =
    catch_panic(fn() {
      version.new(version.path())
      |> version.add("v1", [])
      |> version.default("v2")
      |> app
      |> howdy.handler
    })
}

pub fn second_group_panics_test() {
  let assert Error(_) =
    catch_panic(fn() {
      howdy.new()
      |> howdy.versions(version.new(version.path()))
      |> howdy.versions(version.new(version.path()))
    })
}

fn ok(ctx: Context) -> Response(Content) {
  controller.text(ctx, "ok")
}

pub fn not_found_answers_for_version_groups_test() {
  let app =
    app(group(version.path()))
    |> howdy.not_found(fn(ctx: Context) {
      let asked = case ctx.version {
        Some(version) -> version
        None -> "none"
      }
      controller.text(ctx, "missing in " <> asked)
      |> controller.with_status(404)
    })

  // Not a versioned path at all.
  let res = get(app, "/users", [])
  assert res.status == 404
  assert testing.text(res) == "missing in none"
  // A version that has no such route.
  let res = get(app, "/v1/reports", [])
  assert res.status == 404
  assert testing.text(res) == "missing in v1"
  // Routes still answer, and a wrong method is still 405.
  assert get(app, "/v2/users", []).status == 200
  assert send(app, http.Delete, "/v2/users", []).status == 405
}

pub fn reading_a_group_test() {
  let v1 = controller.new("users") |> controller.get("/", ok)
  let v2 = controller.new("users") |> controller.post("/", ok)
  let group =
    version.new(version.header("X-API-Version"))
    |> version.default("v1")
    |> version.add("v1", [v1])
    |> version.add("v2", [v2])

  assert version.strategy(group) == version.HeaderStrategy("x-api-version")
  assert version.strategy(version.new(version.path())) == version.PathStrategy
  assert version.names(group) == ["v1", "v2"]
  assert version.default_version(group) == Some("v1")
  assert version.controllers(group, "v2") == Ok([v2, v1])
  assert version.controllers(group, "v1") == Ok([v1])
  assert version.controllers(group, "v3") == Error(Nil)
  assert version.controllers(version.no_fallback(group), "v2") == Ok([v2])

  assert howdy.version_group(howdy.new()) == None
  let assert Some(_) = howdy.version_group(howdy.new() |> howdy.versions(group))
}
