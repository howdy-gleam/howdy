import gleam/string
import gleeunit
import howdy/testing
import howdy/ui/live
import howdy_live_example
import lustre

pub fn main() {
  gleeunit.main()
}

pub fn page_stylesheet_and_socket_routes_test() {
  let assert Ok(shared) =
    live.start(howdy_live_example.counter("Test"), with: 0)
  let app = howdy_live_example.app(shared)
  let page = testing.get("/") |> testing.send(app)
  assert page.status == 200
  assert string.contains(testing.text(page), "Howdy live")
  assert string.contains(testing.text(page), "/live/everyone")
  let css = testing.get("/assets/ui.css") |> testing.send(app)
  assert css.status == 200
  assert string.contains(testing.text(css), "--howdy-background")
  assert { testing.get("/live/mine") |> testing.send(app) }.status == 426
  assert { testing.get("/live/everyone") |> testing.send(app) }.status == 426
  assert { testing.get("/live/about") |> testing.send(app) }.status == 426
  let about = testing.get("/about") |> testing.send(app) |> testing.text
  assert string.contains(about, "data-howdy-live-outlet route=\"/live/about\"")
  assert string.contains(about, "data-howdy-live-mount=\"/live/mine\"")
  assert { testing.get("/missing") |> testing.send(app) }.status == 404
  lustre.send(shared, lustre.shutdown())
}
