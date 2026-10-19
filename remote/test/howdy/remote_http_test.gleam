import ewe
import gleam/int
import gleam/list
import gleam/option.{Some}
import howdy
import howdy/codec
import howdy/remote
import howdy/service
import howdy/telemetry
import howdy/telemetry/recorder
import howdy/trace
import howdy_remote_fixtures.{User} as fixtures

@external(erlang, "howdy_remote_test_ffi", "crash")
fn crash() -> a

const token = "test-token-with-plenty-of-entropy"

fn crashing() -> remote.Procedure(Nil, Nil) {
  remote.procedure("http.crash", input: codec.nil(), output: codec.nil())
}

/// Serve the users procedures at `/rpc` on a free port and return the URL.
fn serve(token: String) -> String {
  let server =
    fixtures.users_server("http")
    |> remote.handle(crashing(), fn(_) { crash() })
  let assert Ok(started) =
    ewe.new(
      handler: howdy.new()
      |> howdy.controller(remote.controller(server, at: "/rpc", token:))
      |> howdy.handler,
    )
    |> ewe.bind("127.0.0.1")
    |> ewe.listening(0)
    |> ewe.quiet
    |> ewe.start
  let assert ewe.TcpSocketAddress(_, port) = started.data
  "http://127.0.0.1:" <> int.to_string(port) <> "/rpc"
}

pub fn http_call_test() {
  let target = remote.http(serve(token), token:)
  assert remote.call(target, fixtures.get_user("http"), 1, timeout: 2000)
    == Ok(User(id: 1, name: "Ada"))
  assert remote.call(target, fixtures.get_user("http"), 2, timeout: 2000)
    == Error(remote.Failed(service.NotFound("user not found")))
  assert remote.call(target, fixtures.whoami("http"), Nil, timeout: 2000)
    == Ok(remote.self())
}

pub fn http_trailing_slash_test() {
  let target = remote.http(serve(token) <> "/", token:)
  assert remote.call(target, fixtures.get_user("http"), 1, timeout: 2000)
    == Ok(User(id: 1, name: "Ada"))
}

pub fn http_wrong_token_is_refused_test() {
  let url = serve(token)
  assert remote.call(
      remote.http(url, token: "guess"),
      fixtures.get_user("http"),
      1,
      timeout: 2000,
    )
    == Error(remote.Refused)
  assert remote.call(
      remote.http(url, token: ""),
      fixtures.get_user("http"),
      1,
      timeout: 2000,
    )
    == Error(remote.Refused)
}

pub fn http_empty_server_token_refuses_everything_test() {
  assert remote.call(
      remote.http(serve(""), token: ""),
      fixtures.get_user("http"),
      1,
      timeout: 2000,
    )
    == Error(remote.Refused)
}

pub fn http_missing_handler_test() {
  assert remote.call(
      remote.http(serve(token), token:),
      fixtures.get_user("elsewhere"),
      1,
      timeout: 2000,
    )
    == Error(remote.NoHandler("elsewhere.users.get"))
}

pub fn http_crash_hides_detail_test() {
  assert remote.call(
      remote.http(serve(token), token:),
      crashing(),
      Nil,
      timeout: 2000,
    )
    == Error(remote.Crashed("see the serving node's log"))
}

pub fn http_unreachable_test() {
  let assert Error(remote.Unavailable(_)) =
    remote.call(
      remote.http("http://127.0.0.1:1/rpc", token:),
      fixtures.get_user("http"),
      1,
      timeout: 2000,
    )
}

pub fn http_call_continues_the_trace_test() {
  let target = remote.http(serve(token), token:)
  let recorder = recorder.new(keep: 10)
  let assert Ok(Nil) =
    telemetry.new("howdy-remote-test")
    |> telemetry.record(recorder)
    |> telemetry.start
  let trace_id = {
    use <- trace.span("caller", [])
    let assert Ok(_) =
      remote.call(target, fixtures.get_user("http"), 1, timeout: 2000)
    let assert Error(_) =
      remote.call(target, fixtures.get_user("http"), 2, timeout: 2000)
    let assert Some(id) = trace.trace_id()
    id
  }
  telemetry.stop()

  let assert Ok(spans) = recorder.trace(recorder, trace_id)
  let find = fn(kind, name) {
    list.filter(spans, fn(span) { span.kind == kind && span.name == name })
  }
  let assert [caller] = find(trace.Internal, "caller")
  let assert [client, _] = find(trace.Client, "http.users.get")
  assert client.parent_id == Some(caller.span_id)
  // A NotFound answer is a result, not a failure.
  assert list.all(find(trace.Client, "http.users.get"), fn(span) {
    span.status == recorder.Unset
  })
  let assert [server, _] = find(trace.Server, "POST /rpc/:procedure")
  assert server.parent_id == Some(client.span_id)
  let assert [procedure, _] = find(trace.Internal, "http.users.get")
  assert procedure.parent_id == Some(server.span_id)
}
