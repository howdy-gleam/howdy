//// A single JWKS response per provider runtime, never a cache of identities.
////
//// Fetching is single-flight per key and never under a lock: the first
//// caller to need a body fetches it in its own process, later callers serve
//// the previous body while it is being refreshed or, when there is none,
//// wait for the fetcher's result. See `howdy_auth_oidc_ffi:keys_get/5`.

import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import howdy/auth/internal/token
import howdy/service

pub type Cache

@external(erlang, "howdy_auth_oidc_ffi", "keys_new")
pub fn new() -> Cache

@external(erlang, "howdy_auth_oidc_ffi", "keys_get")
fn single_flight(
  cache: Cache,
  key: String,
  refresh: Bool,
  fetch: fn() -> service.Result(#(String, Int)),
  failed: service.Error,
) -> service.Result(String)

/// Every fetched key for a provider comes from one URL, so a fixed key that
/// no URL can equal.
const only_key = "keys"

/// `what` names the document for the error a failed fetch reports, such as
/// "Google signing keys" or "Microsoft issuer metadata".
pub fn get(
  cache: Cache,
  what: String,
  refresh: Bool,
  fetch: fn() -> service.Result(Response(String)),
) -> service.Result(String) {
  let failed = service.Internal(what <> " unavailable")
  use <- single_flight(cache, only_key, refresh, _, failed)
  use res <- result.try(fetch())
  case res.status == 200 && string.byte_size(res.body) <= 1_048_576 {
    True -> Ok(#(res.body, token.now() + lifetime(res)))
    False -> Error(failed)
  }
}

/// As `get`, for a cache shared by many SSO connections. `key` is the URL
/// fetched, and fetches are single-flight per URL: one customer's slow
/// provider must not stall another's sign-ins. Enterprise discovery documents
/// rarely carry cache headers, so a body is kept for at least `floor` seconds.
pub fn get_keyed(
  cache: Cache,
  key: String,
  refresh: Bool,
  floor: Int,
  fetch: fn() -> service.Result(Response(String)),
) -> service.Result(String) {
  use <- single_flight(cache, key, refresh, _, service.Unauthorized)
  use res <- result.try(fetch())
  case res.status == 200 && string.byte_size(res.body) <= 1_048_576 {
    True -> Ok(#(res.body, token.now() + int.max(floor, lifetime(res))))
    False -> Error(service.Unauthorized)
  }
}

fn lifetime(res: Response(String)) -> Int {
  let directives =
    response.get_header(res, "cache-control")
    |> result.unwrap("")
    |> string.lowercase
    |> string.split(",")
    |> list.map(string.trim)
  case
    list.contains(directives, "no-store")
    || list.contains(directives, "no-cache")
  {
    True -> 0
    False -> {
      let seconds =
        list.find_map(directives, fn(value) {
          case value {
            "max-age=" <> n -> int.parse(n)
            _ -> Error(Nil)
          }
        })
        |> result.unwrap(0)
      let age =
        response.get_header(res, "age")
        |> result.try(int.parse)
        |> result.unwrap(0)
      int.max(0, int.min(seconds - int.max(age, 0), 3600))
    }
  }
}
