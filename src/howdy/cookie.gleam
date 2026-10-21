//// Cookie extraction and response helpers.
////
//// Reading uses `use`, like `howdy/query`. Missing required cookies,
//// duplicate names, and invalid value encoding return JSON `400` responses.
//// Malformed cookie pairs are ignored by the HTTP parser.
//// Values are percent-encoded when set and percent-decoded when read.
//// These helpers do not sign cookies or validate sessions.
////
//// ```gleam
//// use theme <- cookie.string_or(ctx, "theme", default: "system")
//// controller.text(ctx, theme)
//// |> cookie.set("theme", theme, cookie.defaults())
//// ```

import gleam/http
import gleam/http/cookie as http_cookie
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option}
import gleam/string as text
import gleam/uri
import howdy/content.{type Content}
import howdy/controller.{type GuardedContext}
import howdy/service

pub type SameSite {
  Lax
  Strict
  None
}

/// Build with `defaults` and the option setters.
pub opaque type Options {
  Options(attributes: http_cookie.Attributes)
}

/// Secure, HttpOnly, SameSite=Lax, Path=/, with no Domain or Max-Age.
/// Without Max-Age the cookie lasts for the browser session.
pub fn defaults() -> Options {
  Options(http_cookie.defaults(http.Https))
}

/// Set the lifetime in seconds. Zero or negative values expire the cookie.
pub fn max_age(options: Options, seconds: Int) -> Options {
  Options(
    http_cookie.Attributes(..options.attributes, max_age: option.Some(seconds)),
  )
}

/// Set SameSite. `None` requires Secure when setting or deleting a cookie.
pub fn same_site(options: Options, policy: SameSite) -> Options {
  let policy = case policy {
    Lax -> http_cookie.Lax
    Strict -> http_cookie.Strict
    None -> http_cookie.None
  }
  Options(
    http_cookie.Attributes(..options.attributes, same_site: option.Some(policy)),
  )
}

/// Set Secure. Use `secure(False)` explicitly for local HTTP development.
pub fn secure(options: Options, enabled: Bool) -> Options {
  Options(http_cookie.Attributes(..options.attributes, secure: enabled))
}

/// Set HttpOnly. Disable only when browser JavaScript needs the value.
pub fn http_only(options: Options, enabled: Bool) -> Options {
  Options(http_cookie.Attributes(..options.attributes, http_only: enabled))
}

/// Set the cookie path. Must start with / and contain printable ASCII
/// without semicolons. Invalid configuration panics.
pub fn path(options: Options, value: String) -> Options {
  let assert True = text.starts_with(value, "/") && valid_attribute(value)
    as "invalid cookie path"
  Options(
    http_cookie.Attributes(..options.attributes, path: option.Some(value)),
  )
}

/// Set the domain. Omit this to keep the cookie limited to the current host.
/// Accepts ASCII letters, digits, dots, and hyphens; invalid input panics.
pub fn domain(options: Options, value: String) -> Options {
  let assert True =
    value != ""
    && list.all(text.to_graphemes(value), fn(char) {
      text.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-",
        char,
      )
    })
    as "invalid cookie domain"
  Options(
    http_cookie.Attributes(..options.attributes, domain: option.Some(value)),
  )
}

/// Read a required cookie, returning a JSON `400` when absent.
pub fn string(
  ctx: GuardedContext(guarded),
  name: String,
  next: fn(String) -> Response(Content),
) -> Response(Content) {
  use value <- optional_string(ctx, name)
  case value {
    option.Some(value) -> next(value)
    option.None -> invalid(ctx, "missing cookie " <> name)
  }
}

/// Read an optional cookie. Empty values remain Some("").
/// Duplicate names or invalid percent encoding return a JSON `400`.
pub fn optional_string(
  ctx: GuardedContext(guarded),
  name: String,
  next: fn(Option(String)) -> Response(Content),
) -> Response(Content) {
  let values =
    request.get_cookies(ctx.request)
    |> list.filter(fn(pair) { pair.0 == name })
  case values {
    [] -> next(option.None)
    [#(_, value)] ->
      case uri.percent_decode(value) {
        Ok(value) -> next(option.Some(value))
        Error(Nil) -> invalid(ctx, "cookie " <> name <> " has invalid encoding")
      }
    _ -> invalid(ctx, "cookie " <> name <> " must occur only once")
  }
}

/// Use the default only when the cookie is absent.
pub fn string_or(
  ctx: GuardedContext(guarded),
  name: String,
  default default: String,
  next next: fn(String) -> Response(Content),
) -> Response(Content) {
  use value <- optional_string(ctx, name)
  next(option.unwrap(value, default))
}

/// Append a cookie as a separate Set-Cookie header, preserving the response.
/// Values are percent-encoded, including literal percent signs.
/// Invalid names or incompatible options panic as configuration errors.
pub fn set(
  res: Response(body),
  name: String,
  value: String,
  options: Options,
) -> Response(body) {
  check(name, options)
  response.set_cookie(res, name, uri.percent_encode(value), options.attributes)
}

/// Expire a cookie using an empty value, Max-Age=0, and an expiry in the past.
/// Use the same path and domain as when setting it. Other headers are preserved.
/// Invalid names or incompatible options panic as configuration errors.
pub fn delete(
  res: Response(body),
  name: String,
  options: Options,
) -> Response(body) {
  check(name, options)
  response.expire_cookie(res, name, options.attributes)
}

/// Whether `name` is a valid cookie name: one or more RFC 6265 token
/// characters. `set` and `delete` treat an invalid name as a programming
/// error and panic, like a malformed route pattern would, since names are
/// normally literals; an app that builds a name from data should check it
/// with this first.
pub fn valid_name(name: String) -> Bool {
  name != ""
  && list.all(text.to_graphemes(name), fn(char) {
    text.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~",
      char,
    )
  })
}

fn check(name: String, options: Options) -> Nil {
  let assert True = valid_name(name) as "invalid cookie name"
  let assert True =
    options.attributes.same_site != option.Some(http_cookie.None)
    || options.attributes.secure
    as "SameSite=None cookies require Secure"
  Nil
}

fn valid_attribute(value: String) -> Bool {
  case value {
    "" -> True
    _ -> valid_attribute_bytes(<<value:utf8>>)
  }
}

fn valid_attribute_bytes(value: BitArray) -> Bool {
  case value {
    <<>> -> True
    <<byte, rest:bytes>> ->
      byte >= 32 && byte <= 126 && byte != 59 && valid_attribute_bytes(rest)
    _ -> False
  }
}

fn invalid(ctx: GuardedContext(guarded), message: String) -> Response(Content) {
  service.error_response(ctx, service.Invalid(message))
}
