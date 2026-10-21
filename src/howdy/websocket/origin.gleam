//// Internal browser-origin validation shared by every socket upgrade.
////
//// The same-origin policy compares the browser's `origin` with the origin
//// it reached the app at. Behind a proxy that ends TLS, the app sees plain
//// HTTP, so the scheme comes from `x-forwarded-proto` and, for proxies that
//// rewrite `host`, the authority from `x-forwarded-host`. Trusting them is
//// safe here, unlike for a client's address: a hostile page cannot set
//// either header on a browser's socket handshake, and a client outside a
//// browser can send any `origin` it likes anyway.

import gleam/http
import gleam/http/request.{type Request}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri

pub opaque type Origin {
  Origin(scheme: String, host: String, port: Int)
}

pub type Policy {
  SameOrigin
  Allowlist(List(Origin))
}

pub fn allowlist(values: List(String)) -> Policy {
  Allowlist(
    list.map(values, fn(value) {
      let assert Ok(origin) = parse(value)
        as "howdy/websocket: expected an HTTP(S) origin without path, credentials or wildcard"
      origin
    }),
  )
}

pub fn allowed(req: Request(body), policy: Policy, required: Bool) -> Bool {
  let origins = list.filter(req.headers, fn(header) { header.0 == "origin" })
  case origins {
    [] -> !required
    [#(_, value)] ->
      case parse(value) {
        Error(Nil) -> False
        Ok(origin) ->
          case policy {
            Allowlist(origins) -> list.contains(origins, origin)
            SameOrigin -> served_at(req) == Ok(origin)
          }
      }
    _ -> False
  }
}

/// The origin the browser reached the app at: the request's own, with the
/// scheme and authority a proxy forwarded in place of what it sent on.
fn served_at(req: Request(body)) -> Result(Origin, Nil) {
  // Traefik names a socket's scheme, as the browser did: `wss` for one
  // opened from an HTTPS page.
  let scheme = case forwarded(req, "x-forwarded-proto") {
    Ok("https") | Ok("wss") -> "https"
    Ok("http") | Ok("ws") -> "http"
    _ -> http.scheme_to_string(req.scheme)
  }
  case forwarded(req, "x-forwarded-host") {
    Ok(authority) -> parse(scheme <> "://" <> authority)
    Error(Nil) ->
      Ok(Origin(
        scheme,
        normalize_host(req.host),
        effective_port(scheme, req.port),
      ))
  }
}

/// The value the outermost proxy gave a forwarded header, lowercased: the
/// first of a list that later proxies appended to.
fn forwarded(req: Request(body), name: String) -> Result(String, Nil) {
  use #(_, value) <- result.try(
    list.find(req.headers, fn(header) { header.0 == name }),
  )
  let assert [first, ..] = string.split(value, ",")
  case string.trim(first) |> string.lowercase {
    "" -> Error(Nil)
    first -> Ok(first)
  }
}

fn parse(value: String) -> Result(Origin, Nil) {
  case uri.parse(value) {
    Ok(uri.Uri(
      scheme: Some(scheme),
      host: Some(host),
      userinfo: None,
      path: "",
      query: None,
      fragment: None,
      port:,
    )) -> {
      let scheme = string.lowercase(scheme)
      let port = effective_port(scheme, port)
      case
        { scheme == "http" || scheme == "https" }
        && host != ""
        && port >= 1
        && port <= 65_535
        && list.all(string.to_graphemes(host), fn(char) {
          string.contains(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:[]",
            char,
          )
        })
      {
        True -> Ok(Origin(scheme, normalize_host(host), port))
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn effective_port(scheme: String, port: option.Option(Int)) -> Int {
  case port, scheme {
    Some(port), _ -> port
    None, "https" -> 443
    None, _ -> 80
  }
}

// uri.parse removes IPv6 brackets; HTTP request authorities retain them.
fn normalize_host(host: String) -> String {
  let host = string.lowercase(host)
  case host {
    "[" <> rest ->
      case string.ends_with(rest, "]") {
        True -> string.drop_end(rest, 1)
        False -> host
      }
    _ -> host
  }
}
