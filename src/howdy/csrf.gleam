//// Cross-site request forgery protection for cookie-authenticated writes.
////
//// A page on another site can make a browser send a request to yours, and
//// the browser attaches the user's cookies because it decides by
//// destination, not by who asked. An HTML form post needs no CORS
//// preflight, so nothing stops the request from arriving. This middleware
//// rejects writes that did not come from an origin you named.
////
//// ```gleam
//// import howdy/csrf
////
//// howdy.new()
//// |> howdy.middleware(csrf.middleware(csrf.new(["https://example.com"])))
//// ```
////
//// `GET`, `HEAD` and `OPTIONS` pass through untouched, so pages and
//// preflights still work. Every other method must carry exactly one
//// `origin` header matching one of the origins, or it gets `403` before
//// the handler runs. Browsers send that header on cross-site writes.
////
//// Some proxies and privacy tools strip `origin`. When it is missing, a
//// single `sec-fetch-site: same-origin` header is accepted in its place.
//// Browsers set that header themselves and scripts cannot forge it. An
//// `origin` that is present always decides, and a request with neither
//// header fails closed.
////
//// The protection is header-based by design and uses no tokens. Every
//// current browser sends these headers, Go's standard library protects
//// against CSRF the same way with `http.CrossOriginProtection`, and OWASP's
//// verification standard (ASVS 4.0, 13.2.3) lists origin header checks
//// among the accepted protections.
////
//// Because this rejects requests with neither header, it will also reject
//// non-browser clients such as `curl` and native apps. Where those
//// authenticate with a bearer token rather than a cookie they cannot be
//// made to send one by a hostile page, so exempt them:
////
//// ```gleam
//// csrf.new(["https://example.com"])
//// |> csrf.exempt(fn(ctx) {
////   case request.get_header(ctx.request, "authorization") {
////     Ok("Bearer " <> _) -> True
////     _ -> False
////   }
//// })
//// ```
////
//// This is a complete defence on its own for browser clients. Keep
//// `SameSite=Lax` cookies as well, which `cookie.defaults` already sets:
//// the two fail in different ways. Applications must not perform writes on
//// `GET` routes, since those are not checked.
////
//// `howdy_auth` already applies the same check to its own routes and to
//// any route behind its guard, so an application using it for every write
//// does not need this middleware as well.

import gleam/http
import gleam/list
import gleam/string
import howdy/controller.{type Context, type Middleware, type Next}
import howdy/service

/// Which origins may write, and which requests skip the check. Build with
/// `new`, then turn it into middleware with `middleware`.
pub opaque type Policy {
  Policy(origins: List(String), exempt: fn(Context) -> Bool)
}

/// Allow writes from exactly these origins. Each must be of the form
/// `scheme://host` with an optional port and no trailing slash; anything
/// else panics as a configuration error. Comparison is case-insensitive.
///
/// The literal origin `null` cannot be allowed. Sandboxed frames and some
/// redirects send it, so trusting it would defeat the check.
pub fn new(origins: List(String)) -> Policy {
  let assert [_, ..] = origins as "csrf: no origins given"
  let origins =
    list.map(origins, fn(origin) {
      let assert True = valid_origin(origin)
        as { "csrf: invalid origin \"" <> origin <> "\"" }
      string.lowercase(origin)
    })
  Policy(origins:, exempt: fn(_) { False })
}

/// Skip the check for requests the function accepts, such as those
/// authenticated with a bearer token rather than a cookie. It runs on every
/// write. The default exempts nothing.
pub fn exempt(policy: Policy, allow: fn(Context) -> Bool) -> Policy {
  Policy(..policy, exempt: allow)
}

/// Turn a policy into middleware.
pub fn middleware(policy: Policy) -> Middleware {
  fn(ctx: Context, next: Next) {
    case ctx.request.method {
      http.Get | http.Head | http.Options -> next(ctx)
      _ ->
        case policy.exempt(ctx) || check(ctx, policy.origins) == Ok(Nil) {
          True -> next(ctx)
          False -> service.error_response(ctx, service.Forbidden)
        }
    }
  }
}

/// Whether a request passes the check against `origins`: exactly one
/// `origin` header matching one of them or, when there is no `origin` at
/// all, exactly one `sec-fetch-site: same-origin`. Use it in a guard, or for
/// a check of your own on one route. The method is not considered. Unlike
/// `new`, this does not reject a malformed origin, so it never matches one.
pub fn check(ctx: Context, origins: List(String)) -> service.Result(Nil) {
  let origins = list.map(origins, string.lowercase)
  let allowed = case headers(ctx, "origin"), headers(ctx, "sec-fetch-site") {
    [origin], _ -> list.contains(origins, origin)
    [], ["same-origin"] -> True
    _, _ -> False
  }
  case allowed {
    True -> Ok(Nil)
    False -> Error(service.Forbidden)
  }
}

/// Every value sent for a header, lowercased.
fn headers(ctx: Context, name: String) -> List(String) {
  list.filter_map(ctx.request.headers, fn(header) {
    case string.lowercase(header.0) == name {
      True -> Ok(string.lowercase(header.1))
      False -> Error(Nil)
    }
  })
}

fn valid_origin(origin: String) -> Bool {
  case string.split_once(origin, "://") {
    Ok(#(scheme, host)) ->
      scheme != ""
      && host != ""
      && !string.contains(host, "/")
      && !string.contains(host, "*")
      && !string.contains(host, " ")
    Error(Nil) -> False
  }
}
