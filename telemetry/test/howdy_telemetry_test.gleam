import ewe
import gleam/erlang/process
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import howdy
import howdy/controller.{type Context}
import howdy/telemetry
import howdy/telemetry/recorder.{type Span}
import howdy/testing
import howdy/trace
import howdy/websocket
import logging

pub fn main() -> Nil {
  gleeunit.main()
}

/// Every test starts from the same place, whatever the one before left
/// behind: no SDK running and no collector named in the environment.
fn isolated(run: fn() -> Nil) -> Nil {
  reset()
  run()
  reset()
}

fn reset() -> Nil {
  telemetry.stop()
  unsetenv("OTEL_EXPORTER_OTLP_ENDPOINT")
  unsetenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")
  unsetenv("OTEL_SDK_DISABLED")
}

@external(erlang, "howdy_telemetry_test_ffi", "unsetenv")
fn unsetenv(name: String) -> Nil

/// Poll for something that another process is about to make true, rather
/// than sleeping a fixed time and hoping.
fn await(attempts: Int, check: fn() -> Result(a, Nil)) -> a {
  case check(), attempts {
    Ok(value), _ -> value
    Error(Nil), 0 -> panic as "condition not met in time"
    Error(Nil), _ -> {
      process.sleep(10)
      await(attempts - 1, check)
    }
  }
}

/// The traces the recorder holds once it has one with each root `name`.
fn await_traces(
  recorder: recorder.Recorder,
  names: List(String),
) -> List(recorder.Trace) {
  await(100, fn() {
    let traces = recorder.traces(recorder, limit: 10)
    let found = list.map(traces, fn(t) { t.root.name })
    case list.all(names, list.contains(found, _)) {
      True -> Ok(traces)
      False -> Error(Nil)
    }
  })
}

fn recording() -> recorder.Recorder {
  let recorder = recorder.new(keep: 50)
  let assert Ok(Nil) =
    telemetry.new("howdy-telemetry-test")
    |> telemetry.record(recorder)
    |> telemetry.start
  recorder
}

fn app() -> howdy.App {
  let users =
    controller.new("users")
    |> controller.get("/:id", fn(ctx: Context) {
      use <- trace.span("load user", [trace.string("user.id", "7")])
      trace.event("cache miss", [])
      controller.text(ctx, "user")
    })
    |> controller.get("/:id/crash", fn(_ctx: Context) { panic as "boom" })
    |> controller.get("/:id/broken", fn(ctx: Context) {
      response.Response(..controller.text(ctx, "down"), status: 503)
    })
    |> controller.get("/:id/logged", fn(ctx: Context) {
      logging.log(logging.Warning, "slow user")
      controller.text(ctx, "ok")
    })
  howdy.new() |> howdy.controller(users)
}

fn only_trace(recorder: recorder.Recorder) -> List(Span) {
  let assert [trace] = recorder.traces(recorder, limit: 10)
  let assert Ok(spans) = recorder.trace(recorder, trace.root.trace_id)
  spans
}

fn named(spans: List(Span), name: String) -> Span {
  let assert Ok(span) = list.find(spans, fn(span) { span.name == name })
  span
}

pub fn nothing_is_recorded_before_start_test() {
  use <- isolated()
  use <- trace.span("idle", [])
  assert trace.is_recording() == False
  assert trace.trace_id() == None
  assert trace.inject([]) == []
  let parent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
  let passed =
    trace.new("continued")
    |> trace.continue_from([#("traceparent", parent)])
    |> trace.run(fn() { trace.inject([]) })
  assert passed == [#("traceparent", parent)]
}

pub fn a_request_is_a_server_span_named_after_its_route_test() {
  use <- isolated()
  let recorder = recording()
  let response = testing.get("/users/7") |> testing.send(app())
  assert response.status == 200

  let spans = only_trace(recorder)
  let server = named(spans, "GET /users/:id")
  assert server.kind == trace.Server
  assert server.parent_id == None
  assert recorder.attribute(server, "http.route")
    == Some(recorder.Text("/users/:id"))
  assert recorder.attribute(server, "url.path")
    == Some(recorder.Text("/users/7"))
  assert recorder.attribute(server, "http.response.status_code")
    == Some(recorder.Integer(200))
  assert server.status == recorder.Unset

  let child = named(spans, "load user")
  assert child.parent_id == Some(server.span_id)
  assert child.trace_id == server.trace_id
  assert recorder.attribute(child, "user.id") == Some(recorder.Text("7"))
  let assert [event] = child.events
  assert event.name == "cache miss"
}

pub fn an_unmatched_request_is_named_after_its_method_test() {
  use <- isolated()
  let recorder = recording()
  let response = testing.get("/nowhere") |> testing.send(app())
  assert response.status == 404
  let assert [span] = only_trace(recorder)
  assert span.name == "GET"
  assert recorder.attribute(span, "http.route") == None
}

pub fn a_server_error_fails_the_span_test() {
  use <- isolated()
  let recorder = recording()
  let _ = testing.get("/users/7/broken") |> testing.send(app())
  let assert [span] = only_trace(recorder)
  assert span.status == recorder.Failed("HTTP 503")
  assert recorder.attribute(span, "error.type") == Some(recorder.Text("503"))
}

pub fn a_panic_is_recorded_and_carries_on_test() {
  use <- isolated()
  let recorder = recording()
  let assert Error(_) =
    rescue(fn() { testing.get("/users/7/crash") |> testing.send(app()) })
  let assert [span] = only_trace(recorder)
  assert span.status == recorder.Failed("boom")
  let assert [exception] = span.events
  assert exception.name == "exception"
}

pub fn an_incoming_traceparent_is_continued_test() {
  use <- isolated()
  let recorder = recording()
  let parent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
  let _ =
    testing.get("/users/7")
    |> testing.header("traceparent", parent)
    |> testing.send(app())
  let spans = only_trace(recorder)
  let server = named(spans, "GET /users/:id")
  assert server.trace_id == "0af7651916cd43dd8448eb211c80319c"
  assert server.parent_id == Some("b7ad6b7169203331")
}

pub fn inject_writes_the_current_span_test() {
  use <- isolated()
  let _ = recording()
  use <- trace.span("outgoing", [])
  let assert Some(trace_id) = trace.trace_id()
  let assert Ok(header) = list.key_find(trace.inject([]), "traceparent")
  assert string.contains(header, trace_id)
  assert trace.traceparent() == Some(header)
}

pub fn a_link_points_at_another_trace_test() {
  use <- isolated()
  let recorder = recording()
  let parent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
  let assert Ok(link) = trace.link_to(parent)
  trace.new("worker") |> trace.link(link) |> trace.run(fn() { Nil })
  let assert [span] = only_trace(recorder)
  assert span.links
    == [#("0af7651916cd43dd8448eb211c80319c", "b7ad6b7169203331")]
  assert trace.link_to("00-nothex-b7ad6b7169203331-01") == Error(Nil)
  assert trace.link_to("junk") == Error(Nil)
}

pub fn context_carries_a_span_into_another_process_test() {
  use <- isolated()
  let recorder = recording()
  use <- trace.span("parent", [])
  let context = trace.context()
  let done = process.new_subject()
  process.spawn(fn() {
    trace.within(context, fn() { trace.span("child", [], fn() { Nil }) })
    process.send(done, Nil)
  })
  let assert Ok(Nil) = process.receive(done, 1000)
  let assert Some(trace_id) = trace.trace_id()
  let assert Ok(spans) = recorder.trace(recorder, trace_id)
  let assert [child] = spans
  assert child.name == "child"
}

pub fn logs_are_tied_to_their_trace_test() {
  use <- isolated()
  let recorder = recording()
  let _ = testing.get("/users/7/logged") |> testing.send(app())
  let assert [span] = only_trace(recorder)
  let assert [log] = recorder.logs(recorder, span.trace_id)
  assert log.message == "slow user"
  assert log.level == "warning"
  assert log.span_id == Some(span.span_id)
  let assert Ok(event) = list.find(span.events, fn(e) { e.name == "log" })
  assert list.key_find(event.attributes, "log.message")
    == Ok(recorder.Text("slow user"))
}

pub fn old_traces_are_dropped_test() {
  use <- isolated()
  let recorder = recorder.new(keep: 3)
  let assert Ok(Nil) =
    telemetry.new("howdy-telemetry-test")
    |> telemetry.record(recorder)
    |> telemetry.start
  let before = recorder.version(recorder)
  list.each([1, 2, 3, 4, 5], fn(i) {
    trace.span("t" <> string.inspect(i), [], fn() { Nil })
  })
  let names =
    recorder.traces(recorder, limit: 10) |> list.map(fn(t) { t.root.name })
  assert names == ["t5", "t4", "t3"]
  assert recorder.version(recorder) == before + 5
  recorder.clear(recorder)
  assert recorder.traces(recorder, limit: 10) == []
}

pub fn stop_puts_the_log_formatter_back_test() {
  use <- isolated()
  let before = default_formatter()
  let assert Ok(Nil) =
    telemetry.new("howdy-telemetry-test")
    |> telemetry.json_logs
    |> telemetry.start
  assert default_formatter() == "howdy_telemetry_json"
  telemetry.stop()
  assert default_formatter() == before
}

@external(erlang, "howdy_telemetry_test_ffi", "default_formatter")
fn default_formatter() -> String

pub fn stop_goes_back_to_idle_test() {
  use <- isolated()
  let recorder = recording()
  telemetry.stop()
  trace.span("after stop", [], fn() { Nil })
  assert recorder.traces(recorder, limit: 10) == []
}

@external(erlang, "howdy_telemetry_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, Nil)

pub fn websocket_frames_are_spans_linked_to_the_upgrade_test() {
  use <- isolated()
  let recorder = recording()
  let socket =
    websocket.new(fn(_socket) { Nil })
    |> websocket.on_text(fn(socket, state, text) {
      trace.span("echo", [], fn() {
        let _ = websocket.send_text(socket, text)
        Nil
      })
      websocket.continue(state)
    })
  let app =
    howdy.new()
    |> howdy.controller(
      controller.new("ws")
      |> controller.get("/", fn(ctx: Context) { websocket.upgrade(socket, ctx) }),
    )
  let assert Ok(started) =
    ewe.new(handler: howdy.handler(app))
    |> ewe.bind("127.0.0.1")
    |> ewe.listening(0)
    |> ewe.quiet
    |> ewe.start
  let assert ewe.TcpSocketAddress(_, port) = started.data
  let _ = websocket_roundtrip(port, "/ws", "hello")
  let traces = await_traces(recorder, ["GET /ws", "websocket text"])
  let assert Ok(upgrade) = list.find(traces, fn(t) { t.root.name == "GET /ws" })
  let assert Ok(frame) =
    list.find(traces, fn(t) { t.root.name == "websocket text" })
  assert frame.root.kind == trace.Server
  assert frame.root.links == [#(upgrade.root.trace_id, upgrade.root.span_id)]
  assert frame.spans == 2
}

@external(erlang, "howdy_telemetry_test_ffi", "websocket_roundtrip")
fn websocket_roundtrip(port: Int, path: String, text: String) -> BitArray

pub fn a_crash_outside_a_span_is_recorded_test() {
  use <- isolated()
  let recorder = recording()
  crash_process("hunter2")
  let assert Ok(crash) =
    await_traces(recorder, ["process crash"])
    |> list.find(fn(t) { t.root.name == "process crash" })
  assert crash.root.status == recorder.Failed("process crashed")
  assert recorder.attribute(crash.root, "exception.type")
    == Some(recorder.Text("error"))
  let assert Some(recorder.Text(message)) =
    recorder.attribute(crash.root, "exception.message")
  assert string.contains(message, "badarg")
  let assert [log] = recorder.logs(recorder, crash.root.trace_id)
  assert log.level == "error"
}

pub fn a_crash_report_keeps_its_secrets_off_the_span_test() {
  use <- isolated()
  let recorder = recording()
  crash_process("s3cret-token")
  let assert Ok(crash) =
    await_traces(recorder, ["process crash"])
    |> list.find(fn(t) { t.root.name == "process crash" })
  let assert Ok(spans) = recorder.trace(recorder, crash.root.trace_id)
  list.each(spans, fn(span) {
    list.each(span.attributes, fn(attribute) {
      assert !string.contains(
        recorder.value_to_string(attribute.1),
        "s3cret-token",
      )
    })
    list.each(span.events, fn(event) {
      list.each(event.attributes, fn(attribute) {
        assert !string.contains(
          recorder.value_to_string(attribute.1),
          "s3cret-token",
        )
      })
    })
  })
  // The full report still reaches the dev admin's log, as the console gets.
  let assert [log] = recorder.logs(recorder, crash.root.trace_id)
  assert string.contains(log.message, "s3cret-token")
}

@external(erlang, "howdy_telemetry_test_ffi", "crash_process")
fn crash_process(secret: String) -> Nil

pub fn a_recorder_is_owned_by_a_supervised_process_test() {
  use <- isolated()
  let before = recorder_owners()
  let holder = hold_recorder(10)
  assert recorder_owners() == before + 1
  release(holder)
  await(100, fn() {
    case recorder_owners() == before {
      True -> Ok(Nil)
      False -> Error(Nil)
    }
  })
}

@external(erlang, "howdy_telemetry_test_ffi", "recorder_owners")
fn recorder_owners() -> Int

@external(erlang, "howdy_telemetry_test_ffi", "hold_recorder")
fn hold_recorder(keep: Int) -> process.Pid

@external(erlang, "howdy_telemetry_test_ffi", "release")
fn release(holder: process.Pid) -> Nil

pub fn from_env_needs_a_collector_test() {
  use <- isolated()
  assert telemetry.from_env("svc") == Error(Nil)
  // An empty variable is as good as an unset one.
  putenv("OTEL_EXPORTER_OTLP_ENDPOINT", "")
  putenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "")
  assert telemetry.from_env("svc") == Error(Nil)
  putenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")
  assert telemetry.from_env("svc") != Error(Nil)
}

pub fn a_log_line_nobody_will_see_is_not_formatted_test() {
  use <- isolated()
  // No SDK, no span, no recorder: the handler returns before formatting.
  assert !handler_formats("warning", [])
  let recorder = recording()
  // Inside a recording span, only lines that become span events are
  // formatted when no recorder keeps the rest.
  trace.span("logging", [], fn() {
    assert !handler_formats("info", [])
    assert handler_formats("warning", [])
  })
  // A recorder wants every line, span or not.
  assert handler_formats("info", [recorder])
}

@external(erlang, "howdy_telemetry_test_ffi", "handler_formats")
fn handler_formats(level: String, recorders: List(recorder.Recorder)) -> Bool

@external(erlang, "howdy_telemetry_test_ffi", "putenv")
fn putenv(name: String, value: String) -> Nil
