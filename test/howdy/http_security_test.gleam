import ewe
import gleam/erlang/process.{type Pid}
import gleam/int
import howdy
import howdy/controller
import howdy/static
import howdy/websocket

@external(erlang, "howdy_test_ffi", "with_static_tree")
fn with_static_tree(run: fn(String) -> a) -> a

@external(erlang, "howdy_test_ffi", "with_http_server")
fn with_http_server(start: fn() -> #(Pid, Int), run: fn(Int) -> a) -> a

@external(erlang, "howdy_test_ffi", "http_status")
fn http_status(port: Int, path: String, origin: String) -> Int

pub fn live_http_checks_containment_and_handshake_origin_test() {
  use root <- with_static_tree
  let app =
    howdy.new()
    |> howdy.controller(
      controller.new("/ws")
      |> controller.get("/", fn(ctx) {
        websocket.new(fn(_) { Nil }) |> websocket.upgrade(ctx)
      }),
    )
    |> howdy.controller(static.serve("/", from: root))
  use port <- with_http_server(fn() {
    let assert Ok(started) =
      ewe.new(handler: howdy.handler(app))
      |> ewe.bind("127.0.0.1")
      |> ewe.listening(0)
      |> ewe.quiet
      |> ewe.start
    let assert ewe.TcpSocketAddress(_, port) = started.data
    #(started.pid, port)
  })
  let origin = "http://localhost:" <> int.to_string(port)
  assert http_status(port, "/ws", origin) == 101
  assert http_status(port, "/ws", "https://attacker.example") == 403
  assert http_status(port, "/ws", "") == 101
  assert http_status(port, "/ok.txt", "") == 200
  assert http_status(port, "/escape.txt", "") == 404
  assert http_status(port, "/escape-dir/secret.txt", "") == 404
  assert http_status(port, "/nested/", "") == 404
}
