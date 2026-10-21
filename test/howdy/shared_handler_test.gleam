//// A server's handler is kept once for every process to read, rather than
//// copied into each of the web server's processes (`howdy_ffi.erl`).

import gleam/erlang/process
import gleam/int
import gleam/list
import howdy
import howdy/controller

@external(erlang, "howdy_test_ffi", "plain_get")
fn plain_get(port: Int, path: String) -> #(Int, String)

@external(erlang, "howdy_test_ffi", "flat_size")
fn flat_size(term: a) -> Int

@external(erlang, "howdy_ffi", "shared_handlers")
fn shared_handlers() -> Int

/// Forty routes closing over one value, as an app's routes close over its
/// services. Within the app the value is shared; copied to another process,
/// each route holds its own, over 80,000 words.
fn app() -> howdy.App {
  let shared = list.repeat("row", 1000)
  let routes =
    list.fold(numbers(40), controller.new("/"), fn(routes, n) {
      controller.get(routes, "/" <> int.to_string(n), fn(ctx) {
        controller.text(ctx, int.to_string(list.length(shared)))
      })
    })
  howdy.new()
  |> howdy.bind("127.0.0.1")
  |> howdy.listening(on: 0)
  |> howdy.controller(routes)
}

pub fn the_handler_ewe_copies_holds_no_routes_test() {
  assert flat_size(howdy.handler(app())) < 1000
}

pub fn a_server_answers_through_its_kept_handler_test() {
  let before = shared_handlers()
  let assert Ok(started) = howdy.start(app())
  assert shared_handlers() == before + 1
  // Each connection is served by a process of its own.
  list.each(numbers(5), fn(n) {
    assert plain_get(started.data.port, "/" <> int.to_string(n))
      == #(200, "1000")
  })
  howdy.stop(started.pid)
  // Forgotten once the server has gone.
  assert await_handlers(before, 50)
}

/// 1 to `n`.
fn numbers(n: Int) -> List(Int) {
  list.index_map(list.repeat(Nil, n), fn(_, index) { index + 1 })
}

fn await_handlers(count: Int, tries: Int) -> Bool {
  case shared_handlers() == count, tries {
    True, _ -> True
    False, 0 -> False
    False, _ -> {
      process.sleep(20)
      await_handlers(count, tries - 1)
    }
  }
}
