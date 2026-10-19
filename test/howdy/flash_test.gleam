import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/string
import howdy
import howdy/controller
import howdy/cookie
import howdy/flash.{Danger, Info, Message, Success}
import howdy/testing

const secret = "a secret that is at least thirty-two bytes long"

fn app(flash: flash.Flash) -> howdy.App {
  howdy.new()
  |> howdy.controller(
    controller.new("/")
    |> controller.post("/save", fn(ctx) {
      controller.status(ctx, 303)
      |> response.set_header("location", "/")
      |> flash.put(flash, Success, "Saved")
      |> flash.put(flash, Info, "Emails go out tonight")
    })
    |> controller.get("/", fn(ctx) {
      use messages <- flash.take(ctx, flash)
      controller.text(
        ctx,
        list.map(messages, fn(message) { message.text }) |> string.join("|"),
      )
    })
    |> controller.get("/again", fn(ctx) {
      use _ <- flash.take(ctx, flash)
      controller.status(ctx, 303)
      |> response.set_header("location", "/")
      |> flash.put(flash, Danger, "Try again")
    }),
  )
}

fn flash_cookie(res) -> Result(String, Nil) {
  testing.cookies(res) |> list.key_find("howdy_flash")
}

pub fn put_then_take_test() {
  let flash = flash.new(secret:)
  let posted = testing.post_form("/save", []) |> testing.send(app(flash))
  assert posted.status == 303
  let assert Ok(value) = flash_cookie(posted)

  let shown =
    testing.get("/")
    |> testing.cookie("howdy_flash", value)
    |> testing.send(app(flash))
  assert testing.text(shown) == "Saved|Emails go out tonight"
  // Taking the messages clears them, with the same options they were set
  // with.
  assert flash_cookie(shown) == Ok("")
  let assert Ok(header) = response.get_header(shown, "set-cookie")
  assert string.contains(header, "Max-Age=0")
}

pub fn put_adds_to_one_cookie_test() {
  let posted =
    testing.post_form("/save", []) |> testing.send(app(flash.new(secret:)))
  let set = list.filter(posted.headers, fn(header) { header.0 == "set-cookie" })
  assert list.length(set) == 1
}

pub fn nothing_to_take_test() {
  let res = testing.get("/") |> testing.send(app(flash.new(secret:)))
  assert testing.text(res) == ""
  // No cookie was sent, so none is cleared.
  assert flash_cookie(res) == Error(Nil)
}

pub fn a_cookie_signed_with_another_secret_is_ignored_test() {
  let other = flash.new(secret: string.repeat("x", 32))
  let posted = testing.post_form("/save", []) |> testing.send(app(other))
  let assert Ok(value) = flash_cookie(posted)

  let res =
    testing.get("/")
    |> testing.cookie("howdy_flash", value)
    |> testing.send(app(flash.new(secret:)))
  assert testing.text(res) == ""
  // A bad cookie is still cleared.
  assert flash_cookie(res) == Ok("")
}

pub fn a_tampered_cookie_is_ignored_test() {
  let flash = flash.new(secret:)
  let posted = testing.post_form("/save", []) |> testing.send(app(flash))
  let assert Ok(value) = flash_cookie(posted)
  let assert Ok(#(_, signature)) = string.split_once(value, ".")
  // `[["danger","Pay here"]]`, with the original signature.
  let forged = "W1siZGFuZ2VyIiwiUGF5IGhlcmUiXV0." <> signature

  list.each([forged, "garbage", "", value <> "x"], fn(value) {
    let res =
      testing.get("/")
      |> testing.cookie("howdy_flash", value)
      |> testing.send(app(flash))
    assert testing.text(res) == ""
  })
}

pub fn messages_put_while_taking_are_kept_test() {
  let flash = flash.new(secret:)
  let posted = testing.post_form("/save", []) |> testing.send(app(flash))
  let assert Ok(value) = flash_cookie(posted)

  let res =
    testing.get("/again")
    |> testing.cookie("howdy_flash", value)
    |> testing.send(app(flash))
  // The handler's new message replaces the old ones rather than being
  // cleared along with them.
  let assert Ok(value) = flash_cookie(res)
  let shown =
    testing.get("/")
    |> testing.cookie("howdy_flash", value)
    |> testing.send(app(flash))
  assert testing.text(shown) == "Try again"
}

pub fn peek_does_not_clear_test() {
  let flash = flash.new(secret:)
  let posted = testing.post_form("/save", []) |> testing.send(app(flash))
  let assert Ok(value) = flash_cookie(posted)
  let req = testing.get("/") |> testing.cookie("howdy_flash", value)
  assert flash.peek(req, flash)
    == [Message(Success, "Saved"), Message(Info, "Emails go out tonight")]
  assert flash.peek(testing.get("/"), flash) == []
}

pub fn oldest_messages_are_dropped_when_too_large_test() {
  let flash = flash.new(secret:)
  let long = string.repeat("a", 1000)
  let res =
    [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    |> list.fold(response.new(303), fn(res, n) {
      flash.put(res, flash, Info, string.inspect(n) <> long)
    })
  let assert Ok(header) = response.get_header(res, "set-cookie")
  assert string.byte_size(header) < 4096
  let assert [#("howdy_flash", value)] =
    list.filter_map(res.headers, fn(header) {
      case header {
        #("set-cookie", "howdy_flash=" <> rest) -> {
          let assert Ok(#(value, _)) = string.split_once(rest, ";")
          Ok(#("howdy_flash", value))
        }
        _ -> Error(Nil)
      }
    })
  let req = testing.get("/") |> request.set_cookie("howdy_flash", value)
  let messages = flash.peek(req, flash)
  let assert Ok(last) = list.last(messages)
  assert last.text == "10" <> long
  assert list.length(messages) < 10
  assert messages != []
}

pub fn one_huge_message_is_cut_test() {
  let flash = flash.new(secret:)
  let res =
    response.new(303) |> flash.put(flash, Info, string.repeat("é", 5000))
  let assert Ok(header) = response.get_header(res, "set-cookie")
  assert string.byte_size(header) < 4096
}

pub fn options_and_name_test() {
  let flash =
    flash.new(secret:)
    |> flash.cookie_options(cookie.defaults() |> cookie.secure(False))
    |> flash.cookie_name("notice")
  let res = response.new(303) |> flash.put(flash, Info, "Hi")
  let assert Ok(header) = response.get_header(res, "set-cookie")
  assert string.starts_with(header, "notice=")
  assert !string.contains(header, "Secure")
}
