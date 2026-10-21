//// Cross-origin resource sharing (CORS) middleware.
////
//// Browsers block JavaScript on one origin from reading responses served by
//// another unless the response says it is allowed. This middleware adds
//// those headers and answers the `OPTIONS` preflight requests browsers send
//// before non-simple cross-origin requests.
////
//// ```gleam
//// import howdy/cors
////
//// let policy =
////   cors.new()
////   |> cors.allow_origins(["https://app.example.com"])
////   |> cors.allow_methods([http.Get, http.Post, http.Delete])
////   |> cors.allow_headers(["content-type", "authorization"])
////   |> cors.allow_credentials()
////   |> cors.max_age(600)
////
//// howdy.new()
//// |> howdy.middleware(cors.middleware(policy))
//// |> howdy.middleware(require_api_key)
//// ```
////
//// Add it before any middleware that could reject a request, such as
//// authentication or rate limiting. Preflights carry no credentials, so an
//// auth middleware that ran first would answer them with `401` and the
//// browser would never make the real request.
////
//// For a public API with no cookies or auth headers, `cors.allow_all()` is
//// a complete policy.
////
//// ## How requests are handled
////
//// - Requests without an `origin` header are not cross-origin. They pass
////   through without CORS headers, but still vary by Origin when the policy
////   can allow cross-origin requests.
//// - A preflight is an `OPTIONS` request with `origin` and
////   `access-control-request-method` headers. The middleware answers it
////   directly with `204` and never calls the handler. If the origin is not
////   allowed, the `204` carries no CORS headers, so the browser blocks the
////   real request.
//// - Any other request with an `origin` runs as normal, and the response
////   gains `access-control-allow-origin` and friends when the origin is
////   allowed. This includes error responses, so the browser can read a
////   `422` from a handler rather than reporting a CORS failure.
////
//// Preflights reach the middleware because the router answers `OPTIONS`
//// for any path that has routes, through the controller's middleware, even
//// when no `OPTIONS` route was declared. Paths with no routes at all are
//// `404` before any middleware runs, so they carry no CORS headers.
////
//// ## Origins
////
//// An origin is the scheme, host and port a page was loaded from, such as
//// `https://app.example.com` or `http://localhost:5173`. Give the full
//// origin with no path or trailing slash. Sandboxed pages send the literal
//// origin `null`, which you may list explicitly.
////
//// Allowing any origin together with credentials is refused, because it lets
//// every website on the internet make authenticated requests on behalf of
//// your users. If you really want that, `allow_origins_matching` with a
//// function that always returns `True` states the intent explicitly.

import gleam/http.{type Method}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import howdy/content.{type Content}
import howdy/context.{type Body}
import howdy/controller.{type Context, type Middleware, type Next}

/// A CORS policy. Build with `new` or `allow_all` and the setters, then
/// turn it into middleware with `middleware`.
pub opaque type Config {
  Config(
    origins: Origins,
    methods: List(Method),
    headers: Headers,
    exposed: List(String),
    credentials: Bool,
    max_age: Option(Int),
  )
}

type Origins {
  NoOrigins
  AnyOrigin
  Origins(List(String))
  Matching(fn(String) -> Bool)
}

type Headers {
  AnyHeader
  Headers(List(String))
}

/// A policy that allows no origins. Add some with `allow_origins`,
/// `allow_any_origin` or `allow_origins_matching`.
///
/// Methods default to `GET`, `HEAD`, `POST`, `PUT`, `PATCH` and `DELETE`.
/// No request headers beyond the browser's safelist are allowed, no
/// response headers are exposed, credentials are not allowed, and
/// preflights are not cached.
pub fn new() -> Config {
  Config(
    origins: NoOrigins,
    methods: [http.Get, http.Head, http.Post, http.Put, http.Patch, http.Delete],
    headers: Headers([]),
    exposed: [],
    credentials: False,
    max_age: None,
  )
}

/// A policy for public APIs: any origin, the default methods, and whatever
/// request headers the browser asks for. Credentials stay disallowed.
pub fn allow_all() -> Config {
  new() |> allow_any_origin |> allow_any_header
}

/// Allow exactly these origins. Each must be `null` or of the form
/// `scheme://host` with an optional port; anything else panics as a
/// configuration error. Comparison is case-insensitive.
pub fn allow_origins(config: Config, origins: List(String)) -> Config {
  let origins =
    list.map(origins, fn(origin) {
      let assert True = valid_origin(origin)
        as { "cors: invalid origin \"" <> origin <> "\"" }
      string.lowercase(origin)
    })
  Config(..config, origins: Origins(origins))
}

/// Allow every origin. Responses carry `access-control-allow-origin: *`,
/// which browsers refuse to combine with credentials.
pub fn allow_any_origin(config: Config) -> Config {
  Config(..config, origins: AnyOrigin)
}

/// Allow origins the function accepts. The function receives the `origin`
/// header exactly as sent, such as `https://tenant-a.example.com`, and
/// runs on every cross-origin request.
pub fn allow_origins_matching(
  config: Config,
  allow: fn(String) -> Bool,
) -> Config {
  Config(..config, origins: Matching(allow))
}

/// The methods browsers may use for cross-origin requests, sent on
/// preflights as `access-control-allow-methods`.
pub fn allow_methods(config: Config, methods: List(Method)) -> Config {
  Config(..config, methods: list.unique(methods))
}

/// Request headers browsers may send beyond the safelist, such as
/// `content-type` for JSON bodies or `authorization`.
pub fn allow_headers(config: Config, headers: List(String)) -> Config {
  Config(..config, headers: Headers(normalise(headers)))
}

/// Allow whatever request headers the browser asks for on a preflight, by
/// echoing `access-control-request-headers` back.
pub fn allow_any_header(config: Config) -> Config {
  Config(..config, headers: AnyHeader)
}

/// Response headers browser JavaScript may read. Without this, scripts see
/// only the safelisted headers such as `content-type`.
pub fn expose_headers(config: Config, headers: List(String)) -> Config {
  Config(..config, exposed: normalise(headers))
}

/// Allow cookies, `authorization` headers and client certificates on
/// cross-origin requests. Requires a specific origin policy: combining this
/// with `allow_any_origin` panics when the middleware is built.
pub fn allow_credentials(config: Config) -> Config {
  Config(..config, credentials: True)
}

/// How many seconds browsers may cache a preflight response. Negative
/// values are clamped to zero.
pub fn max_age(config: Config, seconds: Int) -> Config {
  Config(..config, max_age: Some(int.max(seconds, 0)))
}

/// Turn a policy into middleware. Panics if the policy allows any origin
/// together with credentials.
pub fn middleware(config: Config) -> Middleware {
  let unsafe = case config.origins {
    AnyOrigin -> config.credentials
    _ -> False
  }
  let assert False = unsafe
    as "cors: allow_credentials cannot be combined with allow_any_origin; list the origins or use allow_origins_matching"

  fn(ctx: Context, next: Next) {
    case request.get_header(ctx.request, "origin") {
      Error(Nil) -> next(ctx) |> vary(config)
      Ok(origin) ->
        case
          ctx.request.method,
          request.get_header(ctx.request, "access-control-request-method")
        {
          http.Options, Ok(_) -> preflight(config, ctx.request, origin)
          _, _ -> next(ctx) |> actual(config, origin)
        }
    }
  }
}

// -- Responses ---------------------------------------------------------------

fn preflight(
  config: Config,
  request: Request(Body),
  origin: String,
) -> Response(Content) {
  let res =
    response.new(204)
    |> response.set_body(content.Empty)
    |> vary(config)
  case allow_origin(config, origin) {
    None -> res
    Some(value) ->
      res
      |> response.set_header("access-control-allow-origin", value)
      |> set_list(
        "access-control-allow-methods",
        config.methods |> list.map(http.method_to_string),
      )
      |> set_list(
        "access-control-allow-headers",
        allowed_headers(config, request),
      )
      |> credentials(config)
      |> set_optional(
        "access-control-max-age",
        option.map(config.max_age, int.to_string),
      )
  }
}

fn actual(
  res: Response(Content),
  config: Config,
  origin: String,
) -> Response(Content) {
  let res = vary(res, config)
  case allow_origin(config, origin) {
    None -> res
    Some(value) ->
      res
      |> response.set_header("access-control-allow-origin", value)
      |> credentials(config)
      |> set_list("access-control-expose-headers", config.exposed)
  }
}

/// The `access-control-allow-origin` value for a request from `origin`, or
/// `None` when the origin is not allowed.
fn allow_origin(config: Config, origin: String) -> Option(String) {
  case config.origins {
    NoOrigins -> None
    AnyOrigin -> Some("*")
    Origins(allowed) ->
      case list.contains(allowed, string.lowercase(origin)) {
        True -> Some(origin)
        False -> None
      }
    Matching(allow) ->
      case allow(origin) {
        True -> Some(origin)
        False -> None
      }
  }
}

fn allowed_headers(config: Config, request: Request(Body)) -> List(String) {
  case config.headers {
    Headers(headers) -> headers
    AnyHeader ->
      case request.get_header(request, "access-control-request-headers") {
        Ok(requested) -> normalise(string.split(requested, ","))
        Error(Nil) -> []
      }
  }
}

fn credentials(res: Response(body), config: Config) -> Response(body) {
  case config.credentials {
    True -> response.set_header(res, "access-control-allow-credentials", "true")
    False -> res
  }
}

/// Responses differ by Origin, including its absence (even for `*`), and preflights
/// that echo requested headers differ by those too. Tell caches so.
fn vary(res: Response(body), config: Config) -> Response(body) {
  let res = case config.origins {
    NoOrigins -> res
    AnyOrigin | Origins(_) | Matching(_) -> add_vary(res, "origin")
  }
  case res.status == 204, config.headers {
    True, AnyHeader -> add_vary(res, "access-control-request-headers")
    _, _ -> res
  }
}

fn add_vary(res: Response(body), name: String) -> Response(body) {
  let existing =
    res.headers
    |> list.filter(fn(header) { string.lowercase(header.0) == "vary" })
    |> list.map(fn(header) { header.1 })
    |> string.join(", ")
  let names = normalise(string.split(existing, ","))
  case list.contains(names, "*") || list.contains(names, name) {
    True -> res
    False ->
      response.set_header(res, "vary", case existing {
        "" -> name
        _ -> existing <> ", " <> name
      })
  }
}

fn set_list(
  res: Response(body),
  name: String,
  values: List(String),
) -> Response(body) {
  case values {
    [] -> res
    _ -> response.set_header(res, name, string.join(values, ", "))
  }
}

fn set_optional(
  res: Response(body),
  name: String,
  value: Option(String),
) -> Response(body) {
  case value {
    Some(value) -> response.set_header(res, name, value)
    None -> res
  }
}

// -- Validation --------------------------------------------------------------

/// Trim, lowercase, drop blanks and duplicates. Header names are
/// case-insensitive, and browsers send them lowercased on preflights.
fn normalise(headers: List(String)) -> List(String) {
  headers
  |> list.map(fn(header) { header |> string.trim |> string.lowercase })
  |> list.filter(fn(header) { header != "" })
  |> list.unique
}

fn valid_origin(origin: String) -> Bool {
  case origin, string.split_once(origin, "://") {
    "null", _ -> True
    _, Ok(#(scheme, host)) ->
      scheme != ""
      && host != ""
      && !string.contains(host, "/")
      && !string.contains(host, "*")
      && !string.contains(host, " ")
    _, Error(Nil) -> False
  }
}
