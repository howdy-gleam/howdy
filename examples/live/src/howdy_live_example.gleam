//// A themed page with two live components. Run with `gleam run` from
//// `examples/live`; it listens on 127.0.0.1:8790. Open http://localhost:8790
//// in two browser tabs.
//// Or run `gleam dev` for the same app with hot reload.
////
//// The first counter is private to each tab: every socket starts its own
//// runtime. The second is shared: one runtime started at boot, and every
//// tab sees the same number. The theme button switches light and dark
//// without a reload and remembers the choice in a cookie.
////
//// The first counter sits in an outlet. The Counter and About links swap
//// it between two live views without reloading the page: the address bar,
//// the title and back and forward all follow, and the shared counter
//// below keeps its connection. Each link's `href` serves the same layout
//// with that view mounted, so reloading or opening a link in a new tab
//// gives the same page.
////
//// In development the CSS is served from `/assets/ui.css` and linked from
//// the page. `gleam run -m tasks/css` writes the same CSS to a static
//// file for publishing.
////
//// The buttons come from `howdy_live_example/ui/button`, a copy of the
//// built-in made with `gleam run -m howdy/ui add button` and then edited
//// to give every button pill-shaped corners.

import gleam/erlang/process
import gleam/int
import gleam/otp/static_supervisor as supervisor
import howdy
import howdy/controller.{type Context}
import howdy/cookie
import howdy/ui
import howdy/ui/live
import howdy/ui/page
import howdy/ui/theme
import howdy_live_example/ui/button
import lustre
import lustre/element.{text}
import lustre/event

pub fn main() -> Nil {
  let assert Ok(shared) = live.start(counter("Everyone's count"), with: 0)

  // Supervised inside an OTP application: restarted on a crash, drained on
  // SIGTERM. A local demo, so it listens on 127.0.0.1:8790 only.
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(howdy.supervised(
      app(shared) |> howdy.bind(to: "127.0.0.1") |> howdy.listening(on: 8790),
    ))
    |> howdy.start_application(name: "howdy_live_server")

  process.sleep_forever()
}

pub fn app(shared: lustre.Runtime(Msg)) -> howdy.App {
  howdy.new()
  |> howdy.controller(pages())
  |> howdy.controller(
    controller.new("/live")
    |> controller.get("/mine", fn(ctx) {
      live.serve(ctx, counter("Your count"), with: 0)
    })
    |> controller.get("/about", fn(ctx) { live.serve(ctx, about(), with: Nil) })
    |> controller.get("/everyone", fn(ctx) { live.serve_shared(ctx, shared) }),
  )
  |> howdy.controller(ui.stylesheet(
    at: "/assets/ui.css",
    themes: theme.default_themes(),
  ))
}

fn pages() {
  controller.new("/")
  |> controller.get("/", fn(ctx) { layout(ctx, mount: "/live/mine") })
  |> controller.get("/about", fn(ctx) { layout(ctx, mount: "/live/about") })
}

/// Every page is this layout with a different view in the outlet.
fn layout(ctx: Context, mount mount: String) {
  use theme <- cookie.string_or(ctx, "theme", default: "system")

  page.new("Howdy live")
  |> page.stylesheet(at: "/assets/ui.css")
  |> page.theme(theme)
  |> page.live
  |> page.body([
    ui.container([], [
      ui.stack([], [
        ui.row([], [
          ui.h1("Howdy live"),
          button.theme_toggle([text("Toggle theme")], from: "light", to: "dark"),
        ]),
        ui.row([], [
          live.link(to: "/", mount: "/live/mine", children: [text("Counter")]),
          live.link(to: "/about", mount: "/live/about", children: [
            text("About"),
          ]),
        ]),
        ui.p([
          text("Open this page in a second tab. "),
          ui.muted("The first counter is yours; the second is shared."),
        ]),
        live.outlet(mount),
        live.mount("/live/everyone"),
      ]),
    ]),
  ])
  |> page.respond(ctx)
}

// -- The component -----------------------------------------------------------

pub type Msg {
  Increment
  Decrement
  Reset
}

pub fn counter(title: String) -> lustre.App(Int, Int, Msg) {
  lustre.simple(
    init: fn(start) { start },
    update: fn(count, msg) {
      case msg {
        Increment -> count + 1
        Decrement -> count - 1
        Reset -> 0
      }
    },
    view: fn(count) {
      ui.card([], [
        live.title("Howdy live: " <> title),
        ui.h2(title),
        ui.p([text(int.to_string(count))]),
        ui.row([], [
          button.button(button.Secondary, [event.on_click(Decrement)], [
            text("-"),
          ]),
          button.button(button.Primary, [event.on_click(Increment)], [text("+")]),
          button.button(button.Danger, [event.on_click(Reset)], [text("Reset")]),
        ]),
      ])
    },
  )
}

/// A second view for the outlet. Its link back works from inside the live
/// view as well as from the page.
pub fn about() -> lustre.App(Nil, Nil, Nil) {
  lustre.element(
    ui.card([], [
      live.title("Howdy live: About"),
      ui.h2("About"),
      ui.p([
        text("This card replaced the counter without a page reload. "),
        text("Your count started again from zero: each view gets a fresh "),
        text("runtime when the outlet connects to it."),
      ]),
      ui.p([
        live.link(to: "/", mount: "/live/mine", children: [
          text("Back to the counter"),
        ]),
      ]),
    ]),
  )
}
