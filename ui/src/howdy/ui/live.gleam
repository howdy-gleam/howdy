//// Lustre server components over howdy WebSockets.
////
//// A server component is a Lustre app whose `init`, `update` and `view` run
//// on the server. The browser holds a thin client that sends events up and
//// applies DOM patches that come back. howdy already has the socket, so the
//// bridge is one route:
////
//// ```gleam
//// import howdy/ui/live
////
//// controller.new("/counter")
//// |> controller.get("/", fn(ctx) { live.serve(ctx, counter.app(), with: 0) })
//// ```
////
//// and one element in a page rendered with `howdy/ui/page`:
////
//// ```gleam
//// page.new("Counter")
//// |> page.live
//// |> page.body([live.mount("/counter")])
//// |> page.respond(ctx)
//// ```
////
//// The socket route goes through guards and middleware like any other, so
//// authentication works the same way as for `howdy/websocket`: read a cookie
//// or query parameter, since browsers cannot set handshake headers.
////
//// Each connection gets its own runtime, started when the socket opens and
//// shut down when it closes. For one runtime shared by every client, such
//// as a dashboard, use `start` and `serve_shared`.
////
//// Views are styled with `howdy/ui` components automatically. A component
//// carries the CSS for the classes its view uses, so it is styled whether
//// or not the page links a stylesheet.
////
//// ## Live links
////
//// A page can mount one `outlet` in place of a `mount`. A `link` then swaps
//// the outlet to another socket route and pushes the page URL onto the
//// history, so moving between live pages needs no reload:
////
//// ```gleam
//// page.new("Orders")
//// |> page.live
//// |> page.body([
////   live.link(to: "/", mount: "/live/home", children: [text("Home")]),
////   live.link(to: "/orders", mount: "/live/orders", children: [text("Orders")]),
////   live.outlet("/live/orders"),
//// ])
//// ```
////
//// The `href` must serve the full page with the same outlet, because it is
//// what a reload, a bookmark, a new tab or a browser without JavaScript
//// loads.

import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http/response.{type Response}
import howdy/content.{type Content}
import howdy/controller.{type GuardedContext}
import howdy/ui/internal/stylesheet
import howdy/ui/style.{class}
import howdy/ui/typography
import howdy/websocket.{type Builder, type Socket}
import lustre.{type App, type Runtime}
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import lustre/runtime/app as lustre_app
import lustre/server_component.{type ClientMessage}

/// The `<lustre-server-component>` element that connects to `route`. The
/// page must include the client runtime; `page.live` does that.
pub fn mount(route: String) -> Element(msg) {
  server_component.element([server_component.route(route)], [])
}

/// A `mount` that live links swap. When a `link` is clicked the outlet
/// connects to the link's socket route and replaces its contents once the
/// new view arrives. A page has at most one outlet.
pub fn outlet(route: String) -> Element(msg) {
  server_component.element(
    [
      server_component.route(route),
      attribute.data("howdy-live-outlet", ""),
      // Focusable from script, so focus can move to the new view.
      attribute.tabindex(-1),
    ],
    [],
  )
}

/// A link that swaps the page's `outlet` to the socket at `mount` and
/// shows `href` in the address bar, instead of loading `href`. Back and
/// forward swap the outlet too.
///
/// It is a plain link wherever swapping is not possible: with a modifier
/// key or middle click, when the page has no outlet, or before scripts
/// run. So `href` must serve a full page whose outlet mounts `mount`.
/// Works in pages and in live views.
pub fn link(
  to href: String,
  mount mount: String,
  children children: List(Element(msg)),
) -> Element(msg) {
  html.a(
    [class(typography.link_class()), ..navigate(to: href, mount:)],
    children,
  )
}

/// The attributes that make any `<a>` a live link, for links styled some
/// other way. See `link`.
pub fn navigate(to href: String, mount mount: String) -> List(Attribute(msg)) {
  [attribute.href(href), attribute.data("howdy-live-mount", mount)]
}

/// Hear the value of a form control in a live view: a `howdy/ui/select`,
/// combobox or calendar, which keep their value in a hidden input called
/// `name`, or any native input, select or textarea with that `name`. Put it
/// on an element that contains the control; the `change` event bubbles to
/// it and the browser sends the value along.
///
/// ```gleam
/// html.div([live.on_value("plan", PlanChosen)], [
///   ui.select(id: "plan", name: "plan", ...),
/// ])
/// ```
pub fn on_value(name: String, message: fn(String) -> msg) -> Attribute(msg) {
  event.on("change", {
    use field <- decode.subfield(["target", "name"], decode.string)
    use value <- decode.subfield(["target", "value"], decode.string)
    case field == name {
      True -> decode.success(message(value))
      False -> decode.failure(message(value), "a change to " <> name)
    }
  })
  |> server_component.include(["target.name", "target.value"])
}

/// Hear every value of a control that holds several, such as
/// `howdy/ui/command.multiple_combobox` called `name`, each time the set
/// changes.
pub fn on_values(
  name: String,
  message: fn(List(String)) -> msg,
) -> Attribute(msg) {
  event.on("howdy-values", {
    use field <- decode.subfield(["detail", "name"], decode.string)
    use values <- decode.subfield(
      ["detail", "values"],
      decode.list(decode.string),
    )
    case field == name {
      True -> decode.success(message(values))
      False -> decode.failure(message(values), "a change to " <> name)
    }
  })
  |> server_component.include(["detail.name", "detail.values"])
}

/// Name the document from a live view. When the outlet mounts a view that
/// contains a title, the document title changes to match, so history
/// entries are named after the page they lead to. Put it anywhere in the
/// view; browsers do not display a `<title>` in the body.
pub fn title(content: String) -> Element(msg) {
  html.title([], content)
}

/// The script that makes `link` work. `page.live` includes it; add it
/// yourself only when rendering the document some other way, after
/// `server_component.script()`.
pub fn script() -> Element(msg) {
  html.script([attribute.type_("module")], navigation_script)
}

/// Upgrade the request to a socket running a fresh runtime of `app`,
/// started with `args`. Equivalent to `socket(app, args)` followed by
/// `websocket.upgrade(ctx)`.
pub fn serve(
  ctx: GuardedContext(guarded),
  app: App(args, model, msg),
  with args: args,
) -> Response(Content) {
  socket(app, args)
  |> websocket.upgrade(ctx)
}

/// The socket description `serve` uses, for adding your own callbacks
/// before upgrading. The socket state is the runtime.
pub fn socket(
  app: App(args, model, msg),
  args: args,
) -> Builder(Runtime(msg), ClientMessage(msg)) {
  websocket.new(fn(socket) {
    let assert Ok(runtime) = start(app, args)
      as "howdy/ui/live: could not start the server component"
    register(runtime, socket)
    runtime
  })
  |> attach
  |> websocket.untraced
  |> websocket.on_close(fn(_socket, runtime) {
    lustre.send(runtime, lustre.shutdown())
  })
}

/// Start a runtime that outlives any one connection. Every socket served
/// with `serve_shared` sees the same model.
pub fn start(
  app: App(args, model, msg),
  with args: args,
) -> Result(Runtime(msg), lustre.Error) {
  app
  |> styled
  |> lustre.start_server_component(with: args)
}

/// Upgrade the request to a socket attached to a runtime from `start`.
/// Closing the socket detaches it and leaves the runtime running.
pub fn serve_shared(
  ctx: GuardedContext(guarded),
  runtime: Runtime(msg),
) -> Response(Content) {
  socket_shared(runtime)
  |> websocket.upgrade(ctx)
}

/// The socket description `serve_shared` uses.
pub fn socket_shared(
  runtime: Runtime(msg),
) -> Builder(Runtime(msg), ClientMessage(msg)) {
  websocket.new(fn(socket) {
    register(runtime, socket)
    runtime
  })
  |> attach
  |> websocket.untraced
  |> websocket.on_close(fn(socket, runtime) {
    lustre.send(runtime, server_component.deregister_subject(inbox(socket)))
  })
}

/// Send a message to a runtime's `update` function from anywhere.
pub fn dispatch(runtime: Runtime(msg), message: msg) -> Nil {
  lustre.send(runtime, lustre.dispatch(message))
}

// -- Internals ---------------------------------------------------------------

// Module scripts run after the document is parsed, so the outlet exists.
// Clicks are handled at the document so links inside live views are seen
// too: their shadow roots are open, so `composedPath` includes the anchor.
// Lustre reconnects when the outlet's `route` changes and keeps the old
// view on screen until the new one mounts.
const navigation_script = "
const outlet = document.querySelector('lustre-server-component[data-howdy-live-outlet]');
if (outlet) {
  let navigated = false;
  const swap = (mount) => {
    if (outlet.getAttribute('route') === mount) return;
    navigated = true;
    outlet.setAttribute('route', mount);
  };
  history.replaceState({ ...history.state, howdyLiveMount: outlet.getAttribute('route') }, '');
  document.addEventListener('click', (event) => {
    if (event.defaultPrevented || event.button !== 0) return;
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const link = event.composedPath().find((node) => node instanceof HTMLAnchorElement);
    if (!link || !link.hasAttribute('data-howdy-live-mount')) return;
    if ((link.target && link.target !== '_self') || link.hasAttribute('download')) return;
    const url = new URL(link.href);
    if (url.origin !== location.origin) return;
    event.preventDefault();
    const mount = link.getAttribute('data-howdy-live-mount');
    if (url.href !== location.href) history.pushState({ howdyLiveMount: mount }, '', url);
    swap(mount);
    if (navigated) window.scrollTo(0, 0);
  });
  window.addEventListener('popstate', (event) => {
    const mount = event.state?.howdyLiveMount;
    if (mount) swap(mount);
  });
  outlet.addEventListener('lustre:mount', () => {
    const title = outlet.shadowRoot?.querySelector('title');
    if (title) document.title = title.textContent;
    if (!navigated) return;
    navigated = false;
    outlet.focus({ preventScroll: true });
  });
}
"

fn styled(app: App(args, model, msg)) -> App(args, model, msg) {
  let view = app.view
  lustre_app.App(..app, view: fn(model) {
    // The component renders into a shadow root, so it carries the CSS for
    // exactly the classes its view used. Lustre diffs the style node like
    // any other, so it only travels when the set of classes changes.
    let #(rendered, css) = stylesheet.scoped(fn() { view(model) })
    element.fragment([html.style([], css), rendered])
  })
}

fn inbox(socket: Socket(ClientMessage(msg))) -> Subject(ClientMessage(msg)) {
  websocket.subject(socket)
}

fn register(runtime: Runtime(msg), socket: Socket(ClientMessage(msg))) -> Nil {
  lustre.send(runtime, server_component.register_subject(inbox(socket)))
}

/// Frames from the browser go to the runtime; runtime output goes to the
/// browser. A client that cannot be written to is dropped.
fn attach(
  builder: Builder(Runtime(msg), ClientMessage(msg)),
) -> Builder(Runtime(msg), ClientMessage(msg)) {
  builder
  |> websocket.on_json(
    server_component.runtime_message_decoder(),
    fn(_socket, runtime, message) {
      lustre.send(runtime, message)
      websocket.continue(runtime)
    },
  )
  |> websocket.on_message(fn(socket, runtime, message) {
    case
      websocket.send_json(
        socket,
        server_component.client_message_to_json(message),
      )
    {
      Ok(Nil) -> websocket.continue(runtime)
      Error(_) -> websocket.stop()
    }
  })
}
