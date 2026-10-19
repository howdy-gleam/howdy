//// `gleam dev` serves the app with hot reload, and regenerates the messages
//// module whenever a catalogue in `locales/` changes.

import gleam/erlang/process
import howdy/dev
import howdy/i18n/cli
import howdy_i18n_example

pub fn main() -> Nil {
  let assert Ok(_) =
    dev.new(howdy_i18n_example.app)
    |> dev.watch("locales")
    |> dev.before_build(fn(_changed) { cli.execute(["gen"]) })
    |> dev.run
  process.sleep_forever()
}
