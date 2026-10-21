import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/string
import howdy
import howdy/controller
import howdy/static
import howdy/testing

const root = "test/fixtures/public"

@external(erlang, "howdy_test_ffi", "with_static_tree")
fn with_static_tree(run: fn(String) -> a) -> a

pub fn symlinks_cannot_escape_or_alias_the_public_tree_test() {
  use root <- with_static_tree
  let app = howdy.new() |> howdy.controller(static.serve("/", from: root))
  assert { testing.get("/ok.txt") |> testing.send(app) |> testing.text }
    == "inside"
  assert { testing.get("/") |> testing.send(app) |> testing.text } == "home"
  assert { testing.get("/escape.txt") |> testing.send(app) }.status == 404
  assert { testing.get("/inside-link.txt") |> testing.send(app) }.status == 404
  assert { testing.get("/escape-dir/secret.txt") |> testing.send(app) }.status
    == 404
  assert { testing.get("/nested/") |> testing.send(app) }.status == 404
  let fallback =
    howdy.new()
    |> howdy.controller(
      static.new(from: root) |> static.fallback("escape.txt") |> static.build,
    )
  assert { testing.get("/missing") |> testing.send(fallback) }.status == 404
  let linked =
    howdy.new()
    |> howdy.controller(static.serve("/", from: root <> "/../root-link"))
  assert { testing.get("/ok.txt") |> testing.send(linked) }.status == 404
}

fn app() -> howdy.App {
  let api =
    controller.new("/api")
    |> controller.get("/ping", fn(ctx) { controller.text(ctx, "pong") })

  howdy.new()
  |> howdy.controller(api)
  |> howdy.controller(static.serve("/", from: root))
}

pub fn serves_a_file_test() {
  let res = testing.get("/css/site.css") |> testing.send(app())
  assert res.status == 200
  assert testing.text(res) == "body { color: red }\n"
  assert response.get_header(res, "content-type")
    == Ok("text/css; charset=utf-8")
}

pub fn serves_index_for_root_test() {
  let res = testing.get("/") |> testing.send(app())
  assert res.status == 200
  assert testing.text(res) == "<h1>Home</h1>\n"
  assert response.get_header(res, "content-type")
    == Ok("text/html; charset=utf-8")
}

pub fn serves_index_for_directory_test() {
  let res = testing.get("/docs/") |> testing.send(app())
  assert res.status == 200
  assert testing.text(res) == "<h1>Docs</h1>\n"

  let res = testing.get("/docs") |> testing.send(app())
  assert res.status == 200
}

pub fn unknown_extension_is_octet_stream_test() {
  let res = testing.get("/blob") |> testing.send(app())
  assert res.status == 200
  assert testing.bytes(res) == <<0, 1, 2, 255>>
  assert response.get_header(res, "content-type")
    == Ok("application/octet-stream")
}

pub fn missing_file_is_404_test() {
  let res = testing.get("/nope.txt") |> testing.send(app())
  assert res.status == 404
  assert testing.error(res) == Ok("file not found")
}

pub fn directory_without_index_is_404_test() {
  let res = testing.get("/css") |> testing.send(app())
  assert res.status == 404
}

pub fn traversal_is_404_test() {
  assert { testing.get("/../gleam.toml") |> testing.send(app()) }.status == 404
  assert { testing.get("/css/../../gleam.toml") |> testing.send(app()) }.status
    == 404
  assert { testing.get("/%2e%2e/gleam.toml") |> testing.send(app()) }.status
    == 404
  assert { testing.get("/css%2f..%2f..%2fgleam.toml") |> testing.send(app()) }.status
    == 404
}

pub fn head_is_answered_test() {
  let res = testing.request(http.Head, "/css/site.css") |> testing.send(app())
  assert res.status == 200
}

pub fn other_methods_are_405_test() {
  let res = testing.post("/css/site.css", json.null()) |> testing.send(app())
  assert res.status == 405
  assert response.get_header(res, "allow") == Ok("GET, HEAD")
}

pub fn other_controllers_win_test() {
  let res = testing.get("/api/ping") |> testing.send(app())
  assert res.status == 200
  assert testing.text(res) == "pong"
}

pub fn exact_routes_decide_allowed_methods_test() {
  // The catch-all also matches /api/ping, but only the exact route decides
  // the methods reported. HEAD is there because the GET route answers it.
  let res = testing.post("/api/ping", json.null()) |> testing.send(app())
  assert res.status == 405
  assert response.get_header(res, "allow") == Ok("GET, HEAD")

  // Answered by the exact GET route, not the catch-all's HEAD route.
  let res = testing.request(http.Head, "/api/ping") |> testing.send(app())
  assert res.status == 200
  assert testing.text(res) == "pong"
}

pub fn mounted_under_prefix_test() {
  let app =
    howdy.new()
    |> howdy.controller(static.serve("/assets", from: root))

  let res = testing.get("/assets/css/site.css") |> testing.send(app)
  assert res.status == 200

  let res = testing.get("/css/site.css") |> testing.send(app)
  assert res.status == 404
}

pub fn custom_index_test() {
  let app =
    howdy.new()
    |> howdy.controller(
      static.new(from: root) |> static.index("app.html") |> static.build,
    )

  let res = testing.get("/") |> testing.send(app)
  assert testing.text(res) == "<h1>App</h1>\n"
}

pub fn max_age_test() {
  let app =
    howdy.new()
    |> howdy.controller(
      static.new(from: root) |> static.max_age(seconds: 3600) |> static.build,
    )

  let res = testing.get("/css/site.css") |> testing.send(app)
  assert response.get_header(res, "cache-control") == Ok("public, max-age=3600")

  // A `304` repeats the policy, so a cache that revalidated keeps it.
  let assert Ok(etag) = response.get_header(res, "etag")
  let res =
    testing.get("/css/site.css")
    |> request.set_header("if-none-match", etag)
    |> testing.send(app)
  assert res.status == 304
  assert response.get_header(res, "cache-control") == Ok("public, max-age=3600")

  let res = testing.get("/nope") |> testing.send(app)
  assert response.get_header(res, "cache-control") == Error(Nil)
}

pub fn fallback_test() {
  let app =
    howdy.new()
    |> howdy.controller(
      static.new(from: root) |> static.fallback("app.html") |> static.build,
    )

  let res = testing.get("/users/42") |> testing.send(app)
  assert res.status == 200
  assert testing.text(res) == "<h1>App</h1>\n"

  // Real files still win over the fallback.
  let res = testing.get("/css/site.css") |> testing.send(app)
  assert testing.text(res) == "body { color: red }\n"
}

pub fn single_file_test() {
  let files =
    controller.new("/")
    |> controller.get("/report", fn(ctx) {
      static.file(ctx, root <> "/docs/index.html")
    })
    |> controller.get("/missing", fn(ctx) { static.file(ctx, root <> "/nope") })
  let app = howdy.new() |> howdy.controller(files)

  let res = testing.get("/report") |> testing.send(app)
  assert res.status == 200
  assert testing.text(res) == "<h1>Docs</h1>\n"

  let res = testing.get("/missing") |> testing.send(app)
  assert res.status == 404
}

pub fn content_type_test() {
  assert static.content_type("a/b.js") == "text/javascript; charset=utf-8"
  assert static.content_type("a/b.png") == "image/png"
  assert static.content_type("a/b.json") == "application/json; charset=utf-8"
  assert static.content_type("Makefile") == "application/octet-stream"
}

pub fn static_files_carry_validators_and_answer_304_test() {
  let res = testing.get("/index.html") |> testing.send(app())
  assert res.status == 200
  let assert Ok(etag) = response.get_header(res, "etag")
  let assert Ok(modified) = response.get_header(res, "last-modified")
  assert string.ends_with(modified, " GMT")

  let res =
    testing.get("/index.html")
    |> request.set_header("if-none-match", etag)
    |> testing.send(app())
  assert res.status == 304
  assert response.get_header(res, "etag") == Ok(etag)

  let res =
    testing.get("/index.html")
    |> request.set_header("if-modified-since", modified)
    |> testing.send(app())
  assert res.status == 304

  let res =
    testing.get("/index.html")
    |> request.set_header("if-modified-since", "Thu, 01 Jan 1970 00:00:00 GMT")
    |> testing.send(app())
  assert res.status == 200

  let res =
    testing.get("/index.html")
    |> request.set_header("if-none-match", "\"nope\"")
    |> testing.send(app())
  assert res.status == 200
}
