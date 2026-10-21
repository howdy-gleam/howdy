import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/json
import gleam/string
import howdy
import howdy/controller
import howdy/testing
import howdy/ui
import howdy/ui/button
import howdy/ui/live
import lustre
import lustre/element.{text}
import lustre/event
import lustre/server_component
import lustre/vdom/vattr

type Msg {
  Increment
}

fn counter() -> lustre.App(Int, Int, Msg) {
  lustre.simple(
    init: fn(start) { start },
    update: fn(count, msg) {
      case msg {
        Increment -> count + 1
      }
    },
    view: fn(count) {
      ui.card([], [
        ui.h2("Count: " <> string.inspect(count)),
        ui.button(button.Primary, [event.on_click(Increment)], [text("+")]),
      ])
    },
  )
}

fn app() -> howdy.App {
  howdy.new()
  |> howdy.controller(
    controller.new("/counter")
    |> controller.get("/", fn(ctx) { live.serve(ctx, counter(), with: 0) }),
  )
}

pub fn socket_route_needs_a_real_connection_test() {
  let res = testing.get("/counter") |> testing.send(app())
  assert res.status == 426
}

pub fn runtime_sends_a_styled_mount_then_patches_test() {
  let assert Ok(runtime) = live.start(counter(), with: 5)
  let inbox = process.new_subject()
  lustre.send(runtime, server_component.register_subject(inbox))

  let assert Ok(mount) = process.receive(inbox, 1000)
  let mount = json.to_string(server_component.client_message_to_json(mount))
  assert string.contains(mount, "Count: 5")
  // The component's own <style> node carries the CSS for the classes its
  // view used into its shadow root, and nothing else.
  assert string.contains(mount, "background: var(--howdy-primary)")
  assert string.contains(mount, "border-radius: var(--howdy-radius-large)")
  assert !string.contains(mount, "::placeholder")

  live.dispatch(runtime, Increment)
  let assert Ok(patch) = process.receive(inbox, 1000)
  let patch = json.to_string(server_component.client_message_to_json(patch))
  assert string.contains(patch, "Count: 6")

  lustre.send(runtime, lustre.shutdown())
}

// -- Form value decoders ------------------------------------------------------

type FormMsg {
  PlanChosen(String)
  TagsChosen(List(String))
}

fn handler(
  attribute: vattr.Attribute(msg),
) -> #(String, decode.Decoder(vattr.Handler(msg)), List(String)) {
  let assert vattr.Event(name:, handler:, include:, ..) = attribute
  #(name, handler, include)
}

fn event(json_text: String) -> decode.Dynamic {
  let assert Ok(dynamic) = json.parse(json_text, decode.dynamic)
  dynamic
}

pub fn on_value_hears_only_the_named_control_test() {
  let #(name, decoder, include) = handler(live.on_value("plan", PlanChosen))
  assert name == "change"
  // The client is told which event properties to send along.
  assert include == ["target.name", "target.value"]
  let assert Ok(vattr.Handler(message: PlanChosen("pro"), ..)) =
    decode.run(
      event("{\"target\":{\"name\":\"plan\",\"value\":\"pro\"}}"),
      decoder,
    )
  // A change to another control in the same container is not a message.
  let assert Error(_) =
    decode.run(
      event("{\"target\":{\"name\":\"seats\",\"value\":\"3\"}}"),
      decoder,
    )
  let assert Error(_) =
    decode.run(event("{\"target\":{\"value\":\"pro\"}}"), decoder)
  Nil
}

pub fn on_values_hears_every_value_of_the_named_control_test() {
  let #(name, decoder, include) = handler(live.on_values("tags", TagsChosen))
  assert name == "howdy-values"
  assert include == ["detail.name", "detail.values"]
  let assert Ok(vattr.Handler(message: TagsChosen(["a", "b"]), ..)) =
    decode.run(
      event("{\"detail\":{\"name\":\"tags\",\"values\":[\"a\",\"b\"]}}"),
      decoder,
    )
  let assert Ok(vattr.Handler(message: TagsChosen([]), ..)) =
    decode.run(event("{\"detail\":{\"name\":\"tags\",\"values\":[]}}"), decoder)
  let assert Error(_) =
    decode.run(
      event("{\"detail\":{\"name\":\"other\",\"values\":[\"a\"]}}"),
      decoder,
    )
  let assert Error(_) =
    decode.run(
      event("{\"detail\":{\"name\":\"tags\",\"values\":\"a\"}}"),
      decoder,
    )
  Nil
}

// -- Socket close paths --------------------------------------------------------

type RawSocket

@external(erlang, "live_socket_test_ffi", "open_websocket")
fn open_websocket(port: Int, path: String) -> RawSocket

@external(erlang, "live_socket_test_ffi", "receive_text")
fn receive_text(socket: RawSocket) -> Result(BitArray, String)

@external(erlang, "live_socket_test_ffi", "close_socket")
fn close_socket(socket: RawSocket) -> Nil

/// A counter whose runtime reports its own pid on start, so a test can
/// watch what a socket closing does to it.
fn reporting_counter() -> lustre.App(Subject(Pid), Int, Msg) {
  lustre.simple(
    init: fn(report) {
      process.send(report, process.self())
      0
    },
    update: fn(count, msg) {
      case msg {
        Increment -> count + 1
      }
    },
    view: fn(count) { ui.h2("Count: " <> string.inspect(count)) },
  )
}

fn start_server(app: howdy.App) -> #(Pid, Int) {
  let assert Ok(started) =
    app
    |> howdy.bind("127.0.0.1")
    |> howdy.listening(on: 0)
    |> howdy.start
  #(started.pid, started.data.port)
}

fn stop_server(pid: Pid) -> Nil {
  howdy.stop(pid)
}

fn await_down(pid: Pid) -> Nil {
  let monitor = process.monitor(pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
  let assert Ok(Nil) = process.selector_receive(selector, 2000)
    as "the runtime should stop when its socket closes"
  Nil
}

pub fn closing_a_socket_shuts_its_own_runtime_down_test() {
  let report = process.new_subject()
  let #(server, port) =
    start_server(
      howdy.new()
      |> howdy.controller(
        controller.new("/counter")
        |> controller.get("/", fn(ctx) {
          live.serve(ctx, reporting_counter(), with: report)
        }),
      ),
    )
  let socket = open_websocket(port, "/counter")
  // The socket started a runtime of its own and sent its first render.
  let assert Ok(runtime) = process.receive(report, 2000)
  let assert Ok(_mount) = receive_text(socket)
  assert process.is_alive(runtime)

  close_socket(socket)
  await_down(runtime)
  stop_server(server)
}

pub fn closing_a_socket_leaves_a_shared_runtime_running_test() {
  let report = process.new_subject()
  let assert Ok(runtime) = live.start(reporting_counter(), with: report)
  let assert Ok(runtime_pid) = process.receive(report, 2000)
  let #(server, port) =
    start_server(
      howdy.new()
      |> howdy.controller(
        controller.new("/shared")
        |> controller.get("/", fn(ctx) { live.serve_shared(ctx, runtime) }),
      ),
    )
  let first = open_websocket(port, "/shared")
  let assert Ok(_mount) = receive_text(first)
  close_socket(first)

  // The runtime is only detached from the closed socket: it is alive, its
  // model is kept, and it still serves the next connection and any
  // subject registered directly.
  process.sleep(50)
  assert process.is_alive(runtime_pid)
  live.dispatch(runtime, Increment)
  let inbox = process.new_subject()
  lustre.send(runtime, server_component.register_subject(inbox))
  let assert Ok(mount) = process.receive(inbox, 2000)
  let mount = json.to_string(server_component.client_message_to_json(mount))
  assert string.contains(mount, "Count: 1")

  let second = open_websocket(port, "/shared")
  let assert Ok(_mount) = receive_text(second)
  close_socket(second)
  process.sleep(50)
  assert process.is_alive(runtime_pid)

  stop_server(server)
  lustre.send(runtime, lustre.shutdown())
}
