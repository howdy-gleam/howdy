import gleam/http
import gleam/http/response.{type Response}
import gleam/list
import gleam/string
import howdy
import howdy/controller.{type Context}
import howdy/cors
import howdy/middleware.{type Next}
import howdy/service
import howdy/testing
import howdy/version

const app_origin = "https://app.example.com"

fn handler(ctx: Context) {
  controller.text(ctx, "ok")
}

fn reject(ctx: Context, _next: Next) {
  service.error_response(ctx, service.Unauthorized)
}

/// An app with the policy at app level and a controller at `/user`.
fn app(policy: cors.Config) -> howdy.App {
  howdy.new()
  |> howdy.middleware(cors.middleware(policy))
  |> howdy.controller(
    controller.new("user")
    |> controller.get("/", handler)
    |> controller.post("/", handler)
    |> controller.get("/:id", handler),
  )
}

fn send(
  app: howdy.App,
  method: http.Method,
  path: String,
  headers: List(#(String, String)),
) -> Response(_) {
  list.fold(headers, testing.request(method, path), fn(req, h) {
    testing.header(req, h.0, h.1)
  })
  |> testing.send(app)
}

fn preflight(app: howdy.App, path: String, headers: List(#(String, String))) {
  send(app, http.Options, path, [
    #("origin", app_origin),
    #("access-control-request-method", "POST"),
    ..headers
  ])
}

fn header(res: Response(_), name: String) -> Result(String, Nil) {
  response.get_header(res, name)
}

fn origins() -> cors.Config {
  cors.new() |> cors.allow_origins([app_origin])
}

// -- Requests that are not cross-origin ---------------------------------------

pub fn request_without_origin_varies_but_has_no_cors_headers_test() {
  let res = send(app(origins()), http.Get, "/user", [])
  assert res.status == 200
  assert header(res, "access-control-allow-origin") == Error(Nil)
  assert header(res, "vary") == Ok("origin")
}

pub fn options_without_request_method_is_not_a_preflight_test() {
  // A plain OPTIONS with an origin is an ordinary cross-origin request: it
  // reaches the router's OPTIONS handler and gets the actual-request headers.
  let res =
    send(app(origins()), http.Options, "/user", [#("origin", app_origin)])
  assert res.status == 204
  assert header(res, "allow") == Ok("GET, HEAD, POST, OPTIONS")
  assert header(res, "access-control-allow-origin") == Ok(app_origin)
  assert header(res, "access-control-allow-methods") == Error(Nil)
}

// -- Preflight ---------------------------------------------------------------

pub fn preflight_for_allowed_origin_test() {
  let policy =
    origins()
    |> cors.allow_methods([http.Get, http.Post])
    |> cors.allow_headers(["Content-Type", "authorization"])
    |> cors.max_age(600)
  let res = preflight(app(policy), "/user", [])

  assert res.status == 204
  assert testing.text(res) == ""
  assert header(res, "access-control-allow-origin") == Ok(app_origin)
  assert header(res, "access-control-allow-methods") == Ok("GET, POST")
  assert header(res, "access-control-allow-headers")
    == Ok("content-type, authorization")
  assert header(res, "access-control-max-age") == Ok("600")
  assert header(res, "access-control-allow-credentials") == Error(Nil)
  assert header(res, "vary") == Ok("origin")
}

pub fn preflight_for_unknown_origin_has_no_cors_headers_test() {
  let res =
    send(app(origins()), http.Options, "/user", [
      #("origin", "https://evil.example.com"),
      #("access-control-request-method", "POST"),
    ])

  assert res.status == 204
  assert header(res, "access-control-allow-origin") == Error(Nil)
  assert header(res, "access-control-allow-methods") == Error(Nil)
  // Caches must still key on origin, since another origin would be allowed.
  assert header(res, "vary") == Ok("origin")
}

pub fn preflight_does_not_reach_inner_middleware_test() {
  // Auth sits inside CORS and would reject a credential-less preflight.
  let app =
    howdy.new()
    |> howdy.middleware(cors.middleware(origins()))
    |> howdy.middleware(reject)
    |> howdy.controller(controller.new("user") |> controller.post("/", handler))

  let res = preflight(app, "/user", [])
  assert res.status == 204
  assert header(res, "access-control-allow-origin") == Ok(app_origin)

  // The real request is still rejected by auth, but with CORS headers so the
  // browser can show the 401 rather than a CORS error.
  let res = send(app, http.Post, "/user", [#("origin", app_origin)])
  assert res.status == 401
  assert header(res, "access-control-allow-origin") == Ok(app_origin)
}

pub fn preflight_uses_default_methods_test() {
  let res = preflight(app(origins()), "/user", [])
  assert header(res, "access-control-allow-methods")
    == Ok("GET, HEAD, POST, PUT, PATCH, DELETE")
}

pub fn preflight_with_no_allowed_headers_omits_header_test() {
  let res =
    preflight(app(origins()), "/user", [
      #("access-control-request-headers", "authorization"),
    ])
  assert header(res, "access-control-allow-headers") == Error(Nil)
}

pub fn allow_any_header_echoes_requested_headers_test() {
  let policy = origins() |> cors.allow_any_header
  let res =
    preflight(app(policy), "/user", [
      #("access-control-request-headers", "Authorization, X-Trace-Id"),
    ])
  assert header(res, "access-control-allow-headers")
    == Ok("authorization, x-trace-id")
  assert header(res, "vary") == Ok("origin, access-control-request-headers")

  // Nothing requested, nothing echoed.
  let res = preflight(app(policy), "/user", [])
  assert header(res, "access-control-allow-headers") == Error(Nil)
}

pub fn preflight_for_parameterised_route_test() {
  let res = preflight(app(origins()), "/user/42", [])
  assert res.status == 204
  assert header(res, "access-control-allow-origin") == Ok(app_origin)
}

pub fn preflight_for_unknown_path_is_404_test() {
  // No route, so no middleware: the framework answers 404 before CORS runs.
  let res = preflight(app(origins()), "/nope", [])
  assert res.status == 404
  assert header(res, "access-control-allow-origin") == Error(Nil)
}

// -- Actual requests ---------------------------------------------------------

pub fn actual_request_from_allowed_origin_test() {
  let policy = origins() |> cors.expose_headers(["X-Request-Id", "x-total"])
  let res = send(app(policy), http.Get, "/user", [#("origin", app_origin)])

  assert res.status == 200
  assert testing.text(res) == "ok"
  assert header(res, "access-control-allow-origin") == Ok(app_origin)
  assert header(res, "access-control-expose-headers")
    == Ok("x-request-id, x-total")
  assert header(res, "access-control-allow-methods") == Error(Nil)
  assert header(res, "vary") == Ok("origin")
}

pub fn actual_request_from_unknown_origin_test() {
  let res =
    send(app(origins()), http.Get, "/user", [
      #("origin", "https://evil.example.com"),
    ])
  // The handler still runs; the browser is what blocks the read.
  assert res.status == 200
  assert header(res, "access-control-allow-origin") == Error(Nil)
  assert header(res, "vary") == Ok("origin")
}

pub fn origin_comparison_is_case_insensitive_test() {
  let policy = cors.new() |> cors.allow_origins(["https://App.Example.com"])
  let res =
    send(app(policy), http.Get, "/user", [
      #("origin", "https://app.EXAMPLE.com"),
    ])
  // Echoed exactly as sent.
  assert header(res, "access-control-allow-origin")
    == Ok("https://app.EXAMPLE.com")
}

pub fn error_responses_carry_cors_headers_test() {
  let res =
    send(app(origins()), http.Delete, "/user", [#("origin", app_origin)])
  assert res.status == 405
  // 405 is produced by the router, outside middleware, so no CORS headers.
  assert header(res, "access-control-allow-origin") == Error(Nil)

  let app =
    howdy.new()
    |> howdy.middleware(cors.middleware(origins()))
    |> howdy.controller(
      controller.new("user")
      |> controller.get("/", fn(ctx) {
        service.error_response(ctx, service.NotFound("user"))
      }),
    )
  let res = send(app, http.Get, "/user", [#("origin", app_origin)])
  assert res.status == 404
  assert header(res, "access-control-allow-origin") == Ok(app_origin)
}

// -- Origin policies ---------------------------------------------------------

pub fn allow_any_origin_uses_wildcard_test() {
  let app = app(cors.allow_all())
  let res =
    send(app, http.Get, "/user", [#("origin", "https://anyone.example")])
  assert header(res, "access-control-allow-origin") == Ok("*")
  assert header(res, "vary") == Ok("origin")

  let res =
    send(app, http.Options, "/user", [
      #("origin", "https://anyone.example"),
      #("access-control-request-method", "PUT"),
      #("access-control-request-headers", "content-type"),
    ])
  assert res.status == 204
  assert header(res, "access-control-allow-origin") == Ok("*")
  assert header(res, "access-control-allow-headers") == Ok("content-type")
  assert header(res, "vary") == Ok("origin, access-control-request-headers")
}

pub fn allow_origins_matching_test() {
  let policy =
    cors.new()
    |> cors.allow_origins_matching(fn(origin) {
      origin == "https://a.example" || origin == "https://b.example"
    })
  let app = app(policy)

  let res = send(app, http.Get, "/user", [#("origin", "https://b.example")])
  assert header(res, "access-control-allow-origin") == Ok("https://b.example")

  let res = send(app, http.Get, "/user", [#("origin", "https://c.example")])
  assert header(res, "access-control-allow-origin") == Error(Nil)
}

pub fn new_allows_nothing_test() {
  let res = send(app(cors.new()), http.Get, "/user", [#("origin", app_origin)])
  assert res.status == 200
  assert header(res, "access-control-allow-origin") == Error(Nil)
  assert header(res, "vary") == Error(Nil)
}

pub fn null_origin_must_be_listed_test() {
  let res = send(app(origins()), http.Get, "/user", [#("origin", "null")])
  assert header(res, "access-control-allow-origin") == Error(Nil)

  let policy = cors.new() |> cors.allow_origins(["null"])
  let res = send(app(policy), http.Get, "/user", [#("origin", "null")])
  assert header(res, "access-control-allow-origin") == Ok("null")
}

// -- Credentials -------------------------------------------------------------

pub fn credentials_test() {
  let policy = origins() |> cors.allow_credentials
  let app = app(policy)

  let res = send(app, http.Get, "/user", [#("origin", app_origin)])
  assert header(res, "access-control-allow-origin") == Ok(app_origin)
  assert header(res, "access-control-allow-credentials") == Ok("true")

  let res = preflight(app, "/user", [])
  assert header(res, "access-control-allow-credentials") == Ok("true")
}

pub fn credentials_with_any_origin_panics_test() {
  let policy = cors.allow_all() |> cors.allow_credentials
  assert panics(fn() { cors.middleware(policy) })
}

pub fn invalid_origin_panics_test() {
  assert panics(fn() { cors.new() |> cors.allow_origins(["*"]) })
  assert panics(fn() {
    cors.new() |> cors.allow_origins(["https://app.example.com/"])
  })
  assert panics(fn() { cors.new() |> cors.allow_origins(["app.example.com"]) })
  assert !panics(fn() {
    cors.new() |> cors.allow_origins(["http://localhost:5173", "null"])
  })
}

// -- Placement ---------------------------------------------------------------

pub fn controller_level_cors_test() {
  let app =
    howdy.new()
    |> howdy.controller(
      controller.new("open")
      |> controller.middleware(cors.middleware(origins()))
      |> controller.post("/", handler),
    )
    |> howdy.controller(
      controller.new("closed") |> controller.post("/", handler),
    )

  let res = preflight(app, "/open", [])
  assert res.status == 204
  assert header(res, "access-control-allow-origin") == Ok(app_origin)

  // The router answers OPTIONS for the other controller too, but without
  // CORS headers since it has no policy.
  let res = preflight(app, "/closed", [])
  assert res.status == 204
  assert header(res, "allow") == Ok("POST, OPTIONS")
  assert header(res, "access-control-allow-origin") == Error(Nil)
}

pub fn explicit_options_route_wins_test() {
  let app =
    howdy.new()
    |> howdy.middleware(cors.middleware(origins()))
    |> howdy.controller(
      controller.new("user")
      |> controller.get("/", handler)
      |> controller.route(http.Options, "/", fn(ctx) {
        controller.text(ctx, "custom")
      }),
    )

  // A preflight is still answered by CORS, never the handler.
  let res = preflight(app, "/user", [])
  assert res.status == 204
  assert testing.text(res) == ""

  // A plain OPTIONS reaches the custom route.
  let res = send(app, http.Options, "/user", [])
  assert testing.text(res) == "custom"
}

pub fn vary_merges_with_version_group_test() {
  let group =
    version.new(version.header("x-api-version"))
    |> version.default("v1")
    |> version.add("v1", [
      controller.new("user") |> controller.get("/", handler),
    ])
  let app =
    howdy.new()
    |> howdy.middleware(cors.middleware(origins()))
    |> howdy.versions(group)

  let res = send(app, http.Get, "/user", [#("origin", app_origin)])
  assert res.status == 200
  assert header(res, "vary") == Ok("origin, x-api-version")
}

// -- Helpers -----------------------------------------------------------------

@external(erlang, "howdy_test_ffi", "catch_panic")
fn catch_panic(run: fn() -> a) -> Result(a, String)

fn panics(run: fn() -> a) -> Bool {
  case catch_panic(run) {
    Ok(_) -> False
    Error(_) -> True
  }
}

pub fn no_origin_then_allowed_origin_cache_variation_test() {
  use policy <- list.each([
    origins(),
    cors.allow_all(),
    cors.new() |> cors.allow_origins_matching(fn(_) { True }),
  ])
  let app = app(policy)
  let initial = send(app, http.Get, "/user", [])
  assert header(initial, "vary") == Ok("origin")
  assert header(initial, "access-control-allow-origin") == Error(Nil)
  let allowed = send(app, http.Get, "/user", [#("origin", app_origin)])
  assert header(allowed, "vary") == Ok("origin")
  assert header(allowed, "access-control-allow-origin") != Error(Nil)
}

pub fn no_origin_preserves_all_vary_fields_test() {
  use values <- list.each([
    ["Accept-Encoding", "X-Api-Version"],
    ["*"],
    ["ORIGIN", "Accept-Encoding"],
  ])
  let app =
    howdy.new()
    |> howdy.middleware(cors.middleware(origins()))
    |> howdy.controller(
      controller.new("user")
      |> controller.get("/", fn(ctx) {
        let res = controller.text(ctx, "ok")
        response.Response(
          ..res,
          headers: list.append(
            res.headers,
            list.map(values, fn(value) { #("vary", value) }),
          ),
        )
      }),
    )
  let res = send(app, http.Get, "/user", [])
  let variations =
    res.headers
    |> list.filter(fn(h) { h.0 == "vary" })
    |> list.map(fn(h) { h.1 })
    |> string.join(", ")
    |> string.lowercase
  use value <- list.each(values)
  assert string.contains(variations, string.lowercase(value))
  assert string.contains(variations, "origin") || variations == "*"
}
