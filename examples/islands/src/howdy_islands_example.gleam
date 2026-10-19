//// Two islands on a server-rendered page. Run with `gleam run` from
//// `examples/islands`; it listens on 127.0.0.1:8793. Or run `gleam dev`
//// for the same app with hot reload.
////
//// The islands are Lustre apps in `src/howdy_islands_example/islands`.
//// The server renders each one into the page, and the browser takes over
//// the rendered elements, so clicks never reach the server. The card
//// around the counters is an ordinary howdy_ui component rendered on the
//// server; the task list is built from howdy_ui components and runs in
//// the browser, tabs and confirmation dialog included.
////
//// The star rating comes from a dependency, `library/`, which ships it in
//// its own `islands` directory; the app mounts it like its own.
////
//// `/live` puts islands inside a live view. The live view's own button
//// counts on the server; the islands run in the browser, and neither
//// disturbs the other. Another button has the live view swap one island
//// for the next: a counter, the rating, and a ticker whose timer stops
//// when it is swapped out. The task list shows howdy_ui components
//// styling themselves inside the live view.

import gleam/erlang/process
import gleam/int
import howdy
import howdy/controller
import howdy/ui
import howdy/ui/card
import howdy/ui/island
import howdy/ui/live
import howdy/ui/page
import howdy_islands_example/islands/counter
import howdy_islands_example/islands/tasks
import howdy_islands_example/islands/ticker
import library/islands/rating
import lustre
import lustre/attribute
import lustre/element.{text}
import lustre/element/html
import lustre/event

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
        island.mount(tasks.island, with: ["Write the docs", "Ship it"]),
        // An island shipped by a package, howdy_islands_library.
        island.mount(rating.island, with: 3),
      ])
      |> page.respond(ctx)
    })
    |> controller.get("/live", fn(ctx) {
      page.new("Island in a live view")
      |> page.live
      |> page.body([live.mount("/live/socket")])
      |> page.respond(ctx)
    })
    |> controller.get("/live/socket", fn(ctx) {
      live.serve(ctx, panel(), with: Nil)
    }),
  )
}

pub type Panel {
  Panel(count: Int, showing: Showing)
}

/// Which island the live view shows in its swappable slot.
pub type Showing {
  Counter
  Rating
  Ticker
}

pub type PanelMsg {
  Bump
  Swap
}

/// A live view, run on the server, with islands inside it.
fn panel() -> lustre.App(Nil, Panel, PanelMsg) {
  lustre.simple(
    init: fn(_) { Panel(count: 0, showing: Counter) },
    update: fn(panel, msg) {
      case msg {
        Bump -> Panel(..panel, count: panel.count + 1)
        Swap ->
          Panel(..panel, showing: case panel.showing {
            Counter -> Rating
            Rating -> Ticker
            Ticker -> Counter
          })
      }
    },
    view: fn(panel) {
      html.div([], [
        html.p([attribute.id("server-count")], [
          text("Server count: " <> int.to_string(panel.count)),
        ]),
        html.button([attribute.id("bump"), event.on_click(Bump)], [
          text("Bump on the server"),
        ]),
        html.button([attribute.id("swap"), event.on_click(Swap)], [
          text("Next island"),
        ]),
        html.div([attribute.id("swappable")], [
          case panel.showing {
            Counter -> island.mount(counter.island, with: 3)
            Rating -> island.mount(rating.island, with: 3)
            Ticker -> island.mount(ticker.island, with: 100)
          },
        ]),
        island.mount(tasks.island, with: ["Try islands in a live view"]),
      ])
    },
  )
}
