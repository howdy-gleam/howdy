//// Facebook Login server flow. Facebook has no OpenID Connect: the code is
//// exchanged for an access token and identity comes from Graph `/me`. That
//// endpoint never asserts that the shared address is owned or verified, so
//// the identity is recorded as unauthoritative: a new account still needs an
//// email Howdy verified itself, or an explicit link from an existing account.
//// No Facebook tokens are stored or returned.

import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import howdy/auth/provider.{type Provider}
import howdy/auth/secret
import howdy/service

const issuer = "https://www.facebook.com"

const authorize_url = "https://www.facebook.com/v23.0/dialog/oauth"

const token_url = "https://graph.facebook.com/v23.0/oauth/access_token"

const profile_url = "https://graph.facebook.com/v23.0/me?fields=id,email"

pub fn new(
  client_id client_id: String,
  client_secret client_secret: String,
) -> Provider {
  with_transport(client_id, client_secret, send)
}

/// Internal network seam. Facebook signs nothing itself, so tests replace only
/// the transport; the account rules live in the shared provider runtime.
@internal
pub fn with_transport(
  client_id: String,
  client_secret: String,
  send: fn(Request(String)) -> service.Result(Response(String)),
) -> Provider {
  let client_secret = secret.wrap(client_secret)
  // Fixed URLs parse once here, at installation, so no sign-in can fail on
  // building a request from a constant.
  let assert Ok(token_request) = request.to(token_url)
  let assert Ok(profile_request) = request.to(profile_url)
  let valid = case
    string.trim(client_id) != "" && secret.reveal(client_secret) != ""
  {
    True -> Ok(Nil)
    False ->
      Error(service.Invalid("Facebook requires a client ID and client secret"))
  }
  provider.new(
    "facebook",
    "Facebook",
    valid,
    // Facebook supports neither PKCE nor a nonce bound into an ID token; the
    // single-use state cookie remains the browser-bound protection.
    fn(auth) {
      authorize_url
      <> "?"
      <> uri.query_to_string([
        #("client_id", client_id),
        #("redirect_uri", auth.redirect_uri),
        #("response_type", "code"),
        #("scope", "email"),
        #("state", auth.state),
      ])
    },
    fn(exchange) {
      use response <- result.try(
        post(send, token_request, [
          #("client_id", client_id),
          #("client_secret", secret.reveal(client_secret)),
          #("code", secret.reveal(exchange.code)),
          #("redirect_uri", exchange.redirect_uri),
        ]),
      )
      use access <- result.try(
        json.parse(
          response,
          decode.field("access_token", decode.string, decode.success),
        )
        |> result.replace_error(service.Unauthorized),
      )
      use access <- result.try(case access == "" {
        True -> Error(service.Unauthorized)
        False -> Ok(access)
      })
      use profile <- result.try(get(
        send,
        request.Request(
          ..profile_request,
          query: Some(
            "fields=id,email&access_token=" <> uri.percent_encode(access),
          ),
        ),
      ))
      use subject <- result.try(
        json.parse(profile, decode.field("id", decode.string, decode.success))
        |> result.replace_error(service.Unauthorized),
      )
      use stated <- result.try(
        json.parse(
          profile,
          decode.optional_field(
            "email",
            None,
            decode.optional(decode.string),
            decode.success,
          ),
        )
        |> result.replace_error(service.Unauthorized),
      )
      case subject != "" && string.byte_size(subject) <= 255 {
        // Unauthoritative: Facebook does not prove current ownership of a
        // mailbox, so registration through Facebook alone is refused and the
        // address must be verified by the email flow first, then linked.
        True ->
          Ok(provider.Identity(
            issuer,
            subject,
            option.unwrap(stated, ""),
            False,
            None,
          ))
        False -> Error(service.Unauthorized)
      }
    },
  )
}

fn get(
  send: fn(Request(String)) -> service.Result(Response(String)),
  req: Request(String),
) -> service.Result(String) {
  use response <- result.try(send(req))
  case response.status == 200 && string.byte_size(response.body) <= 1_048_576 {
    True -> Ok(response.body)
    False -> Error(service.Unauthorized)
  }
}

// Catch transport exceptions as well as ordinary errors: some OTP socket/TLS
// errors are not represented by gleam_httpc's error type. Never log requests.
@external(erlang, "howdy_auth_oidc_ffi", "protect")
fn protect(
  run: fn() -> service.Result(Response(String)),
  message: String,
) -> service.Result(Response(String))

fn send(req: Request(String)) -> service.Result(Response(String)) {
  protect(
    fn() {
      httpc.configure()
      |> httpc.timeout(10_000)
      |> httpc.dispatch(req)
      |> result.replace_error(service.Internal("Facebook request failed"))
    },
    "Facebook request failed",
  )
}

fn post(send, req: Request(String), fields) {
  let response =
    send(
      req
      |> request.set_method(http.Post)
      |> request.set_header("content-type", "application/x-www-form-urlencoded")
      |> request.set_body(uri.query_to_string(fields)),
    )
  case response {
    Ok(response) -> body(response)
    Error(_) -> Error(service.Unauthorized)
  }
}

fn body(response: Response(String)) -> service.Result(String) {
  case response.status == 200 && string.byte_size(response.body) <= 1_048_576 {
    True -> Ok(response.body)
    False -> Error(service.Unauthorized)
  }
}
