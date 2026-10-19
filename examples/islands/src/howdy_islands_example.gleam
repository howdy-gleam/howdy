//// Two islands on a server-rendered page. Run with `gleam run` from
//// `examples/islands`; it listens on 127.0.0.1:8793. Or run `gleam dev`
//// for the same app with hot reload.
////
//// The counters are Lustre apps in `src/howdy_islands_example/islands`.
//// The server renders each one into the page, and the browser takes over
//// the rendered elements, so clicks never reach the server. The card
//// around them is an ordinary howdy_ui component rendered on the server.

import gleam/erlang/process
import howdy
import howdy/controller
import howdy/ui
import howdy/ui/card
import howdy/ui/island
import howdy/ui/page
import howdy_islands_example/islands/counter
import lustre/element.{text}
import lustre/element/html

pub fn main() -> Nil {
  let assert Ok(_) =
    app()
    |> howdy.bind(to: "127.0.0.1")
    |> howdy.listening(on: 8793)
    |> howdy.start
  process.sleep_forever()
}

pub fn app() -> howdy.App {
  howdy.new()
  |> howdy.controller(ui.islands())
  |> howdy.controller(
    controller.new("/")
    |> controller.get("/", fn(ctx) {
      page.new("Islands")
      |> page.body([
        card.card([], [
          card.header([], [card.title([text("Islands")])]),
          card.content([], [
            html.p([], [text("Each counter runs in the browser.")]),
            island.mount(counter.island, with: 5),
            island.mount(counter.island, with: 100),
          ]),
        ]),
      ])
      |> page.respond(ctx)
    }),
  )
}
