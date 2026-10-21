import gleam/erlang/atom
import gleam/erlang/process.{type Pid}
import gleam/http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import howdy
import howdy/controller.{type Context}
import howdy/testing
import howdy/websocket
import howdy/websocket/channel

@external(erlang, "howdy_test_ffi", "channel_member")
fn channel_member(topics: List(String)) -> Pid

@external(erlang, "howdy_test_ffi", "stop_member")
fn stop_member(pid: Pid) -> Nil

@external(erlang, "howdy_channel_ffi", "channel_join")
fn join_pid(topic: String, pid: Pid) -> Nil

@external(erlang, "howdy_channel_ffi", "tuple_second")
fn tuple_second(message: dynamic.Dynamic) -> websocket.Frame

import gleam/dynamic

/// Receive what `channel.broadcast` sends to a member, as a socket would.
fn receive_frame() -> Result(websocket.Frame, Nil) {
  process.new_selector()
  |> process.select_record(atom.create(websocket.channel_tag), 1, tuple_second)
  |> process.selector_receive(200)
}

// -- upgrade -----------------------------------------------------------------

fn app() {
  howdy.new()
  |> howdy.controller(
    controller.new("ws")
    |> controller.get("/", fn(ctx: Context) {
      websocket.new(fn(_socket) { Nil })
      |> websocket.upgrade(ctx)
    }),
  )
}

pub fn upgrade_without_a_connection_is_426_test() {
  let res = testing.get("/ws") |> testing.send(app())

  assert res.status == 426
}

pub fn untrusted_browser_origins_are_rejected_before_upgrade_test() {
  let res =
    testing.get("/ws")
    |> testing.header("origin", "https://attacker.example")
    |> testing.send(app())
  assert res.status == 403
}

pub fn browser_origins_must_be_single_well_formed_and_same_origin_test() {
  use value <- list.each([
    "null", "", "http://localhost/", "http://localhost?x=1",
    "http://user@localhost", "http://localhost#x", "http://localhost.evil",
    "http://localhost:81", "http://localhost", "http://localhost http://evil",
    "http://localhost%00.evil", "http://localhost\\@evil",
  ])
  assert {
      testing.get("/ws")
      |> testing.header("origin", value)
      |> testing.send(app())
    }.status
    == 403
}

pub fn origin_normalization_test() {
  use value <- list.each(["https://localhost", "https://LOCALHOST:443"])
  assert {
      testing.get("/ws")
      |> testing.header("origin", value)
      |> testing.send(app())
    }.status
    == 426
}

pub fn underscore_hosts_support_same_origin_and_allowlists_test() {
  let origin = "http://my_app.localhost:8000"
  let req = testing.get("/ws") |> testing.header("origin", origin)
  let req =
    request.Request(
      ..req,
      scheme: http.Http,
      host: "my_app.localhost",
      port: Some(8000),
    )
  assert { testing.send(req, app()) }.status == 426
  let allowed_app =
    howdy.new()
    |> howdy.controller(
      controller.new("/ws")
      |> controller.get("/", fn(ctx) {
        websocket.new(fn(_) { Nil })
        |> websocket.allow_origins([origin])
        |> websocket.upgrade(ctx)
      }),
    )
  assert { testing.send(req, allowed_app) }.status == 426
}

pub fn https_and_ipv6_use_request_authority_test() {
  let req = testing.get("/ws") |> testing.header("origin", "https://[::1]:443")
  let req =
    request.Request(..req, scheme: http.Https, host: "[::1]", port: None)
  assert { testing.send(req, app()) }.status == 426
  let req = request.Request(..req, port: Some(8443))
  assert { testing.send(req, app()) }.status == 403
}

pub fn duplicate_origin_is_rejected_test() {
  let req =
    testing.get("/ws")
    |> testing.header("origin", "http://localhost")
    |> request.prepend_header("origin", "http://localhost")
  assert { testing.send(req, app()) }.status == 403
}

pub fn explicit_origins_support_proxies_and_required_origin_test() {
  let app =
    howdy.new()
    |> howdy.controller(
      controller.new("/ws")
      |> controller.get("/", fn(ctx) {
        websocket.new(fn(_) { Nil })
        |> websocket.allow_origins(["https://app.example"])
        |> websocket.require_origin
        |> websocket.upgrade(ctx)
      }),
    )
  assert { testing.get("/ws") |> testing.send(app) }.status == 403
  assert {
      testing.get("/ws")
      |> testing.header("origin", "http://localhost")
      |> testing.send(app)
    }.status
    == 403
  assert {
      testing.get("/ws")
      |> testing.header("origin", "https://app.example:443")
      |> testing.send(app)
    }.status
    == 426
  assert {
      testing.get("/ws")
      |> testing.header("origin", "https://evil.example")
      |> testing.header("x-forwarded-host", "evil.example")
      |> testing.send(app)
    }.status
    == 403
}

/// Sent through a proxy that ends TLS and passes the browser's host on, as
/// Traefik and Caddy do: the app sees plain HTTP.
fn behind_proxy(headers: List(#(String, String))) {
  let req = testing.get("/ws")
  let req =
    request.Request(..req, scheme: http.Http, host: "app.example", port: None)
  list.fold(headers, req, fn(req, header) {
    testing.header(req, header.0, header.1)
  })
}

fn from(req, origin: String) -> Int {
  { req |> testing.header("origin", origin) |> testing.send(app()) }.status
}

pub fn same_origin_follows_a_tls_terminating_proxy_test() {
  let proxied = behind_proxy([#("x-forwarded-proto", "https")])
  assert from(proxied, "https://app.example") == 426
  assert from(proxied, "https://APP.example:443") == 426
  // Still exact: not the plain HTTP page, another port, or another site.
  assert from(proxied, "http://app.example") == 403
  assert from(proxied, "https://app.example:8443") == 403
  assert from(proxied, "https://evil.example") == 403
  // The browser's port reaches the app in its host header.
  let on_port =
    request.Request(..proxied, port: Some(8443))
    |> testing.header("origin", "https://app.example:8443")
  assert { testing.send(on_port, app()) }.status == 426
  // Traefik forwards a socket's scheme as the browser named it.
  let wss = behind_proxy([#("x-forwarded-proto", "wss")])
  assert from(wss, "https://app.example") == 426
  assert from(wss, "http://app.example") == 403
  let ws = behind_proxy([#("x-forwarded-proto", "ws")])
  assert from(ws, "http://app.example") == 426
  assert from(ws, "https://app.example") == 403
  // Without the header the request's own scheme decides, as before.
  assert from(behind_proxy([]), "https://app.example") == 403
  assert from(behind_proxy([]), "http://app.example") == 426
}

pub fn same_origin_follows_a_forwarded_host_test() {
  // A proxy that rewrote the host, behind another that appended its own.
  let proxied =
    behind_proxy([
      #("x-forwarded-proto", "HTTPS, http"),
      #("x-forwarded-host", "public.example:8443, app.example"),
    ])
  assert from(proxied, "https://public.example:8443") == 426
  assert from(proxied, "https://public.example") == 403
  assert from(proxied, "https://app.example") == 403
  assert from(proxied, "http://app.example") == 403
}

pub fn malformed_forwarded_values_fail_closed_test() {
  // An unknown scheme is ignored; a host that is not one matches nothing.
  let ignored = behind_proxy([#("x-forwarded-proto", "ftp")])
  assert from(ignored, "http://app.example") == 426
  use host <- list.each([
    "app.example/path", "user@app.example", "app.example?x", "*.example",
    "app.example:0", "app.example:99999",
  ])
  let proxied =
    behind_proxy([#("x-forwarded-proto", "https"), #("x-forwarded-host", host)])
  assert from(proxied, "https://app.example") == 403
}

// -- channel -----------------------------------------------------------------

pub fn broadcast_reaches_every_member_test() {
  let topic = "test:everyone"
  join_pid(topic, process.self())

  channel.broadcast_text(topic, "hello")

  assert receive_frame() == Ok(websocket.Text("hello"))
}

pub fn broadcast_json_sends_encoded_text_test() {
  let topic = "test:json"
  join_pid(topic, process.self())

  channel.broadcast_json(topic, json.object([#("n", json.int(1))]))

  assert receive_frame() == Ok(websocket.Text("{\"n\":1}"))
}

pub fn broadcast_is_scoped_to_its_topic_test() {
  join_pid("test:mine", process.self())

  channel.broadcast_text("test:other", "not for you")

  assert receive_frame() == Error(Nil)
}

pub fn broadcast_to_empty_topic_is_fine_test() {
  assert channel.broadcast_text("test:nobody", "hello") == Nil
}

pub fn size_counts_live_members_once_test() {
  let topic = "test:size"
  assert channel.size(topic) == 0

  let a = channel_member([topic])
  let b = channel_member([topic])
  join_pid(topic, a)
  assert channel.size(topic) == 2

  stop_member(a)
  assert channel.size(topic) == 1

  stop_member(b)
  assert channel.size(topic) == 0
}

pub fn joining_twice_delivers_once_test() {
  let topic = "test:twice"
  join_pid(topic, process.self())
  join_pid(topic, process.self())

  channel.broadcast_text(topic, "once")

  assert receive_frame() == Ok(websocket.Text("once"))
  assert receive_frame() == Error(Nil)
}

@external(erlang, "howdy_test_ffi", "scope_pid")
fn scope_pid() -> Result(process.Pid, Nil)

fn await_dead(pid: process.Pid, tries: Int) -> Nil {
  case process.is_alive(pid) {
    False -> Nil
    True if tries > 0 -> {
      process.sleep(5)
      await_dead(pid, tries - 1)
    }
    True -> panic as "process did not die"
  }
}

// The channel scope belongs to the howdy application's supervisor, so it
// comes back if it dies and channels keep working.
pub fn the_channel_scope_is_restarted_test() {
  let topic = "test:scope"
  let _ = channel_member([topic])
  let assert Ok(first) = scope_pid()
  process.kill(first)
  // The kill is asynchronous: until it lands the old scope is still
  // registered, and joining it would fail.
  await_dead(first, 100)
  // Membership is lost with the scope, but the scope itself returns and
  // takes new members.
  let member = channel_member([topic])
  assert channel.size(topic) == 1
  let assert Ok(second) = scope_pid()
  assert second != first
  stop_member(member)
}
