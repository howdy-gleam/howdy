//// Islands: Lustre apps rendered on the server, then run in the browser.
////
//// An island is an ordinary Lustre app in a module under
//// `src/<app>/islands/`. It exposes a function returning an `Island`:
////
//// ```gleam
//// // src/my_app/islands/counter.gleam
//// import gleam/dynamic/decode
//// import gleam/json
//// import howdy/ui/island
////
//// pub fn island() {
////   island.simple(init:, update:, view:, flags: decode.int, encode: json.int)
//// }
//// ```
////
//// A page mounts it by passing that function, with the island's flags:
////
//// ```gleam
//// page.body([island.mount(counter.island, with: 5)])
//// ```
////
//// The server renders the view for `init(5)` straight into the page, so it
//// shows at once and works without JavaScript as far as plain HTML can.
//// In the browser the same app takes over the rendered elements.
////
//// The app must also mount `ui.islands()`, which serves the browser code.
//// In development it builds the islands on demand, so `gleam run` and
//// `gleam dev` both serve code that matches the source.
////
//// A release has no compiler, so bundle the islands before exporting:
////
//// ```sh
//// gleam run -m howdy/ui islands
//// gleam export erlang-shipment
//// ```
////
//// The bundle lands in `priv/howdy_islands`, which the export includes.
//// It records which code it was built from, and a release whose code has
//// changed since refuses it, logging what to run, rather than serving
//// islands that no longer match the server.
////
//// Island modules and the app modules they import are compiled for
//// JavaScript, so they can only use code that runs in a browser.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/result
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html

/// A Lustre app that can be rendered on the server and run in the browser,
/// with the codecs that carry its flags between the two.
pub opaque type Island(flags, model, msg) {
  Island(
    init: fn(flags) -> #(model, Effect(msg)),
    update: fn(model, msg) -> #(model, Effect(msg)),
    view: fn(model) -> Element(msg),
    decoder: Decoder(flags),
    encode: fn(flags) -> Json,
  )
}

/// An island without effects, like `lustre.simple`.
pub fn simple(
  init init: fn(flags) -> model,
  update update: fn(model, msg) -> model,
  view view: fn(model) -> Element(msg),
  flags decoder: Decoder(flags),
  encode encode: fn(flags) -> Json,
) -> Island(flags, model, msg) {
  Island(
    init: fn(flags) { #(init(flags), effect.none()) },
    update: fn(model, msg) { #(update(model, msg), effect.none()) },
    view:,
    decoder:,
    encode:,
  )
}

/// An island with effects, like `lustre.application`. Effects from `init`
/// run in the browser only; the server renders the initial model.
pub fn application(
  init init: fn(flags) -> #(model, Effect(msg)),
  update update: fn(model, msg) -> #(model, Effect(msg)),
  view view: fn(model) -> Element(msg),
  flags decoder: Decoder(flags),
  encode encode: fn(flags) -> Json,
) -> Island(flags, model, msg) {
  Island(init:, update:, view:, decoder:, encode:)
}

/// Render the island for `flags` and mark it for the browser to start.
///
/// Pass the island's function itself, such as `counter.island`, rather
/// than calling it: the browser loads the module that function lives in.
pub fn mount(
  island: fn() -> Island(flags, model, msg),
  with flags: flags,
) -> Element(a) {
  let Island(init:, view:, encode:, ..) = island()
  let #(model, _) = init(flags)
  let location = case locate(island) {
    Ok(#(package, module, function)) -> [
      attribute.data("package", package),
      attribute.data("module", module),
      attribute.data("function", function),
    ]
    Error(reason) -> [attribute.data("error", reason)]
  }
  element.fragment([
    element.element(
      "howdy-island",
      [
        attribute.style("display", "contents"),
        attribute.data("flags", json.to_string(encode(flags))),
        ..location
      ],
      [inert(view(model))],
    ),
    html.script([attribute.type_("module")], loader),
  ])
}

// Every island repeats this. Imports of one URL run once, so the boot
// module starts all islands; if it cannot load, say so on the page.
const loader = "import('/_howdy/islands/boot.mjs').catch((e) => {
if (window.__howdyIslandsFailed) return; window.__howdyIslandsFailed = true;
const m = 'howdy islands: could not load /_howdy/islands/boot.mjs. Does the app mount ui.islands()?';
console.error(m, e);
const d = document.createElement('div');
d.dataset.howdyIslandsErrors = '';
d.textContent = m;
d.setAttribute('style', 'position:fixed;inset:auto 1rem 1rem 1rem;z-index:2147483647;padding:1rem;background:#7f1d1d;color:#fff;font:14px/1.4 ui-monospace,monospace;border-radius:.5rem;white-space:pre-wrap');
document.body.append(d);
});"

/// Where `island` was defined: its package, module path and function
/// name. Fails for anonymous functions, which the browser cannot import.
fn locate(
  island: fn() -> Island(flags, model, msg),
) -> Result(#(String, String, String), String) {
  use #(package, module, function) <- result.try(function_location(island))
  let module = string.replace(module, "@", "/")
  case string.starts_with(function, "-") {
    True ->
      Error(
        "island.mount needs a named function such as counter.island, not an anonymous fn",
      )
    False -> Ok(#(package, module, function))
  }
}

// The server renders the view to HTML and never dispatches its messages,
// so any message type will do. Unlike `element.map`, this leaves no marker
// in the HTML for the browser's first render to disagree with.
@external(erlang, "howdy_ui_island_ffi", "identity")
fn inert(view: Element(msg)) -> Element(a)

@external(erlang, "howdy_ui_island_ffi", "function_location")
fn function_location(
  function: fn() -> Island(flags, model, msg),
) -> Result(#(String, String, String), String)

/// Start an island on `root`, a `howdy-island` element, with flags encoded
/// as JSON. The boot module calls this in the browser.
@internal
pub fn start(
  island: Island(flags, model, msg),
  root: Dynamic,
  flags: String,
) -> Result(Nil, String) {
  let Island(init:, update:, view:, decoder:, ..) = island
  use flags <- result.try(
    json.parse(flags, decoder)
    |> result.map_error(fn(error) {
      "its flags did not decode: " <> string.inspect(error)
    }),
  )
  lustre.application(init, update, view)
  |> lustre.start(onto: element_as_selector(root), with: flags)
  |> result.map(fn(_) { Nil })
  |> result.map_error(string.inspect)
}

// Lustre's client start accepts an element where it documents a selector.
@external(erlang, "howdy_ui_island_ffi", "identity")
@external(javascript, "./island.ffi.mjs", "identity")
fn element_as_selector(element: Dynamic) -> String
