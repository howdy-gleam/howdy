//// Development entry point: `gleam dev`. The same app as `gleam run`,
//// with hot reload.

import gleam/erlang/process
import howdy
import howdy/dev
import howdy_islands_example

pub fn main() -> Nil {
  let assert Ok(_) =
    dev.start(fn() { howdy_islands_example.app() |> howdy.listening(on: 8793) })
  process.sleep_forever()
}
