import gleam/bytes_tree
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/string
import howdy
import howdy/content
import howdy/controller
import howdy/dev
import howdy/dev/internal/reload
import howdy/testing

fn app() -> howdy.App {
  howdy.new()
  |> howdy.controller(
    controller.new("/")
    |> controller.get("/", fn(ctx) {
      controller.html(ctx, "<html><body><h1>Hi</h1></body></html>")
    })
    |> controller.get("/bytes", fn(ctx) {
      controller.html(ctx, "")
      |> response.set_body(content.Bytes(bytes_tree.from_string("<p>raw</p>")))
    })
    |> controller.get("/json", fn(ctx) {
      controller.json(ctx, json.object([#("ok", json.bool(True))]))
    }),
  )
}

fn wrapped() -> howdy.App {
  dev.wrap(app)
}

pub fn html_pages_get_the_reload_script_before_the_body_ends_test() {
  let html = testing.get("/") |> testing.send(wrapped()) |> testing.text
  assert string.contains(html, "<h1>Hi</h1><script data-howdy-dev>")
  assert string.contains(html, "location.host + '/_howdy/reload?token=")
}

pub fn html_without_a_body_tag_gets_the_script_appended_test() {
  let html = testing.get("/bytes") |> testing.send(wrapped()) |> testing.text
  assert string.starts_with(html, "<p>raw</p><script data-howdy-dev>")
}

pub fn other_responses_are_untouched_test() {
  let res = testing.get("/json") |> testing.send(wrapped())
  assert testing.text(res) == "{\"ok\":true}"

  let plain = testing.get("/json") |> testing.send(app())
  assert testing.text(plain) == testing.text(res)
}

pub fn the_reload_socket_is_mounted_test() {
  // Missing authorization must fail before attempting a connection upgrade.
  let res = testing.get(reload.path) |> testing.send(wrapped())
  assert res.status == 403
  let missing = testing.get(reload.path) |> testing.send(app())
  assert missing.status == 404
}

fn token(app: howdy.App) -> String {
  let html = testing.get("/") |> testing.send(app) |> testing.text
  let assert Ok(#(_, rest)) = string.split_once(html, "?token=")
  let assert Ok(#(token, _)) = string.split_once(rest, "'")
  token
}

pub fn reload_requires_current_token_and_same_origin_test() {
  let app = wrapped()
  let secret = token(app)
  let valid =
    testing.get(reload.path <> "?token=" <> secret)
    |> testing.header("origin", "https://localhost")
  assert { testing.send(valid, app) }.status == 426
  assert {
      testing.get(reload.path <> "?token=" <> secret) |> testing.send(app)
    }.status
    == 403
  assert {
      valid
      |> testing.header("origin", "http://evil.example")
      |> testing.send(app)
    }.status
    == 403
  assert {
      testing.get(reload.path <> "?token=wrong")
      |> testing.header("origin", "https://localhost")
      |> testing.send(app)
    }.status
    == 403
  assert {
      testing.get(reload.path <> "?token=" <> secret <> "&token=" <> secret)
      |> testing.header("origin", "https://localhost")
      |> testing.send(app)
    }.status
    == 403
  assert {
      testing.get(reload.path <> "?token=%ZZ")
      |> testing.header("origin", "https://localhost")
      |> testing.send(app)
    }.status
    == 403
  assert { testing.send(valid, wrapped()) }.status == 403
  assert string.length(secret) == 64
  assert token(app) == secret
}

pub fn unapproved_hosts_cannot_read_tokens_or_open_sockets_test() {
  let app = wrapped()
  use path <- list.each(["/", reload.path <> "?token=" <> token(app)])
  let req = testing.get(path) |> testing.header("origin", "http://evil.example")
  let req = request.Request(..req, host: "evil.example")
  assert { testing.send(req, app) }.status == 403
}

pub fn injected_pages_are_not_cacheable_test() {
  let session = reload.new(["localhost"])
  let app =
    howdy.new()
    |> howdy.middleware(reload.inject(session))
    |> howdy.controller(
      controller.new("/")
      |> controller.get("/", fn(ctx) {
        controller.html(ctx, "<p>hello</p>")
        |> response.set_header("content-length", "12")
        |> response.set_header("etag", "old")
        |> response.set_header("last-modified", "old")
        |> response.set_header("cache-control", "public, max-age=3600")
      }),
    )
  let res = testing.get("/") |> testing.send(app)
  assert response.get_header(res, "cache-control") == Ok("no-store")
  assert response.get_header(res, "etag") == Error(Nil)
  assert response.get_header(res, "content-length") == Error(Nil)
  assert response.get_header(res, "last-modified") == Error(Nil)
}
