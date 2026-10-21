import gleam/erlang/process
import gleam/otp/static_supervisor as supervisor
import howdy
import howdy/controller
import howdy/websocket

@external(erlang, "howdy_test_ffi", "open_websocket")
fn open_websocket(port: Int) -> Socket

@external(erlang, "howdy_test_ffi", "receive_close_frame")
fn receive_close_frame(socket: Socket) -> Result(Int, String)

@external(erlang, "howdy_test_ffi", "socket_closed")
fn socket_closed(socket: Socket) -> Bool

@external(erlang, "howdy_test_ffi", "tcp_connect")
fn tcp_connect(port: Int) -> Result(Socket, Nil)

type Socket

fn app() -> howdy.App {
  howdy.new()
  |> howdy.bind("127.0.0.1")
  |> howdy.listening(on: 0)
  |> howdy.shutdown_timeout(2000)
  |> howdy.controller(
    controller.new("/")
    |> controller.get("/", fn(ctx) { controller.text(ctx, "ok") })
    |> controller.get("/ws", fn(ctx) {
      websocket.new(fn(_) { Nil }) |> websocket.upgrade(ctx)
    }),
  )
}

// A supervised server is restarted by its supervisor, and the calling
// process is not linked to it.
pub fn supervised_server_is_restarted_test() {
  let assert Ok(sup) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(howdy.supervised(app()))
    |> supervisor.start
  process.unlink(sup.pid)

  let assert Ok(_) = server_pid(sup.pid)
  let assert Ok(first) = server_pid(sup.pid)
  process.kill(first)
  // The supervisor restarts it under a new pid.
  let second = await_restart(sup.pid, first, 50)
  assert second != first

  howdy.stop(sup.pid)
  assert !process.is_alive(sup.pid)
}

// Stopping lets open connections finish: a WebSocket is told the server is
// going away before the socket closes.
pub fn stop_drains_open_websockets_test() {
  let assert Ok(started) = app() |> howdy.start
  let socket = open_websocket(started.data.port)

  howdy.stop(started.pid)

  assert receive_close_frame(socket) == Ok(1001)
  assert socket_closed(socket)
  assert !process.is_alive(started.pid)
  // The port is free again once stop returns.
  assert tcp_connect(started.data.port) == Error(Nil)
}

@external(erlang, "howdy_test_ffi", "single_child")
fn server_pid(supervisor: process.Pid) -> Result(process.Pid, Nil)

fn await_restart(
  supervisor: process.Pid,
  old: process.Pid,
  tries: Int,
) -> process.Pid {
  case server_pid(supervisor) {
    Ok(pid) if pid != old -> pid
    _ if tries > 0 -> {
      process.sleep(20)
      await_restart(supervisor, old, tries - 1)
    }
    _ -> panic as "server was not restarted"
  }
}

// A tree run as an application is stopped in order by the node: the server
// drains its WebSockets when the application stops.
pub fn application_stop_drains_connections_test() {
  let tree =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(howdy.supervised(app() |> howdy.listening(on: 18_791)))
  let assert Ok(root) = howdy.start_application(tree, name: "howdy_test_app")
  assert process.is_alive(root)
  // A second start of the same name is a no-op, not a crash.
  let assert Ok(same) = howdy.start_application(tree, name: "howdy_test_app")
  assert same == root
  // A name that belongs to a real package is refused.
  let assert Error(message) = howdy.start_application(tree, name: "howdy")
  assert message
    == "an application called howdy already exists; pick another name"

  let socket = open_websocket(18_791)
  howdy.stop_application("howdy_test_app")

  assert receive_close_frame(socket) == Ok(1001)
  assert socket_closed(socket)
  assert !process.is_alive(root)
  assert tcp_connect(18_791) == Error(Nil)
}
