import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/string
import howdy
import howdy/testing
import howdy/ui
import howdy/ui/island.{type Island}
import howdy_ui/islands/probe
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

pub fn mount_renders_the_view_test() {
  let html = island.mount(counter, with: 41) |> element.to_string

  assert string.contains(html, "<howdy-island ")
  assert string.contains(html, "data-flags=\"41\"")
  // The view is rendered as is: no marker for the browser to disagree with.
  assert string.contains(
    html,
    "style=\"display:contents;\"><button>41</button>",
  )
  assert !string.contains(html, "lustre:map")
  assert string.contains(html, "import('/_howdy/islands/boot.mjs')")
}

pub fn mount_locates_the_island_function_test() {
  let html = island.mount(probe.island, with: 7) |> element.to_string

  assert string.contains(html, "data-package=\"howdy_ui\"")
  assert string.contains(html, "data-module=\"howdy_ui/islands/probe\"")
  assert string.contains(html, "data-function=\"island\"")
  assert string.contains(html, "data-flags=\"7\"")
  assert string.contains(html, "<output>7</output>")
}

// This module is not under src/howdy_ui/islands/, so the browser could
// never load it; mount says so instead of leaving a silent failure.
pub fn mount_names_where_island_modules_live_test() {
  let html = island.mount(counter, with: 41) |> element.to_string

  assert string.contains(
    html,
    "data-error=\"island_test is not an island module: island modules live in a directory called islands, such as src/howdy_ui/islands/\"",
  )
  assert !string.contains(html, "data-module=")
}

pub fn island_modules_are_those_in_an_islands_directory_test() {
  assert island.is_island_module("my_app/islands/counter")
  assert island.is_island_module("howdy/ui/islands/editor")
  assert island.is_island_module("my_app/islands/forms/signup")
  assert !island.is_island_module("my_app/islands")
  assert !island.is_island_module("howdy/ui/internal/islands")
  assert !island.is_island_module("my_app/counter")
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
    "no island modules found. Put them in a directory called islands under src, such as src/howdy_ui/islands/.",
  )
}

pub fn files_outside_the_build_are_not_served_test() {
  let res =
    testing.get("/_howdy/islands/howdy_ui/../../../../../gleam.toml")
    |> testing.send(app())

  assert res.status == 404
}
