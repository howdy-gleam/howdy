//// Islands: Lustre apps rendered on the server, then run in the browser.
////
//// An island is an ordinary Lustre app in a module in a directory called
//// `islands`, such as `src/<app>/islands/`. It exposes a function returning
//// an `Island`:
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
//// A release has no compiler, so its islands are bundled as it is
//// exported. In place of `gleam export erlang-shipment`, run:
////
//// ```sh
//// gleam run -m howdy/ui export
//// ```
////
//// It bundles the islands into `priv/howdy_islands`, then exports. For a
//// build that must run `gleam export erlang-shipment` itself, run
//// `gleam run -m howdy/ui islands` just before it.
////
//// The bundle records what it was built from: for every package with code
//// in it, the version and the compiled modules involved, Erlang FFI
//// included. A release whose code differs refuses the bundle and logs
//// what to run, rather than serving islands that no longer match the
//// server. A release cannot see JavaScript sources, so an edit to only a
//// JavaScript FFI file in the app between bundling and exporting goes
//// unnoticed; the single `export` command leaves no gap for one.
////
//// Packages ship islands the same way: any package that depends on
//// howdy_ui can have an `islands` directory, and an app mounts those
//// islands like its own, with nothing to register.
////
//// Island modules and the app modules they import are compiled for
//// JavaScript, so they can only use code that runs in a browser.
////
//// `howdy/ui` components work in islands. A class gets the same name on
//// the server and in the browser, so the rendered page keeps its styles
//// when the browser takes over, and CSS for classes first used in the
//// browser is added to the page as they appear. Components whose state
//// the browser keeps, such as tabs and dialogs, keep it across the
//// island's re-renders, as they do in live views. Ids passed to components
//// must still be unique in the page, so an island mounted twice needs ids
//// built from its flags.
////
//// Islands also work inside live views. The live view renders the island
//// once and leaves it to the browser: the island's events never reach the
//// server, and the live view's re-renders leave the island's state alone.
//// If the live view renders a different island in its place, or the same
//// island with different flags, the new one starts afresh.
////
//// An island removed from the page stops: its update and view no longer
//// run, so effects waiting to send it a message, such as a timeout, end
//// there. Effects that keep running, such as intervals and event
//// listeners, need starting with `subscription` or `every`, which stop
//// them too; Lustre gives other effects no way to stop. If a removed
//// island still receives messages seconds later, the browser console says
//// which. An island put back in the page starts again from its flags.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/result
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed

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
  let #(identity, location) = case locate(island) {
    Ok(#(package, module, function)) -> #(
      package <> "/" <> module <> "." <> function,
      [
        attribute.data("package", package),
        attribute.data("module", module),
        attribute.data("function", function),
      ],
    )
    Error(reason) -> #(reason, [attribute.data("error", reason)])
  }
  let flags = json.to_string(encode(flags))
  // Keyed by which island it is and its flags: when a live view re-renders
  // it as a different island or with new flags, it replaces the element,
  // and the new one starts afresh, rather than rewriting HTML a running
  // island owns.
  keyed.fragment([
    #(
      "howdy-island " <> identity <> " " <> flags,
      // Opaque HTML, so a live view rendering the island sees no handlers
      // to wire up and leaves the browser's copy alone.
      element.unsafe_raw_html(
        "",
        "howdy-island",
        [
          attribute.style("display", "contents"),
          attribute.data("flags", flags),
          ..location
        ],
        element.to_string(view(model)),
      ),
    ),
    #("howdy-island-loader", html.script([attribute.type_("module")], loader)),
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
  case string.starts_with(function, "-"), is_island_module(module) {
    True, _ ->
      Error(
        "island.mount needs a named function such as counter.island, not an anonymous fn",
      )
    False, False ->
      Error(
        module
        <> " is not an island module: island modules live in a directory called islands, such as src/"
        <> package
        <> "/islands/",
      )
    False, True -> Ok(#(package, module, function))
  }
}

/// Whether a module is an island module: one in a directory called
/// `islands`, such as `my_app/islands/counter`. Only these are built for
/// the browser.
@internal
pub fn is_island_module(module: String) -> Bool {
  case list.reverse(string.split(module, "/")) {
    [_, ..directories] -> list.contains(directories, "islands")
    [] -> False
  }
}

@external(erlang, "howdy_ui_island_ffi", "function_location")
fn function_location(
  function: fn() -> Island(flags, model, msg),
) -> Result(#(String, String, String), String)

/// An effect that keeps running, such as a timer or an event listener,
/// and stops when the island does. `start` begins it, given the function
/// that sends the island a message, and returns the function that ends it.
///
/// ```gleam
/// island.subscription(fn(dispatch) {
///   let id = set_interval(1000, fn() { dispatch(Tick) })
///   fn() { clear_interval(id) }
/// })
/// ```
///
/// An island stops when it is removed from the page, such as by a live
/// view re-rendering without it. Lustre gives effects no way to clean up,
/// so an interval or listener started by a plain `effect.from` would keep
/// running, and keep the removed island in memory.
pub fn subscription(start: fn(fn(msg) -> Nil) -> fn() -> Nil) -> Effect(msg) {
  use dispatch, root <- effect.before_paint
  on_stop(root, start(dispatch))
}

/// Send the island `message` every `milliseconds`, for as long as it runs.
pub fn every(milliseconds: Int, message: msg) -> Effect(msg) {
  use dispatch <- subscription
  let interval = set_interval(milliseconds, fn() { dispatch(message) })
  fn() { clear_interval(interval) }
}

/// Start an island on `root`, a `howdy-island` element, with flags encoded
/// as JSON. The boot module calls this in the browser.
///
/// Lustre cannot stop an app, so the island's update and view are wrapped:
/// once the island is removed from the page they do nothing, and an effect
/// waiting to send a message, such as a timeout, finds no one listening.
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
  let lifetime = begin(root)
  let update = fn(model, msg) {
    case accepts(lifetime) {
      True -> update(model, msg)
      False -> #(model, effect.none())
    }
  }
  let view = fn(model) {
    case alive(lifetime) {
      True -> view(model)
      False -> element.none()
    }
  }
  lustre.application(init, update, view)
  |> lustre.start(onto: element_as_selector(root), with: flags)
  |> result.map(fn(_) { Nil })
  |> result.map_error(string.inspect)
}

/// One start of an island, which ends when the island leaves the page.
type Lifetime

@external(erlang, "howdy_ui_island_ffi", "begin_lifetime")
@external(javascript, "./island.ffi.mjs", "begin_lifetime")
fn begin(root: Dynamic) -> Lifetime

@external(erlang, "howdy_ui_island_ffi", "alive")
@external(javascript, "./island.ffi.mjs", "alive")
fn alive(lifetime: Lifetime) -> Bool

// Whether the island takes a message: `alive`, but noting messages that
// arrive long after it stopped, which mean an effect is still running.
@external(erlang, "howdy_ui_island_ffi", "alive")
@external(javascript, "./island.ffi.mjs", "accepts")
fn accepts(lifetime: Lifetime) -> Bool

@external(erlang, "howdy_ui_island_ffi", "on_stop")
@external(javascript, "./island.ffi.mjs", "on_stop")
fn on_stop(root: Dynamic, cleanup: fn() -> Nil) -> Nil

type Interval

@external(erlang, "howdy_ui_island_ffi", "set_interval")
@external(javascript, "./island.ffi.mjs", "set_interval")
fn set_interval(milliseconds: Int, callback: fn() -> Nil) -> Interval

@external(erlang, "howdy_ui_island_ffi", "clear_interval")
@external(javascript, "./island.ffi.mjs", "clear_interval")
fn clear_interval(interval: Interval) -> Nil

// Lustre's client start accepts an element where it documents a selector.
@external(erlang, "howdy_ui_island_ffi", "identity")
@external(javascript, "./island.ffi.mjs", "identity")
fn element_as_selector(element: Dynamic) -> String
