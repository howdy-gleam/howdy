import gleam/http
import gleam/http/request
import gleam/list
import howdy
import howdy/context.{type Body}
import howdy/controller
import howdy/csrf
import howdy/form
import howdy/service
import howdy/testing

const origin = "https://example.com"

fn app() -> howdy.App {
  howdy.new()
  |> howdy.middleware(csrf.middleware(csrf.new([origin])))
  |> howdy.controller(
    controller.new("/notes")
    |> controller.get("/", fn(ctx) { controller.text(ctx, "read") })
    |> controller.post("/", fn(ctx) {
      use fields <- form.read(ctx)
      controller.text(ctx, form.value(fields, "body"))
    })
    |> controller.delete("/", fn(ctx) { controller.text(ctx, "gone") }),
  )
}

/// A form post carrying the origins given, in order.
fn post(origins: List(String)) {
  let req = testing.post_form("/notes", [#("body", "written")])
  origins
  |> list_prepend(req)
  |> testing.send(app())
}

fn list_prepend(
  origins: List(String),
  req: request.Request(Body),
) -> request.Request(Body) {
  case origins {
    [] -> req
    [value, ..rest] ->
      list_prepend(rest, request.prepend_header(req, "origin", value))
  }
}

pub fn matching_origin_is_allowed_test() {
  let res = post([origin])
  assert res.status == 200
  assert testing.text(res) == "written"
}

pub fn origin_comparison_ignores_case_test() {
  assert post(["HTTPS://EXAMPLE.COM"]).status == 200
}

pub fn missing_origin_is_rejected_test() {
  let res = post([])
  assert res.status == 403
  assert testing.error(res) == Ok("forbidden")
}

pub fn foreign_origins_are_rejected_test() {
  assert post(["https://evil.com"]).status == 403
  // A name that merely starts with the allowed one is a different origin.
  assert post(["https://example.com.evil.com"]).status == 403
  // So are a different scheme and a different port.
  assert post(["http://example.com"]).status == 403
  assert post(["https://example.com:8443"]).status == 403
}

pub fn null_origin_is_rejected_test() {
  assert post(["null"]).status == 403
}

pub fn duplicate_origins_are_rejected_test() {
  assert post([origin, origin]).status == 403
  assert post([origin, "https://evil.com"]).status == 403
}

// -- Sec-Fetch-Site ----------------------------------------------------------

fn post_with(headers: List(#(String, String))) {
  let req = testing.post_form("/notes", [#("body", "written")])
  headers
  |> list.fold(req, fn(req, header) {
    request.prepend_header(req, header.0, header.1)
  })
  |> testing.send(app())
}

pub fn same_origin_fetch_site_stands_in_for_a_missing_origin_test() {
  assert post_with([#("sec-fetch-site", "same-origin")]).status == 200
  assert post_with([#("Sec-Fetch-Site", "Same-Origin")]).status == 200
}

pub fn other_fetch_sites_do_not_test() {
  assert post_with([#("sec-fetch-site", "cross-site")]).status == 403
  assert post_with([#("sec-fetch-site", "same-site")]).status == 403
  assert post_with([#("sec-fetch-site", "none")]).status == 403
  assert post_with([#("sec-fetch-site", "")]).status == 403
}

pub fn a_present_origin_always_decides_test() {
  // An allowed origin may be another site entirely.
  assert post_with([#("origin", origin), #("sec-fetch-site", "cross-site")]).status
    == 200
  assert post_with([
      #("origin", "https://evil.com"),
      #("sec-fetch-site", "same-origin"),
    ]).status
    == 403
  assert post_with([
      #("origin", origin),
      #("origin", origin),
      #("sec-fetch-site", "same-origin"),
    ]).status
    == 403
}

pub fn duplicate_fetch_sites_are_rejected_test() {
  assert post_with([
      #("sec-fetch-site", "same-origin"),
      #("sec-fetch-site", "same-origin"),
    ]).status
    == 403
  assert post_with([
      #("sec-fetch-site", "same-origin"),
      #("sec-fetch-site", "cross-site"),
    ]).status
    == 403
}

pub fn reads_are_not_checked_test() {
  let res = testing.get("/notes") |> testing.send(app())
  assert res.status == 200
  assert testing.text(res) == "read"
}

pub fn other_write_methods_are_checked_test() {
  let send = fn(headers) {
    testing.request(http.Delete, "/notes")
    |> list_prepend(headers, _)
    |> testing.send(app())
  }
  assert send([]).status == 403
  assert send([origin]).status == 200
}

pub fn exempt_requests_skip_the_check_test() {
  let policy =
    csrf.new([origin])
    |> csrf.exempt(fn(ctx) {
      case request.get_header(ctx.request, "authorization") {
        Ok("Bearer " <> _) -> True
        _ -> False
      }
    })
  let app =
    howdy.new()
    |> howdy.middleware(csrf.middleware(policy))
    |> howdy.controller(
      controller.new("/notes")
      |> controller.post("/", fn(ctx) { controller.text(ctx, "written") }),
    )
  let send = fn(req) { testing.send(req, app) }
  let post = fn() { testing.post_form("/notes", []) }

  assert send(post() |> testing.header("authorization", "Bearer abc")).status
    == 200
  assert send(post()).status == 403
  assert send(post() |> testing.header("authorization", "Basic abc")).status
    == 403
}

pub fn check_is_usable_on_one_route_test() {
  let app =
    howdy.new()
    |> howdy.controller(
      controller.new("/notes")
      |> controller.post("/", fn(ctx) {
        case csrf.check(ctx, [origin]) {
          Ok(Nil) -> controller.text(ctx, "written")
          Error(error) -> service.error_response(ctx, error)
        }
      }),
    )
  let send = fn(req) { testing.send(req, app) }
  assert send(
      testing.post_form("/notes", []) |> testing.header("origin", origin),
    ).status
    == 200
  assert send(testing.post_form("/notes", [])).status == 403
}

// -- Configuration -----------------------------------------------------------

pub fn invalid_origins_panic_test() {
  assert panics(fn() { csrf.new([]) })
  assert panics(fn() { csrf.new(["example.com"]) })
  assert panics(fn() { csrf.new(["https://example.com/notes"]) })
  assert panics(fn() { csrf.new(["https://*.example.com"]) })
  assert panics(fn() { csrf.new(["https://"]) })
  assert panics(fn() { csrf.new(["null"]) })
  assert panics(fn() { csrf.new([origin, "nonsense"]) })
}

pub fn valid_origins_are_accepted_test() {
  assert !panics(fn() { csrf.new([origin, "http://localhost:5173"]) })
}

@external(erlang, "howdy_test_ffi", "catch_panic")
fn catch_panic(run: fn() -> a) -> Result(a, String)

fn panics(run: fn() -> a) -> Bool {
  case catch_panic(run) {
    Ok(_) -> False
    Error(_) -> True
  }
}

pub fn check_normalises_the_origins_it_is_given_test() {
  let app =
    howdy.new()
    |> howdy.controller(
      controller.new("/notes")
      |> controller.post("/", fn(ctx) {
        case csrf.check(ctx, ["HTTPS://Example.COM"]) {
          Ok(Nil) -> controller.text(ctx, "written")
          Error(error) -> service.error_response(ctx, error)
        }
      }),
    )
  let res =
    testing.post_form("/notes", [])
    |> testing.header("origin", origin)
    |> testing.send(app)
  assert res.status == 200
}
