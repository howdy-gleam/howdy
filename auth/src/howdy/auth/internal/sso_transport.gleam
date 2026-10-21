//// Outbound requests to a customer's identity provider. Unlike the built-in
//// providers, the URL is configuration a customer supplied, so it is treated
//// as hostile: HTTPS only, public addresses only, no redirects followed, and
//// the connection goes to the address that was vetted, never to a second
//// resolution of the name.

import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/option.{type Option, None}
import gleam/result
import gleam/string
import howdy/service

pub type Send =
  fn(Request(String)) -> service.Result(Response(String))

/// Resolves and vets the host once, then connects to that address with the
/// original name as the Host header and TLS server name.
@external(erlang, "howdy_auth_sso_ffi", "dispatch")
fn dispatch(
  method: Method,
  host: String,
  path: String,
  query: Option(String),
  headers: List(#(String, String)),
  body: String,
  timeout_ms: Int,
) -> Result(#(Int, List(#(String, String)), String), Nil)

/// An `httpc` method atom.
type Method

@external(erlang, "erlang", "binary_to_existing_atom")
fn method(name: String) -> Method

// Catch transport exceptions as well as ordinary errors: some OTP socket/TLS
// errors are not represented by a result. Never log requests.
@external(erlang, "howdy_auth_oidc_ffi", "protect")
fn protect(
  run: fn() -> service.Result(Response(String)),
  message: String,
) -> service.Result(Response(String))

pub fn send(req: Request(String)) -> service.Result(Response(String)) {
  let failed = "SSO provider request failed"
  case req.scheme == http.Https && req.port == None {
    False -> Error(service.Internal(failed))
    True ->
      protect(
        fn() {
          dispatch(
            method(string.lowercase(http.method_to_string(req.method))),
            req.host,
            req.path,
            req.query,
            req.headers,
            req.body,
            10_000,
          )
          |> result.map(fn(answer) {
            response.Response(answer.0, answer.1, answer.2)
          })
          |> result.replace_error(service.Internal(failed))
        },
        failed,
      )
  }
}
