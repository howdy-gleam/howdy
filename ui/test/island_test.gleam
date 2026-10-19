import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/string
import howdy
import howdy/testing
import howdy/ui
import howdy/ui/island.{type Island}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event

pub fn counter() -> Island(Int, Int, Nil) {
  island.simple(
    init: fn(start) { start },
    update: fn(count, _) { count + 1 },
    view:,
    flags: decode.int,
    encode: json.int,
  )
}

fn view(count: Int) -> Element(Nil) {
  html.button([event.on_click(Nil)], [text(int.to_string(count))])
}

pub fn mount_renders_the_view_and_locates_the_function_test() {
  let html = island.mount(counter, with: 41) |> element.to_string

  assert string.contains(html, "<howdy-island ")
  assert string.contains(html, "data-package=\"howdy_ui\"")
  assert string.contains(html, "data-module=\"island_test\"")
  assert string.contains(html, "data-function=\"counter\"")
  assert string.contains(html, "data-flags=\"41\"")
  // The view is rendered as is: no marker for the browser to disagree with.
  assert string.contains(
    html,
    "style=\"display:contents;\"><button>41</button>",
  )
  assert !string.contains(html, "lustre:map")
  assert string.contains(html, "import('/_howdy/islands/boot.mjs')")
}

pub fn mount_rejects_anonymous_functions_test() {
  let html =
    island.mount(fn() { counter() }, with: 1)
    |> element.to_string

  assert string.contains(
    html,
    "data-error=\"island.mount needs a named function",
  )
  assert !string.contains(html, "data-module=")
}

fn app() -> howdy.App {
  howdy.new() |> howdy.controller(ui.islands())
}

// The tests run in ui/, a checkout without src/howdy_ui/islands.
pub fn boot_reports_a_missing_islands_directory_test() {
  let res = testing.get("/_howdy/islands/boot.mjs") |> testing.send(app())

  assert res.status == 200
  assert string.contains(
    testing.text(res),
    "no island modules found in src/howdy_ui/islands",
  )
}

pub fn files_outside_the_build_are_not_served_test() {
  let res =
    testing.get("/_howdy/islands/howdy_ui/../../../../../gleam.toml")
    |> testing.send(app())

  assert res.status == 404
}
