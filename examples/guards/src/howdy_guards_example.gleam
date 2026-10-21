//// A separate example of controller guards and endpoint guards.

import gleam/erlang/process
import gleam/int
import gleam/otp/static_supervisor as supervisor
import guards/auth
import guards/profile_service
import howdy
import howdy/controller
import howdy/guard
import howdy/param
import howdy/service

pub fn app() -> howdy.App {
  // Every route in this controller requires authentication.
  let account =
    controller.guarded("account", auth.authenticated)
    |> controller.get("/me", fn(ctx) {
      profile_service.find(ctx.guard)
      |> service.respond(ctx, profile_service.to_json)
    })
    |> controller.get("/admin/:id", fn(ctx) {
      // This endpoint also requires the authenticated user to be an admin.
      use _ <- guard.require(ctx, auth.admin)
      use id <- param.int(ctx, "id")
      controller.text(ctx, "Admin access to record " <> int.to_string(id))
    })
    |> controller.build()

  // This controller mixes a public route with one guarded endpoint.
  let public =
    controller.new("public")
    |> controller.get("/hello", fn(ctx) {
      controller.text(ctx, "Hello, anyone!")
    })
    |> controller.get("/me", fn(ctx) {
      use user <- guard.require(ctx, auth.authenticated)
      profile_service.find(user)
      |> service.respond(ctx, profile_service.to_json)
    })

  howdy.new()
  |> howdy.controller(account)
  |> howdy.controller(public)
}

pub fn main() -> Nil {
  let server =
    app()
    |> howdy.bind(to: "127.0.0.1")
    |> howdy.listening(on: 8788)
  // Supervised inside an OTP application: restarted on a crash, drained on
  // SIGTERM.
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(howdy.supervised(server))
    |> howdy.start_application(name: "howdy_guards_server")

  process.sleep_forever()
}
