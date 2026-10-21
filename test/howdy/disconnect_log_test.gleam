import gleam/erlang/process.{type Pid}
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/supervision
import howdy
import howdy/controller
import howdy/websocket

@external(erlang, "disconnect_log_ffi", "with_captured_reports")
fn with_captured_reports(server: Pid, run: fn() -> a) -> Int

@external(erlang, "disconnect_log_ffi", "drop_mid_close")
fn drop_mid_close(port: Int) -> Nil

@external(erlang, "disconnect_log_ffi", "exit_with")
fn exit_with(pid: Pid, reason: String) -> Nil

fn start_server() -> #(Pid, Int) {
  let assert Ok(started) =
    howdy.new()
    |> howdy.bind("127.0.0.1")
    |> howdy.listening(on: 0)
    |> howdy.controller(
      controller.new("/ws")
      |> controller.get("/", fn(ctx) {
        websocket.new(fn(_) { Nil }) |> websocket.upgrade(ctx)
      }),
    )
    |> howdy.start
  #(started.pid, started.data.port)
}

fn stop_server(pid: Pid) -> Nil {
  process.unlink(pid)
  process.send_abnormal_exit(pid, "test over")
}

// A client hanging up mid close handshake is not a crash. This also guards
// against an ewe upgrade rewording the socket errors the filter matches.
pub fn clients_leaving_mid_write_are_not_reported_test() {
  let #(pid, port) = start_server()
  let reports = with_captured_reports(pid, fn() { drop_mid_close(port) })
  stop_server(pid)
  assert reports == 0
}

pub fn other_connection_crashes_are_still_reported_test() {
  let #(pid, _port) = start_server()
  let assert Ok(started) =
    factory.worker_child(fn(_) {
      let child = process.spawn(fn() { process.sleep_forever() })
      Ok(actor.Started(pid: child, data: Nil))
    })
    |> factory.restart_strategy(supervision.Temporary)
    |> factory.start
  process.unlink(started.pid)
  let reports =
    with_captured_reports(started.pid, fn() {
      let assert Ok(child) = factory.start_child(started.data, Nil)
      exit_with(child.pid, "something actually broke")
    })
  stop_server(pid)
  assert reports >= 1
}
