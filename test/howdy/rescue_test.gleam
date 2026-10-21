import gleam/string
import howdy
import howdy/controller
import howdy/middleware
import howdy/testing

fn app() -> howdy.App {
  howdy.new()
  |> howdy.middleware(middleware.rescue)
  |> howdy.controller(
    controller.new("/")
    |> controller.get("/ok", fn(ctx) { controller.text(ctx, "fine") })
    |> controller.get("/boom", fn(_ctx) { panic as "handler exploded" }),
  )
}

pub fn a_crash_becomes_a_500_with_the_usual_error_body_test() {
  let res = testing.get("/boom") |> testing.send(app())
  assert res.status == 500
  assert string.contains(testing.text(res), "internal server error")
  // The panic's own words stay in the log, not the response.
  assert !string.contains(testing.text(res), "exploded")
}

pub fn rescue_leaves_working_handlers_alone_test() {
  let res = testing.get("/ok") |> testing.send(app())
  assert res.status == 200
  assert testing.text(res) == "fine"
}
