import gleam/http/request
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import howdy
import howdy/content.{type Content}
import howdy/controller
import howdy/cookie
import howdy/testing

fn app(handler: controller.Handler) -> howdy.App {
  howdy.new()
  |> howdy.controller(controller.new("/") |> controller.get("/", handler))
}

/// Send a request with raw headers, so tests can produce repeated `cookie`
/// headers and malformed pairs that `testing.cookie` would never build.
fn send(headers: List(#(String, String)), handler: controller.Handler) {
  let req = testing.get("/")
  request.Request(..req, headers:) |> testing.send(app(handler))
}

fn bad_request(res: Response(Content), message: String) {
  assert res.status == 400
  assert response.get_header(res, "content-type")
    == Ok("application/json; charset=utf-8")
  assert testing.error(res) == Ok(message)
}

pub fn read_required_and_optional_test() {
  let res =
    send([#("cookie", "theme=dark; empty=; token=a+b==")], fn(ctx) {
      use theme <- cookie.string(ctx, "theme")
      use empty <- cookie.optional_string(ctx, "empty")
      use absent <- cookie.optional_string(ctx, "absent")
      use token <- cookie.string(ctx, "token")
      assert theme == "dark"
      assert empty == Some("")
      assert absent == None
      assert token == "a+b=="
      controller.text(ctx, theme)
    })
  assert res.status == 200
  assert testing.text(res) == "dark"
}

pub fn default_only_when_missing_test() {
  list.each(
    [#("", "system"), #("theme=", ""), #("theme=dark", "dark")],
    fn(pair) {
      let res =
        send([#("cookie", pair.0)], fn(ctx) {
          use theme <- cookie.string_or(ctx, "theme", default: "system")
          controller.text(ctx, theme)
        })
      assert testing.text(res) == pair.1
    },
  )
}

pub fn missing_required_stops_handler_test() {
  let res =
    send([], fn(ctx) {
      use _ <- cookie.string(ctx, "theme")
      panic as "must not continue"
    })
  bad_request(res, "missing cookie theme")
}

pub fn duplicates_and_invalid_encoding_stop_all_readers_test() {
  list.each(
    [
      #(
        [#("cookie", "theme=dark; theme=light")],
        "cookie theme must occur only once",
      ),
      #(
        [#("cookie", "theme=dark"), #("cookie", "theme=light")],
        "cookie theme must occur only once",
      ),
      #([#("cookie", "theme=%GG")], "cookie theme has invalid encoding"),
    ],
    fn(pair) {
      list.each(
        [
          fn(ctx) {
            use _ <- cookie.string(ctx, "theme")
            panic as "must not continue"
          },
          fn(ctx) {
            use _ <- cookie.optional_string(ctx, "theme")
            panic as "must not continue"
          },
          fn(ctx) {
            use _ <- cookie.string_or(ctx, "theme", default: "system")
            panic as "must not continue"
          },
        ],
        fn(handler) { bad_request(send(pair.0, handler), pair.1) },
      )
    },
  )
}

pub fn malformed_pairs_are_ignored_test() {
  let res =
    send([#("cookie", "broken; =no; bad key=no; theme=dark")], fn(ctx) {
      use theme <- cookie.string(ctx, "theme")
      controller.text(ctx, theme)
    })
  assert testing.text(res) == "dark"
}

pub fn secure_defaults_test() {
  let res =
    response.new(201)
    |> response.set_body("unchanged")
    |> response.set_header("x-test", "kept")
    |> cookie.set("theme", "dark", cookie.defaults())
  assert res.status == 201
  assert res.body == "unchanged"
  assert response.get_header(res, "x-test") == Ok("kept")
  assert response.get_header(res, "set-cookie")
    == Ok("theme=dark; Path=/; Secure; HttpOnly; SameSite=Lax")
}

pub fn options_test() {
  let options =
    cookie.defaults()
    |> cookie.max_age(60 * 60 * 24 * 30)
    |> cookie.same_site(cookie.Strict)
    |> cookie.path("/account")
    |> cookie.domain("example.com")
    |> cookie.secure(False)
    |> cookie.http_only(False)
  let res = response.new(200) |> cookie.set("theme", "dark", options)
  assert response.get_header(res, "set-cookie")
    == Ok(
      "theme=dark; Max-Age=2592000; Domain=example.com; Path=/account; SameSite=Strict",
    )
}

pub fn same_site_none_keeps_secure_test() {
  let options = cookie.defaults() |> cookie.same_site(cookie.None)
  let res = response.new(200) |> cookie.set("theme", "dark", options)
  assert response.get_header(res, "set-cookie")
    == Ok("theme=dark; Path=/; Secure; HttpOnly; SameSite=None")
}

pub fn multiple_cookies_and_deletion_preserve_headers_test() {
  let options =
    cookie.defaults()
    |> cookie.path("/account")
    |> cookie.domain("example.com")
    |> cookie.max_age(3600)
  let res =
    response.new(202)
    |> response.set_body("kept")
    |> cookie.set("first", "one", cookie.defaults())
    |> cookie.set("second", "two", cookie.defaults())
    |> cookie.delete("theme", options)
  let headers = list.filter(res.headers, fn(pair) { pair.0 == "set-cookie" })
  assert list.length(headers) == 3
  assert list.contains(headers, #(
    "set-cookie",
    "first=one; Path=/; Secure; HttpOnly; SameSite=Lax",
  ))
  assert list.contains(headers, #(
    "set-cookie",
    "second=two; Path=/; Secure; HttpOnly; SameSite=Lax",
  ))
  assert response.get_header(res, "set-cookie")
    == Ok(
      "theme=; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0; Domain=example.com; Path=/account; Secure; HttpOnly; SameSite=Lax",
    )
  assert res.status == 202
  assert res.body == "kept"
}

pub fn values_round_trip_without_header_injection_test() {
  let echo_theme = fn(ctx) {
    use theme <- cookie.string(ctx, "theme")
    controller.text(ctx, theme)
  }
  list.each(
    [
      "",
      "dark",
      "hello world",
      "a+b==",
      "100%",
      "雪",
      "x; other=bad\r\nX-Evil: yes",
    ],
    fn(value) {
      let res =
        response.new(200) |> cookie.set("theme", value, cookie.defaults())
      let assert Ok(header) = response.get_header(res, "set-cookie")
      assert !string.contains(header, "\r")
      assert !string.contains(header, "\n")

      // What the browser would send back is what the handler reads.
      let received =
        testing.get("/")
        |> testing.cookie("theme", value)
        |> testing.send(app(echo_theme))
      assert testing.text(received) == value
    },
  )
}

pub fn response_cookies_are_decoded_test() {
  let res =
    testing.get("/")
    |> testing.send(
      app(fn(ctx) {
        controller.text(ctx, "ok")
        |> cookie.set("theme", "dark mode", cookie.defaults())
        |> cookie.set("lang", "en", cookie.defaults())
        |> cookie.delete("old", cookie.defaults())
      }),
    )
  assert testing.cookies(res)
    == [#("theme", "dark mode"), #("lang", "en"), #("old", "")]
}

pub fn guarded_context_test() {
  let routes =
    controller.guarded("/", fn(_) { Ok("guard value") })
    |> controller.get("/", fn(ctx) {
      use theme <- cookie.string_or(ctx, "theme", default: "system")
      assert ctx.guard == "guard value"
      controller.text(ctx, theme)
      |> cookie.set("theme", theme, cookie.defaults())
    })
    |> controller.build
  let res =
    testing.get("/") |> testing.send(howdy.new() |> howdy.controller(routes))
  assert res.status == 200
  assert testing.text(res) == "system"
  assert testing.cookies(res) == [#("theme", "system")]
}
