import gleam/erlang/process.{type Subject}
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import howdy
import howdy/controller.{type Context}
import howdy/sse
import howdy/stream
import howdy/testing
import howdy/websocket/channel

type Socket

@external(erlang, "howdy_sse_test_ffi", "open_get")
fn open_get(port: Int, path: String, headers: List(#(String, String))) -> Socket

@external(erlang, "howdy_sse_test_ffi", "recv_until")
fn recv_until(
  socket: Socket,
  needle: String,
  timeout: Int,
) -> Result(String, String)

@external(erlang, "howdy_sse_test_ffi", "recv_all")
fn recv_all(socket: Socket) -> String

@external(erlang, "howdy_sse_test_ffi", "close")
fn close(socket: Socket) -> Nil

@external(erlang, "howdy_sse_test_ffi", "elapsed")
fn elapsed(run: fn() -> a) -> Int

/// What the streams under test report back to the test.
type Report {
  Opened(Subject(String))
  Closed(Int)
}

/// An app with one event stream at `/events` on `topic`. A reconnecting
/// client is sent what it missed; messages to the stream's subject are sent
/// on as named events and `"stop"` ends it. Each stream reports to `reports`.
fn app(topic: String, reports: Subject(Report)) -> howdy.App {
  howdy.new()
  |> howdy.bind("127.0.0.1")
  |> howdy.listening(on: 0)
  |> howdy.shutdown_timeout(2000)
  |> howdy.controller(
    controller.new("/")
    |> controller.get("/events", fn(ctx: Context) {
      sse.new(fn(stream) {
        sse.join(stream, topic)
        case sse.last_event_id(stream) {
          Some(id) -> {
            let _ = sse.send(stream, sse.event("missed") |> sse.id(id <> "+1"))
            Nil
          }
          None -> Nil
        }
        process.send(reports, Opened(sse.subject(stream)))
        0
      })
      |> sse.heartbeat(50)
      |> sse.on_message(fn(stream, sent, message) {
        case message {
          "stop" -> sse.stop()
          _ -> {
            let assert Ok(Nil) =
              sse.send(stream, sse.event(message) |> sse.name("note"))
            sse.continue(sent + 1)
          }
        }
      })
      |> sse.on_close(fn(_stream, sent) { process.send(reports, Closed(sent)) })
      |> sse.start(ctx)
    })
    |> controller.get("/export", fn(_ctx) {
      response.new(200)
      |> response.set_header("content-type", "text/csv")
      |> stream.body(fn(writer) {
        use writer <- result.try(stream.send_text(writer, "id\n"))
        list.try_fold([1, 2, 3], writer, fn(writer, n) {
          stream.send_text(writer, string.inspect(n) <> "\n")
        })
      })
    })
    |> controller.get("/broken", fn(_ctx) {
      response.new(200)
      |> stream.body(fn(writer) {
        use _writer <- result.try(
          stream.send_text(writer, "partial")
          |> result.replace_error("the client went away"),
        )
        Error("the database went away")
      })
    }),
  )
}

fn await_size(topic: String, size: Int, tries: Int) -> Nil {
  case sse.size(topic) == size {
    True -> Nil
    False if tries > 0 -> {
      process.sleep(10)
      await_size(topic, size, tries - 1)
    }
    False -> panic as "topic size never settled"
  }
}

fn opened(reports: Subject(Report)) -> Subject(String) {
  let assert Ok(Opened(subject)) = process.receive(reports, 1000)
  subject
}

fn closed(reports: Subject(Report)) -> Int {
  let assert Ok(Closed(sent)) = process.receive(reports, 2000)
  sent
}

// -- Without a socket ---------------------------------------------------------

pub fn events_test() {
  assert sse.event("hi") |> sse.name("greeting") |> sse.id("1") |> sse.retry(5)
    == sse.Event(
      data: "hi",
      name: Some("greeting"),
      id: Some("1"),
      retry: Some(5),
    )
  assert sse.json(json.object([#("a", json.int(1))])) == sse.event("{\"a\":1}")
}

pub fn a_stream_runs_in_a_test_test() {
  let reports = process.new_subject()
  let res = testing.get("/events") |> testing.send(app("t:test", reports))
  assert res.status == 200

  let stream = testing.open_events(res)
  let subject = opened(reports)
  assert sse.size("t:test") == 1

  sse.broadcast("t:test", sse.event("everyone"))
  assert testing.next_event(stream) == Ok(sse.event("everyone"))
  process.send(subject, "just you")
  assert testing.next_event(stream)
    == Ok(sse.event("just you") |> sse.name("note"))
  assert testing.sent_events(stream) == []

  testing.close_events(stream)
  assert closed(reports) == 1
  // pg sees the stream's process exit a moment later.
  await_size("t:test", 0, 100)
}

pub fn a_reconnecting_client_gets_what_it_missed_test() {
  let reports = process.new_subject()
  let stream =
    testing.get("/events")
    |> testing.header("last-event-id", "41")
    |> testing.send(app("t:resume", reports))
    |> testing.open_events
  let _ = opened(reports)
  assert testing.sent_events(stream) == [sse.event("missed") |> sse.id("41+1")]
  testing.close_events(stream)
}

pub fn a_callback_can_stop_the_stream_test() {
  let reports = process.new_subject()
  let stream =
    testing.get("/events")
    |> testing.send(app("t:stop", reports))
    |> testing.open_events
  process.send(opened(reports), "stop")
  assert closed(reports) == 0
  // Closing a stream that already ended is fine.
  testing.close_events(stream)
}

pub fn topics_are_apart_from_websocket_channels_test() {
  let reports = process.new_subject()
  let stream =
    testing.get("/events")
    |> testing.send(app("shared-name", reports))
    |> testing.open_events
  let _ = opened(reports)
  assert sse.size("shared-name") == 1
  assert channel.size("shared-name") == 0
  channel.broadcast_text("shared-name", "a websocket frame")
  assert testing.next_event(stream) == Error(Nil)
  testing.close_events(stream)
}

pub fn a_streamed_body_is_read_in_full_in_a_test_test() {
  let res =
    testing.get("/export") |> testing.send(app("t:x", process.new_subject()))
  assert response.get_header(res, "content-type") == Ok("text/csv")
  assert testing.text(res) == "id\n1\n2\n3\n"
  // What was written before an error is still readable.
  let res =
    testing.get("/broken") |> testing.send(app("t:x", process.new_subject()))
  assert testing.text(res) == "partial"
}

// -- Over HTTP/1.1 ------------------------------------------------------------

pub fn a_live_stream_test() {
  let reports = process.new_subject()
  let assert Ok(started) = app("t:live", reports) |> howdy.start
  let socket = open_get(started.data.port, "/events", [])

  let assert Ok(head) = recv_until(socket, "\r\n\r\n", 2000)
  assert string.starts_with(head, "HTTP/1.1 200")
  let head = string.lowercase(head)
  assert string.contains(head, "content-type: text/event-stream")
  assert string.contains(head, "x-accel-buffering: no")

  let subject = opened(reports)
  sse.broadcast("t:live", sse.event("one\ntwo") |> sse.id("7"))
  let assert Ok(body) = recv_until(socket, "data: two\n\n", 2000)
  assert string.contains(body, "id: 7\ndata: one\ndata: two\n\n")

  process.send(subject, "hi")
  let assert Ok(_) = recv_until(socket, "event: note\ndata: hi\n\n", 2000)
  // The heartbeat is an empty comment.
  let assert Ok(_) = recv_until(socket, ":", 2000)

  // A client that goes away is noticed, at the latest by the heartbeat.
  close(socket)
  assert closed(reports) == 1
  howdy.stop(started.pid)
}

pub fn last_event_id_is_read_from_the_header_test() {
  let reports = process.new_subject()
  let assert Ok(started) = app("t:live-resume", reports) |> howdy.start
  let socket = open_get(started.data.port, "/events", [#("last-event-id", "3")])
  let assert Ok(_) = recv_until(socket, "id: 3+1\ndata: missed\n\n", 2000)
  close(socket)
  howdy.stop(started.pid)
}

pub fn stopping_the_server_ends_open_streams_test() {
  let reports = process.new_subject()
  let assert Ok(started) = app("t:drain", reports) |> howdy.start
  let socket = open_get(started.data.port, "/events", [])
  let _ = opened(reports)

  // Well within the two second shutdown timeout: streams end at once
  // rather than holding the server up until it gives up on them.
  assert elapsed(fn() { howdy.stop(started.pid) }) < 1000
  assert closed(reports) == 0
  let _ = recv_all(socket)
}

pub fn a_live_streamed_body_test() {
  let assert Ok(started) = app("t:x", process.new_subject()) |> howdy.start
  let socket =
    open_get(started.data.port, "/export", [#("connection", "close")])
  let body = recv_all(socket)
  assert string.contains(string.lowercase(body), "transfer-encoding: chunked")
  assert string.ends_with(body, "2\r\n3\n\r\n0\r\n\r\n")

  // A body that fails part way is cut off, not finished.
  let socket = open_get(started.data.port, "/broken", [])
  let body = recv_all(socket)
  assert string.contains(body, "partial")
  assert !string.ends_with(body, "0\r\n\r\n")
  howdy.stop(started.pid)
}
