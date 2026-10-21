//// Flash messages: a short note that survives one redirect, such as
//// "Settings saved" after a form post.
////
//// A form handler does its work, redirects with `303` so a refresh does
//// not post the form again, and puts the message on the redirect. The page
//// it lands on takes the messages, which clears them, and shows them:
////
//// ```gleam
//// import howdy/flash
////
//// let assert Ok(secret) = env.get("SECRET_KEY_BASE")
//// let flash = flash.new(secret:)
////
//// fn save(ctx: Context) {
////   // ... save the settings ...
////   controller.status(ctx, 303)
////   |> response.set_header("location", "/settings")
////   |> flash.put(flash, flash.Success, "Settings saved")
//// }
////
//// fn show(ctx: Context) {
////   use messages <- flash.take(ctx, flash)
////   page(messages)
//// }
//// ```
////
//// `howdy/ui/toast.flashed` turns the messages into toasts.
////
//// The messages travel in a cookie, so they need no server-side storage
//// and work without JavaScript. The cookie is signed with a key derived
//// from the secret, so a message the page shows is always one the app
//// wrote: a cookie planted by someone else, such as from a sibling
//// subdomain, is ignored. Messages are not encrypted, so never put a
//// secret in one. The text is shown as text, never as HTML.
////
//// Flash messages are for feedback on something the user just did. For
//// telling someone about what others did, use notifications, which are
//// kept until read.

import gleam/bit_array
import gleam/bool
import gleam/dynamic/decode
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam/uri
import howdy/content.{type Content}
import howdy/controller.{type GuardedContext}
import howdy/cookie

/// How the message should look.
pub type Level {
  Info
  Success
  Danger
}

pub type Message {
  Message(level: Level, text: String)
}

/// Where flash messages are kept and how they are signed. Build with `new`.
pub opaque type Flash {
  Flash(key: BitArray, name: String, options: cookie.Options)
}

/// The longest a cookie value may be. Browsers accept about 4096 bytes for
/// the name, value and attributes together.
const max_value_bytes = 3800

/// Flash messages signed with a key derived from `secret`. The secret must
/// be at least 32 bytes and should come from the environment, so it stays
/// the same across restarts and every node. The same secret can be shared
/// with other parts of the app, since the flash key is derived from it.
/// A shorter secret panics, as a configuration error.
///
/// The cookie is called `howdy_flash`, and uses `cookie.defaults` with a
/// ten minute lifetime, so a message nobody reads does not turn up much
/// later.
pub fn new(secret secret: String) -> Flash {
  let assert True = string.byte_size(secret) >= 32
    as "howdy/flash: the secret must be at least 32 bytes"
  Flash(
    key: hmac(<<secret:utf8>>, <<"howdy/flash":utf8>>),
    name: "howdy_flash",
    options: cookie.defaults() |> cookie.max_age(600),
  )
}

/// Use other cookie options, such as `cookie.secure(False)` while serving
/// plain HTTP on a host other than `localhost`.
pub fn cookie_options(flash: Flash, options: cookie.Options) -> Flash {
  Flash(..flash, options:)
}

/// Use a different cookie name.
pub fn cookie_name(flash: Flash, name: String) -> Flash {
  let assert True = cookie.valid_name(name) as "howdy/flash: invalid name"
  Flash(..flash, name:)
}

/// Add a message to the response, after any it already carries. Messages
/// are kept in the order they were put, and the oldest are dropped if the
/// cookie would grow too large.
pub fn put(
  res: Response(body),
  flash: Flash,
  level: Level,
  text: String,
) -> Response(body) {
  let earlier = carried(res, flash)
  let headers =
    list.filter(res.headers, fn(header) { !sets(header, flash.name) })
  response.Response(..res, headers:)
  |> cookie.set(
    flash.name,
    encode(flash, list.append(earlier, [Message(level:, text:)])),
    flash.options,
  )
}

/// Read the messages put on the response that led here, and clear them so
/// they show only once. The handler gets an empty list when there are none,
/// or when the cookie was not signed with this flash's key.
///
/// The cookie is cleared on the handler's response, unless the handler put
/// new messages on it itself.
pub fn take(
  ctx: GuardedContext(guarded),
  flash: Flash,
  next: fn(List(Message)) -> Response(Content),
) -> Response(Content) {
  let values =
    request.get_cookies(ctx.request)
    |> list.filter_map(fn(pair) {
      case pair.0 == flash.name {
        True -> Ok(pair.1)
        False -> Error(Nil)
      }
    })
  case values {
    [] -> next([])
    _ -> {
      let messages =
        list.find_map(values, fn(value) {
          uri.percent_decode(value) |> result.try(decode(flash, _))
        })
        |> result.unwrap([])
      let res = next(messages)
      case list.any(res.headers, sets(_, flash.name)) {
        True -> res
        False -> cookie.delete(res, flash.name, flash.options)
      }
    }
  }
}

/// The messages a request carries, without clearing them. For a layout
/// that wants to know whether there are any; a handler showing them should
/// use `take`.
pub fn peek(request: request.Request(body), flash: Flash) -> List(Message) {
  request.get_cookies(request)
  |> list.find_map(fn(pair) {
    case pair.0 == flash.name {
      True -> uri.percent_decode(pair.1) |> result.try(decode(flash, _))
      False -> Error(Nil)
    }
  })
  |> result.unwrap([])
}

// -- Encoding ----------------------------------------------------------------

/// The messages a response already sets, so that `put` can add to them.
fn carried(res: Response(body), flash: Flash) -> List(Message) {
  list.find_map(res.headers, fn(header) {
    case sets(header, flash.name) {
      False -> Error(Nil)
      True -> {
        let value = case string.split_once(header.1, ";") {
          Ok(#(pair, _)) -> pair
          Error(Nil) -> header.1
        }
        let value = string.drop_start(value, string.length(flash.name) + 1)
        uri.percent_decode(value) |> result.try(decode(flash, _))
      }
    }
  })
  |> result.unwrap([])
}

fn sets(header: #(String, String), name: String) -> Bool {
  header.0 == "set-cookie" && string.starts_with(header.1, name <> "=")
}

/// `<payload>.<signature>`, both base64url without padding. Oldest
/// messages are dropped until it fits in a cookie.
fn encode(flash: Flash, messages: List(Message)) -> String {
  let payload =
    json.array(messages, fn(message) {
      json.preprocessed_array([
        json.string(level_code(message.level)),
        json.string(message.text),
      ])
    })
    |> json.to_string
    |> bit_array.from_string
  let value =
    bit_array.base64_url_encode(payload, False)
    <> "."
    <> bit_array.base64_url_encode(hmac(flash.key, payload), False)
  case string.byte_size(value) > max_value_bytes, messages {
    True, [_, _, ..] -> encode(flash, list.drop(messages, 1))
    // One message too long on its own is cut until it fits.
    True, [only] -> {
      let text = string.slice(only.text, 0, string.length(only.text) / 2)
      encode(flash, [Message(..only, text:)])
    }
    _, _ -> value
  }
}

fn decode(flash: Flash, value: String) -> Result(List(Message), Nil) {
  use #(payload, signature) <- result.try(string.split_once(value, "."))
  use payload <- result.try(bit_array.base64_url_decode(payload))
  use signature <- result.try(bit_array.base64_url_decode(signature))
  use <- bool.guard(!equal(hmac(flash.key, payload), signature), Error(Nil))
  use payload <- result.try(bit_array.to_string(payload))
  json.parse(payload, decode.list(message_decoder()))
  |> result.replace_error(Nil)
}

fn message_decoder() -> decode.Decoder(Message) {
  use code <- decode.field(0, decode.string)
  use text <- decode.field(1, decode.string)
  case code {
    "info" -> decode.success(Message(Info, text))
    "success" -> decode.success(Message(Success, text))
    "danger" -> decode.success(Message(Danger, text))
    _ -> decode.failure(Message(Info, text), "a flash level")
  }
}

fn level_code(level: Level) -> String {
  case level {
    Info -> "info"
    Success -> "success"
    Danger -> "danger"
  }
}

@external(erlang, "howdy_flash_ffi", "hmac")
fn hmac(key: BitArray, data: BitArray) -> BitArray

@external(erlang, "howdy_flash_ffi", "equal")
fn equal(a: BitArray, b: BitArray) -> Bool
