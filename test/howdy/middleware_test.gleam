import gleam/http
import gleam/http/response
import howdy
import howdy/controller.{type Context}
import howdy/middleware.{type Next}
import howdy/service
import howdy/testing

/// Records its name in a response header on the way out, so tests can see
/// the order middleware ran in. The header lists the innermost first.
fn tag(name: String) {
  fn(ctx: Context, next: Next) {
    let res = next(ctx)
    let trail = case response.get_header(res, "x-trail") {
      Ok(trail) -> trail <> "," <> name
      Error(Nil) -> name
    }
    response.set_header(res, "x-trail", trail)
  }
}

fn reject(ctx: Context, _next: Next) {
  service.error_response(ctx, service.Unauthorized)
}

fn handler(ctx: Context) {
  controller.text(ctx, "handler")
}

fn get(app: howdy.App, path: String) {
  testing.get(path) |> testing.send(app)
}

pub fn route_wrap_test() {
  let app =
    howdy.new()
    |> howdy.controller(
      controller.new("t")
      |> controller.get("/", handler |> middleware.wrap(tag("route"))),
    )

  let res = get(app, "/t")
  assert testing.text(res) == "handler"
  assert response.get_header(res, "x-trail") == Ok("route")
}

pub fn ordering_test() {
  let app =
    howdy.new()
    |> howdy.middleware(tag("app1"))
    |> howdy.middleware(tag("app2"))
    |> howdy.controller(
      controller.new("t")
      |> controller.get(
        "/",
        handler |> middleware.wrap_all([tag("route1"), tag("route2")]),
      )
      // Added after the route, but still applies to it.
      |> controller.middleware(tag("ctrl1"))
      |> controller.middleware(tag("ctrl2")),
    )

  let res = get(app, "/t")
  // Innermost first: the handler's response passes route2, route1, ctrl2, ...
  assert response.get_header(res, "x-trail")
    == Ok("route2,route1,ctrl2,ctrl1,app2,app1")
}

pub fn controller_middleware_applies_to_all_routes_test() {
  let app =
    howdy.new()
    |> howdy.controller(
      controller.new("t")
      |> controller.middleware(tag("ctrl"))
      |> controller.get("/a", handler)
      |> controller.get("/b", handler),
    )

  assert response.get_header(get(app, "/t/a"), "x-trail") == Ok("ctrl")
  assert response.get_header(get(app, "/t/b"), "x-trail") == Ok("ctrl")
}

pub fn controller_middleware_is_scoped_test() {
  let app =
    howdy.new()
    |> howdy.controller(
      controller.new("a")
      |> controller.middleware(tag("only-a"))
      |> controller.get("/", handler),
    )
    |> howdy.controller(controller.new("b") |> controller.get("/", handler))

  assert response.get_header(get(app, "/a"), "x-trail") == Ok("only-a")
  assert response.get_header(get(app, "/b"), "x-trail") == Error(Nil)
}

pub fn short_circuit_test() {
  let app =
    howdy.new()
    |> howdy.middleware(tag("app"))
    |> howdy.controller(
      controller.new("t")
      |> controller.get("/", handler |> middleware.wrap(reject)),
    )

  let res = get(app, "/t")
  assert res.status == 401
  assert testing.error(res) == Ok("unauthorized")
  // Outer middleware still sees the rejected response.
  assert response.get_header(res, "x-trail") == Ok("app")
}

pub fn app_middleware_does_not_run_for_unmatched_routes_test() {
  let app = howdy.new() |> howdy.middleware(tag("app"))

  let res = get(app, "/nope")
  assert res.status == 404
  assert response.get_header(res, "x-trail") == Error(Nil)
}

fn missing(ctx: Context) {
  service.error_response(ctx, service.NotFound("no such page"))
}

pub fn not_found_answers_unmatched_routes_test() {
  let app =
    howdy.new()
    |> howdy.controller(controller.new("t") |> controller.get("/", handler))
    |> howdy.not_found(missing)

  let res = get(app, "/nope")
  assert res.status == 404
  assert testing.error(res) == Ok("no such page")
  // Any method, not only GET.
  let res = testing.request(http.Post, "/nope") |> testing.send(app)
  assert testing.error(res) == Ok("no such page")
  // Matched routes are unaffected.
  assert testing.text(get(app, "/t")) == "handler"
}

pub fn not_found_runs_inside_app_middleware_test() {
  let app =
    howdy.new()
    |> howdy.middleware(tag("outer"))
    |> howdy.middleware(tag("inner"))
    |> howdy.not_found(missing)

  let res = get(app, "/nope")
  assert res.status == 404
  assert response.get_header(res, "x-trail") == Ok("inner,outer")
}

pub fn not_found_leaves_method_not_allowed_test() {
  let app =
    howdy.new()
    |> howdy.controller(controller.new("t") |> controller.get("/", handler))
    |> howdy.not_found(missing)

  let res = testing.request(http.Delete, "/t") |> testing.send(app)
  assert res.status == 405
}

pub fn not_found_gets_no_path_parameters_test() {
  let app =
    howdy.new()
    |> howdy.not_found(fn(ctx: Context) {
      controller.text(ctx, ctx.request.path)
      |> controller.with_status(404)
    })

  let res = get(app, "/some/where")
  assert res.status == 404
  assert testing.text(res) == "/some/where"
}
