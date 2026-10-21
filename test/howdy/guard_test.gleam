import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import howdy
import howdy/body
import howdy/context
import howdy/controller.{type GuardedContext}
import howdy/guard
import howdy/param
import howdy/service
import howdy/testing
import howdy/validate

type User {
  User(id: Int, admin: Bool)
}

fn authenticated(ctx: GuardedContext(existing)) -> service.Result(User) {
  case request.get_header(ctx.request, "authorization") {
    Ok("member") -> Ok(User(7, False))
    Ok("admin") -> Ok(User(9, True))
    _ -> Error(service.Unauthorized)
  }
}

fn admin(ctx: GuardedContext(User)) -> service.Result(Nil) {
  case ctx.guard.admin {
    True -> Ok(Nil)
    False -> Error(service.Forbidden)
  }
}

fn send(app: howdy.App, method: http.Method, path: String, token: String) {
  testing.request(method, path)
  |> testing.header("authorization", token)
  |> testing.send(app)
}

pub fn endpoint_guard_passes_typed_value_and_is_scoped_test() {
  let app =
    howdy.new()
    |> howdy.controller(
      controller.new("users")
      |> controller.get("/public", fn(ctx) { controller.text(ctx, "public") })
      |> controller.get("/me", fn(ctx) {
        use user <- guard.require(ctx, authenticated)
        controller.text(ctx, int.to_string(user.id))
      }),
    )

  assert send(app, http.Get, "/users/public", "").status == 200
  assert testing.text(send(app, http.Get, "/users/me", "member")) == "7"
  let denied = send(app, http.Get, "/users/me", "")
  assert denied.status == 401
  assert testing.error(denied) == Ok("unauthorized")
}

pub fn endpoint_rejection_skips_later_checks_and_work_test() {
  let app =
    howdy.new()
    |> howdy.controller(
      controller.new("users")
      |> controller.get("/", fn(ctx) {
        use _ <- guard.require(ctx, fn(_) { Error(service.Forbidden) })
        use _ <- guard.require(ctx, fn(_) { panic as "later guard ran" })
        panic as "protected work ran"
      }),
    )

  let denied = send(app, http.Get, "/users", "")
  assert denied.status == 403
  assert testing.error(denied) == Ok("forbidden")
}

pub fn controller_guard_supplies_every_route_and_runs_per_request_test() {
  let calls = process.new_subject()
  let users =
    controller.guarded("users", fn(ctx) {
      process.send(calls, ctx.request.path)
      authenticated(ctx)
    })
    |> controller.get("/me", fn(ctx) {
      controller.text(ctx, int.to_string(ctx.guard.id))
    })
    |> controller.post("/other", fn(ctx) {
      controller.text(ctx, int.to_string(ctx.guard.id))
    })
    |> controller.build()

  let app = howdy.new() |> howdy.controller(users)
  // Building and mounting must not execute request guards.
  assert process.receive(calls, 0) == Error(Nil)
  assert testing.text(send(app, http.Get, "/users/me", "member")) == "7"
  assert testing.text(send(app, http.Post, "/users/other", "admin")) == "9"
  assert send(app, http.Get, "/users/me", "").status == 401
  assert send(app, http.Post, "/users/other", "").status == 401
  assert process.receive(calls, 0) == Ok("/users/me")
  assert process.receive(calls, 0) == Ok("/users/other")
  assert process.receive(calls, 0) == Ok("/users/me")
  assert process.receive(calls, 0) == Ok("/users/other")
  assert process.receive(calls, 0) == Error(Nil)
}

pub fn controller_rejection_skips_handler_and_endpoint_guard_test() {
  let app =
    howdy.new()
    |> howdy.controller(
      controller.guarded("users", authenticated)
      |> controller.get("/", fn(ctx) {
        use _ <- guard.require(ctx, fn(_) { panic as "endpoint guard ran" })
        panic as "protected work ran"
      })
      |> controller.build(),
    )

  assert send(app, http.Get, "/users", "invalid").status == 401
}

pub fn endpoint_guard_can_depend_on_controller_identity_test() {
  let app =
    howdy.new()
    |> howdy.controller(
      controller.guarded("users", authenticated)
      |> controller.delete("/:id", fn(ctx) {
        use _ <- guard.require(ctx, admin)
        use id <- param.int(ctx, "id")
        controller.text(
          ctx,
          int.to_string(ctx.guard.id) <> ":" <> int.to_string(id),
        )
      })
      |> controller.build(),
    )

  assert send(app, http.Delete, "/users/42", "").status == 401
  assert send(app, http.Delete, "/users/42", "member").status == 403
  assert testing.text(send(app, http.Delete, "/users/42", "admin")) == "9:42"
  assert send(app, http.Delete, "/users/nope", "member").status == 403
  assert send(app, http.Delete, "/users/nope", "admin").status == 400
}

pub fn guards_only_run_for_the_matched_route_test() {
  let app =
    howdy.new()
    |> howdy.controller(
      controller.guarded("private", fn(_) { panic as "unmatched guard ran" })
      |> controller.get("/", fn(ctx) { controller.text(ctx, "private") })
      |> controller.build(),
    )
    |> howdy.controller(
      controller.new("public")
      |> controller.get("/", fn(ctx) { controller.text(ctx, "public") }),
    )

  assert send(app, http.Get, "/missing", "").status == 404
  assert send(app, http.Post, "/private", "").status == 405
  assert testing.text(send(app, http.Get, "/public", "")) == "public"
}

pub fn differently_typed_controllers_can_share_an_app_test() {
  let app =
    howdy.new()
    |> howdy.controller(
      controller.guarded("user", authenticated)
      |> controller.get("/", fn(ctx) {
        controller.text(ctx, int.to_string(ctx.guard.id))
      })
      |> controller.build(),
    )
    |> howdy.controller(
      controller.guarded("key", fn(_) { Ok("accepted") })
      |> controller.get("/", fn(ctx) { controller.text(ctx, ctx.guard) })
      |> controller.build(),
    )

  assert testing.text(send(app, http.Get, "/user", "member")) == "7"
  assert testing.text(send(app, http.Get, "/key", "")) == "accepted"
}

pub fn middleware_wraps_guards_and_observes_rejections_test() {
  let app =
    howdy.new()
    |> howdy.middleware(fn(ctx, next) {
      let ctx = context_with_token(ctx)
      next(ctx) |> response.set_header("x-app", "ran")
    })
    |> howdy.controller(
      controller.guarded("users", fn(ctx) {
        let assert Ok("member") =
          request.get_header(ctx.request, "authorization")
        Error(service.Forbidden)
      })
      |> controller.get("/", fn(_) { panic as "handler ran" })
      |> controller.middleware(fn(ctx, next) {
        next(ctx) |> response.set_header("x-controller", "ran")
      })
      |> controller.build(),
    )

  let denied = send(app, http.Get, "/users", "")
  assert denied.status == 403
  assert response.get_header(denied, "x-controller") == Ok("ran")
  assert response.get_header(denied, "x-app") == Ok("ran")
}

fn context_with_token(ctx: controller.Context) {
  // Middleware transformations are visible to guards.
  context.Context(
    ..ctx,
    request: request.set_header(ctx.request, "authorization", "member"),
  )
}

pub fn body_validation_and_service_helpers_accept_guarded_contexts_test() {
  let app =
    howdy.new()
    |> howdy.controller(
      controller.guarded("users", authenticated)
      |> controller.post("/", fn(ctx) {
        use name <- body.json(ctx, decode.string)
        use name <- validate.check(ctx, Ok(name))
        Ok(name <> int.to_string(ctx.guard.id))
        |> service.created(ctx, json.string)
      })
      |> controller.build(),
    )

  let res =
    testing.post("/users", json.string("Ada"))
    |> testing.header("authorization", "member")
    |> testing.send(app)
  assert res.status == 201
  assert testing.json(res, decode.string) == Ok("Ada7")
}

pub fn build_does_not_remove_protection_from_later_routes_test() {
  let app =
    howdy.new()
    |> howdy.controller(
      controller.guarded("users", authenticated)
      |> controller.get("/before", fn(ctx) {
        controller.text(ctx, int.to_string(ctx.guard.id))
      })
      |> controller.build()
      |> controller.get("/after", fn(ctx) { controller.text(ctx, "protected") }),
    )

  assert send(app, http.Get, "/users/before", "").status == 401
  assert send(app, http.Get, "/users/after", "").status == 401
  assert send(app, http.Get, "/users/after", "member").status == 200
}
