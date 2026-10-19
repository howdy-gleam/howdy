import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import howdy/problem
import howdy/remote
import howdy/service
import howdy_remote_fixtures.{User} as fixtures

// Every test uses its own procedure names: servers are registered in one
// cluster-wide scope and may outlive the test that started them.

@external(erlang, "howdy_remote_test_ffi", "crash")
fn crash() -> a

fn serve(prefix: String) -> Nil {
  let assert Ok(_) = remote.start(fixtures.users_server(prefix))
  Nil
}

pub fn call_returns_handler_output_test() {
  serve("local_ok")
  assert remote.call(
      remote.cluster(),
      fixtures.get_user("local_ok"),
      1,
      timeout: 1000,
    )
    == Ok(User(id: 1, name: "Ada"))
}

pub fn call_passes_service_errors_through_test() {
  serve("local_err")
  assert remote.call(
      remote.cluster(),
      fixtures.get_user("local_err"),
      2,
      timeout: 1000,
    )
    == Error(remote.Failed(service.NotFound("user not found")))
}

pub fn every_service_error_round_trips_test() {
  let echo_error =
    remote.procedure("errors.echo", input: remote.int(), output: remote.nil())
  let errors = [
    service.NotFound("gone"),
    service.Invalid("bad"),
    service.Conflict("taken"),
    service.Unauthorized,
    service.Forbidden,
    service.UnsupportedMediaType("application/json"),
    service.Validation([
      service.FieldError(
        field: "email",
        problem: problem.Custom("taken", "is taken"),
      ),
    ]),
    service.TooManyRequests(retry_after_seconds: 30),
    service.Coded("email_taken", service.Conflict("taken")),
  ]
  let assert Ok(_) =
    remote.server()
    |> remote.handle(echo_error, fn(index) {
      let assert Ok(error) = list.drop(errors, index) |> list.first
      Error(error)
    })
    |> remote.start
  list.index_map(errors, fn(error, index) {
    assert remote.call(remote.cluster(), echo_error, index, timeout: 1000)
      == Error(remote.Failed(error))
  })
}

pub fn internal_detail_stays_on_the_server_test() {
  let failing =
    remote.procedure("internal.fail", input: remote.nil(), output: remote.nil())
  let assert Ok(_) =
    remote.server()
    |> remote.handle(failing, fn(_) {
      Error(service.Internal("password=hunter2"))
    })
    |> remote.start
  assert remote.call(remote.cluster(), failing, Nil, timeout: 1000)
    == Error(remote.Failed(service.Internal("internal.fail failed remotely")))
}

pub fn missing_handler_test() {
  assert remote.call(
      remote.cluster(),
      fixtures.get_user("nobody_serves_this"),
      1,
      timeout: 1000,
    )
    == Error(remote.NoHandler("nobody_serves_this.users.get"))
  assert remote.call(
      remote.node(remote.self()),
      fixtures.get_user("nobody_serves_this"),
      1,
      timeout: 1000,
    )
    == Error(remote.NoHandler("nobody_serves_this.users.get"))
}

pub fn crashing_handler_test() {
  let crashing =
    remote.procedure("crash.now", input: remote.nil(), output: remote.nil())
  let assert Ok(_) =
    remote.server()
    |> remote.handle(crashing, fn(_) { crash() })
    |> remote.start
  let assert Error(remote.Crashed(reason)) =
    remote.call(remote.cluster(), crashing, Nil, timeout: 1000)
  assert reason != ""
  // The server survives a crashing handler.
  let assert Error(remote.Crashed(_)) =
    remote.call(remote.cluster(), crashing, Nil, timeout: 1000)
}

pub fn slow_handler_times_out_test() {
  let slow =
    remote.procedure("slow.sleep", input: remote.int(), output: remote.int())
  let assert Ok(_) =
    remote.server()
    |> remote.handle(slow, fn(ms) {
      process.sleep(ms)
      Ok(ms)
    })
    |> remote.start
  assert remote.call(remote.cluster(), slow, 500, timeout: 50)
    == Error(remote.Timeout)
  assert remote.call(remote.cluster(), slow, 0, timeout: 1000) == Ok(0)
}

pub fn calls_run_concurrently_test() {
  // Every handler waits at a gate that opens once all ten have arrived, so
  // the calls only succeed if they run side by side: run one after
  // another, the first would wait for the rest forever.
  let gate = gate(10)
  let meet =
    remote.procedure("meet.parallel", input: remote.nil(), output: remote.int())
  let assert Ok(_) =
    remote.server()
    |> remote.handle(meet, fn(_) { Ok(process.call(gate, 1000, Arrive)) })
    |> remote.start
  let reply = process.new_subject()
  list.each(list.repeat(Nil, 10), fn(_) {
    process.spawn(fn() {
      process.send(
        reply,
        remote.call(remote.cluster(), meet, Nil, timeout: 2000),
      )
    })
  })
  list.each(list.repeat(Nil, 10), fn(_) {
    assert process.receive(reply, 2000) == Ok(Ok(10))
  })
}

type Arrival {
  Arrive(reply: process.Subject(Int))
}

/// A gate that answers everyone at once, with how many arrived, when
/// `expected` have.
fn gate(expected: Int) -> process.Subject(Arrival) {
  let assert Ok(started) =
    actor.new([])
    |> actor.on_message(fn(waiting, arrival: Arrival) {
      let waiting = [arrival.reply, ..waiting]
      case list.length(waiting) >= expected {
        True -> {
          list.each(waiting, process.send(_, list.length(waiting)))
          actor.continue([])
        }
        False -> actor.continue(waiting)
      }
    })
    |> actor.start
  started.data
}

pub fn mismatched_output_is_a_bad_response_test() {
  serve("mismatch")
  let expecting_int =
    remote.procedure(
      "mismatch.users.get",
      input: remote.int(),
      output: remote.int(),
    )
  let assert Error(remote.BadResponse(reason)) =
    remote.call(remote.cluster(), expecting_int, 1, timeout: 1000)
  assert reason == "mismatch.users.get: expected Int, found Dict"
}

pub fn mismatched_input_is_invalid_test() {
  serve("bad_input")
  let sending_string =
    remote.procedure(
      "bad_input.users.get",
      input: remote.string(),
      output: fixtures.user(),
    )
  assert remote.call(remote.cluster(), sending_string, "1", timeout: 1000)
    == Error(
      remote.Failed(service.Invalid(
        "bad_input.users.get: expected Int, found String",
      )),
    )
}

pub fn cast_runs_without_waiting_test() {
  let seen = process.new_subject()
  let notify =
    remote.procedure(
      "cast.notify",
      input: remote.string(),
      output: remote.nil(),
    )
  let assert Ok(_) =
    remote.server()
    |> remote.handle(notify, fn(text) {
      process.send(seen, text)
      Ok(Nil)
    })
    |> remote.start
  remote.cast(remote.cluster(), notify, "hello")
  remote.cast(remote.node(remote.self()), notify, "again")
  // Each cast runs in its own process, so they may arrive in either order.
  let assert Ok(first) = process.receive(seen, 1000)
  let assert Ok(second) = process.receive(seen, 1000)
  assert list.sort([first, second], string.compare) == ["again", "hello"]
  // Casting to nobody does nothing, and does not wait to find that out.
  let took =
    elapsed_ms(fn() {
      remote.cast(remote.cluster(), fixtures.whoami("nobody_casts"), Nil)
    })
  assert took < 100
}

@external(erlang, "howdy_remote_test_ffi", "elapsed_ms")
fn elapsed_ms(run: fn() -> a) -> Int

pub fn the_scope_and_servers_are_supervised_test() {
  assert scope_supervised()
  let assert Ok(started) = remote.start(fixtures.users_server("supervised"))
  assert sys_aware(started.pid)
}

@external(erlang, "howdy_remote_test_ffi", "scope_supervised")
fn scope_supervised() -> Bool

@external(erlang, "howdy_remote_test_ffi", "sys_aware")
fn sys_aware(pid: process.Pid) -> Bool

pub fn multicall_and_providers_test() {
  serve("multi")
  assert remote.providers(fixtures.whoami("multi")) == [remote.self()]
  assert remote.multicall(fixtures.whoami("multi"), Nil, timeout: 1000)
    == [#(remote.self(), Ok(remote.self()))]
  assert remote.providers(fixtures.whoami("nobody_multi")) == []
  assert remote.multicall(fixtures.whoami("nobody_multi"), Nil, timeout: 1000)
    == []
}

pub fn stopped_server_leaves_the_cluster_test() {
  let assert Ok(started) = remote.start(fixtures.users_server("stopped"))
  process.unlink(started.pid)
  process.kill(started.pid)
  assert fixtures.await_no_provider(
    fixtures.whoami("stopped"),
    remote.self(),
    100,
  )
  assert remote.providers(fixtures.whoami("stopped")) == []
  assert remote.call(
      remote.cluster(),
      fixtures.whoami("stopped"),
      Nil,
      timeout: 1000,
    )
    == Error(remote.NoHandler("stopped.whoami"))
}

pub fn server_lists_procedures_test() {
  assert remote.procedures(fixtures.users_server("names"))
    == ["names.users.get", "names.whoami"]
}

pub fn apply_calls_plain_erlang_test() {
  assert remote.apply(
      on: remote.self(),
      module: "erlang",
      function: "abs",
      args: [dynamic.int(-4)],
      decoder: decode.int,
      timeout: 1000,
    )
    == Ok(4)
  assert remote.apply(
      on: remote.self(),
      module: "erlang",
      function: "abs",
      args: [dynamic.int(-4)],
      decoder: decode.string,
      timeout: 1000,
    )
    == Error(remote.BadResponse("erlang:abs returned a Int, expected String"))
  let assert Error(remote.Crashed(_)) =
    remote.apply(
      on: remote.self(),
      module: "erlang",
      function: "abs",
      args: [dynamic.string("x")],
      decoder: decode.int,
      timeout: 1000,
    )
}

pub fn names_that_are_not_node_names_are_refused_test() {
  // None of these may become an atom on a caller's say-so.
  list.each(["nope", "@host", "name@", "bad name@host", "a@b@c"], fn(name) {
    assert remote.connect(name)
      == Error(remote.Unavailable("not a node name: " <> name))
    assert remote.connect_to([name])
      == Error(remote.Unavailable("not a node name: " <> name))
    let assert Error(remote.Unavailable(_)) =
      remote.call(remote.node(name), fixtures.whoami("x"), Nil, timeout: 100)
    // A cast to it is dropped, without raising.
    remote.cast(remote.node(name), fixtures.whoami("x"), Nil)
  })
  let assert Error(remote.Unavailable(_)) =
    remote.connect(string.repeat("a", 250) <> "@host")
}

pub fn apply_refuses_a_module_or_function_this_node_has_never_seen_test() {
  let assert Error(remote.Crashed(reason)) =
    remote.apply(
      on: remote.self(),
      module: "howdy_remote_no_such_module_" <> string.inspect(erlang_unique()),
      function: "abs",
      args: [],
      decoder: decode.int,
      timeout: 1000,
    )
  assert string.contains(reason, "undef")
  let assert Error(remote.Crashed(reason)) =
    remote.apply(
      on: remote.self(),
      module: "erlang",
      function: "howdy_remote_no_such_function_"
        <> string.inspect(erlang_unique()),
      args: [],
      decoder: decode.int,
      timeout: 1000,
    )
  assert string.contains(reason, "undef")
}

@external(erlang, "erlang", "unique_integer")
fn erlang_unique() -> Int

pub fn codecs_round_trip_test() {
  let round_trip = fn(codec: remote.Codec(a), value: a) {
    json.parse(json.to_string(codec.encode(value)), codec.decoder)
  }
  assert round_trip(remote.int(), 3) == Ok(3)
  assert round_trip(remote.float(), 1.5) == Ok(1.5)
  assert round_trip(remote.bool(), True) == Ok(True)
  assert round_trip(remote.string(), "hi") == Ok("hi")
  assert round_trip(remote.nil(), Nil) == Ok(Nil)
  assert round_trip(remote.list(remote.int()), [1, 2]) == Ok([1, 2])
  assert round_trip(remote.optional(remote.int()), Some(1)) == Ok(Some(1))
  assert round_trip(remote.optional(remote.int()), None) == Ok(None)
}

pub fn to_service_error_test() {
  assert remote.to_service_error(remote.Failed(service.Forbidden))
    == service.Forbidden
  assert remote.to_service_error(remote.Timeout)
    == service.Internal("remote call timed out")
  assert remote.describe(remote.NoHandler("a.b")) == "no remote handler for a.b"
}
