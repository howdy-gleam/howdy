//// Development entry point: `gleam dev`. The same app as `gleam run`,
//// with hot reload. Edit anything under `src` and open pages refresh.

import gleam/erlang/process
import howdy
import howdy/dev
import howdy/ui/live
import howdy_live_example

pub fn main() -> Nil {
  let assert Ok(shared) =
    live.start(howdy_live_example.counter("Everyone's count"), with: 0)

  let assert Ok(_) =
    dev.start(fn() {
      howdy_live_example.app(shared) |> howdy.listening(on: 8790)
    })

  process.sleep_forever()
}
