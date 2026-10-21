//// Core has no OpenTelemetry SDK, so these check that tracing stays out of
//// the way. What spans record is tested in howdy_telemetry.

import gleam/option.{None}
import howdy
import howdy/controller.{type Context}
import howdy/testing
import howdy/trace

pub fn a_span_returns_what_its_body_returns_test() {
  let value =
    trace.span("work", [trace.string("a", "b"), trace.int("n", 1)], fn() {
      trace.set_attributes([trace.bool("done", True)])
      trace.event("halfway", [trace.float("progress", 0.5)])
      trace.set_error("not really")
      42
    })
  assert value == 42
}

pub fn nothing_is_recorded_without_an_sdk_test() {
  use <- trace.span("work", [])
  assert trace.is_recording() == False
  assert trace.trace_id() == None
  assert trace.traceparent() == None
  assert trace.inject([#("accept", "*/*")]) == [#("accept", "*/*")]
}

pub fn a_panic_still_reaches_the_caller_test() {
  let assert Error(_) =
    rescue(fn() { trace.span("work", [], fn() { panic as "boom" }) })
}

pub fn within_runs_in_a_captured_context_test() {
  let context = trace.context()
  assert trace.within(context, fn() { "ran" }) == "ran"
}

pub fn link_to_reads_a_traceparent_test() {
  let assert Ok(_) =
    trace.link_to("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")
  let assert Error(Nil) =
    trace.link_to("00-00000000000000000000000000000000-b7ad6b7169203331-01")
  let assert Error(Nil) =
    trace.link_to("00-0af7651916cd43dd-b7ad6b7169203331-01")
  let assert Error(Nil) = trace.link_to("not a traceparent")
}

pub fn requests_are_answered_as_before_test() {
  let app =
    howdy.new()
    |> howdy.controller(
      controller.new("users")
      |> controller.get("/:id", fn(ctx: Context) { controller.text(ctx, "hi") }),
    )
  let response =
    testing.get("/users/1")
    |> testing.header(
      "traceparent",
      "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
    )
    |> testing.send(app)
  assert response.status == 200
  assert testing.text(response) == "hi"
}

@external(erlang, "howdy_test_ffi", "catch_panic")
fn rescue(run: fn() -> a) -> Result(a, String)
