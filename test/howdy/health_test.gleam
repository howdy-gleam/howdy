import gleam/erlang/process
import gleam/http
import gleam/http/response
import howdy
import howdy/controller.{type Context}
import howdy/health
import howdy/middleware.{type Next}
import howdy/service
import howdy/testing

fn app(check: health.Health) -> howdy.App {
  howdy.new()
  |> howdy.controller(
    controller.new("pages")
    |> controller.get("/", fn(ctx: Context) { controller.text(ctx, "home") }),
  )
  |> howdy.health_check(check)
}

fn up(app: howdy.App) {
  testing.get("/up") |> testing.send(app)
}

fn failing() -> Result(Nil, String) {
  Error("connection refused")
}

fn passing() -> Result(Nil, String) {
  Ok(Nil)
}

pub fn answers_ok_at_up_test() {
  let res = up(app(health.new()))
  assert res.status == 200
  assert testing.text(res) == "{\"status\":\"ok\"}"
  assert response.get_header(res, "content-type")
    == Ok("application/json; charset=utf-8")
  assert response.get_header(res, "cache-control") == Ok("no-store")
}

pub fn answers_head_test() {
  let res = testing.request(http.Head, "/up") |> testing.send(app(health.new()))
  assert res.status == 200
}

pub fn is_not_there_unless_mounted_test() {
  let res = testing.get("/up") |> testing.send(howdy.new())
  assert res.status == 404
}

pub fn other_methods_are_routed_as_usual_test() {
  let res = testing.post_form("/up", []) |> testing.send(app(health.new()))
  assert res.status == 404
}

pub fn other_paths_are_routed_as_usual_test() {
  let app = app(health.new())
  assert testing.text(testing.get("/pages") |> testing.send(app)) == "home"
  assert { testing.get("/up/more") |> testing.send(app) }.status == 404
}

pub fn app_middleware_cannot_turn_it_away_test() {
  let reject = fn(ctx: Context, _next: Next) {
    service.error_response(ctx, service.Unauthorized)
  }
  let app = app(health.new()) |> howdy.middleware(reject)
  assert { testing.get("/pages") |> testing.send(app) }.status == 401
  assert up(app).status == 200
}

pub fn it_comes_before_a_route_at_the_same_path_test() {
  let app =
    howdy.new()
    |> howdy.controller(
      controller.new("up")
      |> controller.get("/", fn(ctx: Context) { controller.text(ctx, "mine") }),
    )
    |> howdy.health_check(health.new())
  assert testing.text(up(app)) == "{\"status\":\"ok\"}"
}

pub fn answers_at_another_path_test() {
  let app = app(health.new() |> health.at("/healthz"))
  assert { testing.get("/healthz") |> testing.send(app) }.status == 200
  assert up(app).status == 404
}

pub fn several_can_be_mounted_test() {
  let app =
    app(health.new() |> health.at("/live"))
    |> howdy.health_check(
      health.new()
      |> health.at("/ready")
      |> health.check("database", failing),
    )
  assert { testing.get("/live") |> testing.send(app) }.status == 200
  assert { testing.get("/ready") |> testing.send(app) }.status == 503
}

pub fn the_first_at_a_path_answers_test() {
  let app =
    app(health.new())
    |> howdy.health_check(health.new() |> health.check("database", failing))
  assert up(app).status == 200
}

pub fn a_path_must_start_with_a_slash_test() {
  assert rescue(fn() { health.new() |> health.at("up") }) |> is_error
}

pub fn check_names_must_be_unique_test() {
  let duplicate = fn() {
    health.new()
    |> health.check("database", passing)
    |> health.check("database", passing)
  }
  assert rescue(duplicate) |> is_error
}

pub fn passing_checks_are_listed_test() {
  let res =
    health.new()
    |> health.check("database", passing)
    |> health.check("cache", passing)
    |> app
    |> up
  assert res.status == 200
  assert testing.text(res)
    == "{\"status\":\"ok\",\"checks\":{\"database\":\"ok\",\"cache\":\"ok\"}}"
}

pub fn a_failing_check_is_a_503_without_its_reason_test() {
  let res =
    health.new()
    |> health.check("database", failing)
    |> health.check("cache", passing)
    |> app
    |> up
  assert res.status == 503
  assert testing.text(res)
    == "{\"status\":\"error\",\"checks\":{\"database\":\"error\",\"cache\":\"ok\"}}"
}

pub fn a_crashing_check_fails_test() {
  let res =
    health.new()
    |> health.check("database", fn() { panic as "pool is gone" })
    |> app
    |> up
  assert res.status == 503
  assert testing.text(res)
    == "{\"status\":\"error\",\"checks\":{\"database\":\"error\"}}"
}

pub fn checks_run_at_the_same_time_test() {
  let slow = fn() {
    process.sleep(100)
    Ok(Nil)
  }
  let res =
    health.new()
    |> health.check("one", slow)
    |> health.check("two", slow)
    |> health.check("three", slow)
    |> health.timeout(250)
    |> app
    |> up
  assert res.status == 200
}

pub fn a_slow_check_times_out_and_is_stopped_test() {
  let finished = process.new_subject()
  let slow = fn() {
    process.sleep(200)
    process.send(finished, Nil)
    Ok(Nil)
  }
  let res =
    health.new()
    |> health.check("database", slow)
    |> health.check("cache", passing)
    |> health.timeout(20)
    |> app
    |> up
  assert res.status == 503
  assert testing.text(res)
    == "{\"status\":\"error\",\"checks\":{\"database\":\"timeout\",\"cache\":\"ok\"}}"
  assert process.receive(finished, 400) == Error(Nil)
}

pub fn late_checks_leave_nothing_in_the_mailbox_test() {
  // The caller is a connection process; a reply arriving after the
  // response must not be left for it to find.
  let barely_late = fn() {
    process.sleep(15)
    Ok(Nil)
  }
  let app =
    health.new()
    |> health.check("a", barely_late)
    |> health.check("b", barely_late)
    |> health.check("c", passing)
    |> health.timeout(15)
    |> app
  let _ = up(app)
  let _ = up(app)
  process.sleep(50)
  assert mailbox_size() == 0
}

fn is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}

@external(erlang, "howdy_test_ffi", "catch_panic")
fn rescue(run: fn() -> a) -> Result(a, String)

@external(erlang, "howdy_health_test_ffi", "mailbox_size")
fn mailbox_size() -> Int
