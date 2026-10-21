//// The browser side: a socket every open page listens on, and the script
//// that connects to it.

import gleam/bit_array
import gleam/bytes_tree
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/string
import howdy/content.{type Content}
import howdy/controller.{type Controller, type Middleware}
import howdy/websocket
import howdy/websocket/channel

/// Where open pages connect.
pub const path = "/_howdy/reload"

pub opaque type Session {
  Session(token: String, hosts: List(String))
}

@external(erlang, "howdy_dev_ffi", "reload_token")
fn reload_token() -> String

@external(erlang, "howdy_dev_ffi", "token_matches")
fn token_matches(expected: String, supplied: String) -> Bool

pub fn new(hosts: List(String)) -> Session {
  Session(reload_token(), list.map(hosts, string.lowercase))
}

pub fn allowed_host(session: Session, host: String) -> Bool {
  list.contains(session.hosts, string.lowercase(host))
}

fn topic(session: Session) -> String {
  "howdy_dev:reload:" <> session.token
}

fn authorized(session: Session, ctx: controller.Context) -> Bool {
  allowed_host(session, ctx.request.host)
  && case request.get_query(ctx.request) {
    Ok(pairs) ->
      case list.filter(pairs, fn(pair) { pair.0 == "token" }) {
        [#(_, value)] -> token_matches(session.token, value)
        _ -> False
      }
    Error(_) -> False
  }
}

pub fn forbidden() -> Response(Content) {
  response.new(403) |> response.set_body(content.Text("forbidden"))
}

/// The controller that upgrades pages to the reload socket.
pub fn controller(session: Session) -> Controller {
  controller.new(path)
  |> controller.get("/", fn(ctx) {
    case authorized(session, ctx) {
      False -> forbidden()
      True ->
        websocket.new(fn(socket) {
          channel.join(socket, topic(session))
          Nil
        })
        |> websocket.require_origin
        |> websocket.upgrade(ctx)
    }
  })
}

/// Tell every open page to reload.
pub fn reload_all(session: Session) -> Nil {
  channel.broadcast_json(
    topic(session),
    json.object([#("kind", json.string("reload"))]),
  )
}

/// Show every open page a build failure.
pub fn show_error(session: Session, output: String) -> Nil {
  channel.broadcast_json(
    topic(session),
    json.object([
      #("kind", json.string("error")),
      #("output", json.string(output)),
    ]),
  )
}

/// Middleware that adds the reload script to HTML responses.
pub fn inject(session: Session) -> Middleware {
  fn(ctx: controller.Context, next) {
    case allowed_host(session, ctx.request.host) {
      True -> add_script(next(ctx), session)
      False -> forbidden()
    }
  }
}

fn add_script(res: Response(Content), session: Session) -> Response(Content) {
  case response.get_header(res, "content-type"), res.body {
    Ok("text/html" <> _), content.Text(html) -> with_script(res, html, session)
    Ok("text/html" <> _), content.Bytes(tree) ->
      case bit_array.to_string(bytes_tree.to_bit_array(tree)) {
        Ok(html) -> with_script(res, html, session)
        Error(Nil) -> res
      }
    _, _ -> res
  }
}

fn with_script(
  res: Response(Content),
  html: String,
  session: Session,
) -> Response(Content) {
  let res =
    response.Response(
      ..res,
      headers: list.filter(res.headers, fn(header) {
        !list.contains(["content-length", "etag", "last-modified"], header.0)
      }),
    )
  res
  |> response.set_header("cache-control", "no-store")
  |> response.set_body(content.Text(insert(html, session)))
}

fn insert(html: String, session: Session) -> String {
  let script = script(session)
  case string.contains(html, "</body>") {
    True -> string.replace(html, "</body>", script <> "</body>")
    False -> html <> script
  }
}

/// Reconnects when the server restarts, reloads on a `reload` message and
/// shows build output on an `error` message.
pub fn script(session: Session) -> String {
  string.replace(script_template, "__HOWDY_TOKEN__", session.token)
}

const script_template = "<script data-howdy-dev>
(function () {
  var seen = false;
  var overlay = null;
  function showError(output) {
    if (!overlay) {
      overlay = document.createElement('pre');
      overlay.setAttribute('data-howdy-dev-error', '');
      overlay.style.cssText = 'position:fixed;inset:0;margin:0;padding:1.5rem;overflow:auto;background:#1e1e1e;color:#f8f8f2;font:13px/1.5 ui-monospace,Menlo,Consolas,monospace;z-index:2147483647;white-space:pre-wrap';
      document.body.appendChild(overlay);
    }
    overlay.textContent = output;
  }
  function connect() {
    var url = (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '"
  <> path
  <> "?token=__HOWDY_TOKEN__';
    var socket = new WebSocket(url);
    socket.onopen = function () { if (seen) { location.reload(); } seen = true; };
    socket.onmessage = function (event) {
      var message = JSON.parse(event.data);
      if (message.kind === 'reload') { location.reload(); }
      if (message.kind === 'error') { showError(message.output); }
    };
    socket.onclose = function () { setTimeout(connect, 500); };
  }
  connect();
})();
</script>"
