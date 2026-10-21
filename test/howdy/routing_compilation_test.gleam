import gleam/http
import gleam/http/response
import gleam/list
import gleam/option.{None}
import howdy
import howdy/context
import howdy/controller
import howdy/router
import howdy/testing
import router_reference

fn reply(ctx: controller.Context) {
  controller.text(ctx, "matched")
}

fn stamp(name: String) -> controller.Middleware {
  fn(ctx, next) { next(ctx) |> response.prepend_header("x-order", name) }
}

pub fn compiled_routes_preserve_reference_semantics_test() {
  let controllers = [
    controller.new("/")
      |> controller.middleware(stamp("fallback"))
      |> controller.get("/*rest", reply),
    controller.new("items")
      |> controller.middleware(stamp("first"))
      |> controller.get("/:id", reply)
      |> controller.post("/:id", reply),
    controller.new("items")
      |> controller.middleware(stamp("second"))
      |> controller.get("/all", reply)
      |> controller.put("/all", reply)
      |> controller.get("/:other", reply)
      |> controller.route(http.Options, "/explicit", reply),
  ]
  let table = router.compile(controllers, [stamp("app")])
  use path <- list.each([
    "/",
    "/missing",
    "/items/42",
    "/items/all",
    "/items/explicit",
    "/items//all/",
    "/items/a/b",
  ])
  use method <- list.each([
    http.Get,
    http.Post,
    http.Put,
    http.Delete,
    http.Head,
    http.Options,
  ])
  let expected = router_reference.match(controllers, method, path)
  let actual = router.match_table(table, method, path)
  case expected, actual {
    router.NotFound, router.NotFound -> Nil
    router.MethodNotAllowed(a), router.MethodNotAllowed(b) -> {
      assert a == b
    }
    router.Found(a, a_params, a_route), router.Found(b, b_params, b_route) -> {
      assert a_params == b_params
      assert a_route == b_route
      let ctx =
        context.Context(
          request: testing.request(method, path),
          params: a_params,
          guard: Nil,
          version: None,
        )
      let expected = controller.wrap_all(a, [stamp("app")])(ctx)
      let actual = b(ctx)
      assert expected == actual
    }
    _, _ -> panic as "compiled router changed matching semantics"
  }
}

/// The index buckets routes by segment count and first literal; these
/// controllers interleave parameter-first, literal-first, root and wildcard
/// patterns of several lengths so every bucket has to merge in order.
pub fn indexed_routes_preserve_reference_semantics_test() {
  let controllers = [
    controller.new("/")
      |> controller.middleware(stamp("root"))
      |> controller.get("/", reply)
      |> controller.get("/:tenant/settings", reply),
    controller.new("/users")
      |> controller.middleware(stamp("users"))
      |> controller.get("/:id", reply)
      |> controller.get("/me", reply)
      |> controller.delete("/:id", reply),
    controller.new("/")
      |> controller.middleware(stamp("catch"))
      |> controller.post("/:tenant/:resource", reply)
      |> controller.get("/:a/:b/:c", reply)
      |> controller.get("/users/*rest", reply)
      |> controller.get("/*rest", reply),
    controller.new("/users")
      |> controller.middleware(stamp("late"))
      |> controller.put("/me", reply)
      |> controller.get("/me/settings", reply),
  ]
  let table = router.compile(controllers, [stamp("app")])
  use path <- list.each([
    "/",
    "/users",
    "/users/me",
    "/users/42",
    "/users/me/settings",
    "/users/42/settings",
    "/acme/settings",
    "/acme/widgets",
    "/a/b/c",
    "/a/b/c/d",
    "/users/a/b/c",
  ])
  use method <- list.each([
    http.Get,
    http.Post,
    http.Put,
    http.Delete,
    http.Options,
  ])
  let expected = router_reference.match(controllers, method, path)
  let actual = router.match_table(table, method, path)
  case expected, actual {
    router.NotFound, router.NotFound -> Nil
    router.MethodNotAllowed(a), router.MethodNotAllowed(b) -> {
      assert a == b
    }
    router.Found(a, a_params, a_route), router.Found(b, b_params, b_route) -> {
      assert a_params == b_params
      assert a_route == b_route
      let ctx =
        context.Context(
          request: testing.request(method, path),
          params: a_params,
          guard: Nil,
          version: None,
        )
      assert controller.wrap_all(a, [stamp("app")])(ctx) == b(ctx)
    }
    _, _ -> panic as "indexed router changed matching semantics"
  }
}

pub fn compiled_handler_is_reusable_and_isolated_from_later_builders_test() {
  let app =
    howdy.new()
    |> howdy.middleware(stamp("app"))
    |> howdy.controller(controller.new("/one") |> controller.get("/", reply))
  let serve = howdy.serve(app)
  let later =
    app
    |> howdy.controller(controller.new("/two") |> controller.get("/", reply))
    |> howdy.serve
  use _ <- list.each(list.repeat(Nil, 20))
  assert serve(testing.get("/one")).status == 200
  assert serve(testing.get("/two")).status == 404
  assert later(testing.get("/two")).status == 200
}

pub fn compiled_empty_table_returns_not_found_test() {
  assert router.match_table(router.compile([], []), http.Get, "/")
    == router.NotFound
}
