//// Sign in with Apple, web flow. Only the email scope is requested; Apple
//// access and refresh tokens are never stored or returned.
////
//// Apple differs from the other providers in two ways. The client proves
//// itself with a short-lived ES256 JWT signed by the developer's key, made
//// afresh for each exchange, instead of a shared secret. And any scope makes
//// Apple answer with a cross-site POST (`response_mode=form_post`), which the
//// provider routes turn into the ordinary callback GET.

import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam/uri
import howdy/auth/internal/provider_keys
import howdy/auth/internal/token
import howdy/auth/provider.{type Provider}
import howdy/auth/secret
import howdy/service

const issuer = "https://appleid.apple.com"

const authorize_url = "https://appleid.apple.com/auth/authorize"

const token_url = "https://appleid.apple.com/auth/token"

const keys_url = "https://appleid.apple.com/auth/keys"

/// Long enough for clock skew and one token request, and no longer.
const client_secret_seconds = 300

/// `client_id` is the Services ID (not the app's bundle ID), `team_id` the
/// ten-character Apple developer team, `key_id` the identifier of a key with
/// Sign in with Apple enabled, and `private_key` the contents of its `.p8`
/// download: a PEM-encoded P-256 key. Keep the key wherever other secrets live.
pub fn new(
  client_id client_id: String,
  team_id team_id: String,
  key_id key_id: String,
  private_key private_key: String,
) -> Provider {
  with_transport(client_id, team_id, key_id, private_key, send)
}

@external(erlang, "howdy_auth_apple_ffi", "client_secret")
fn sign_client_secret(
  pem: String,
  key_id: String,
  team_id: String,
  client_id: String,
  now: Int,
  lifetime: Int,
) -> Result(String, Nil)

/// Internal network seam: tests exercise the real signature and claims verifier.
@internal
pub fn with_transport(
  client_id: String,
  team_id: String,
  key_id: String,
  private_key: String,
  send: fn(Request(String)) -> service.Result(Response(String)),
) -> Provider {
  let keys_cache = provider_keys.new()
  let private_key = secret.wrap(private_key)
  // Fixed URLs parse once here, at installation, so no sign-in can fail on
  // building a request from a constant.
  let assert Ok(token_request) = request.to(token_url)
  let assert Ok(keys_request) = request.to(keys_url)
  let client_secret = fn() {
    sign_client_secret(
      secret.reveal(private_key),
      key_id,
      team_id,
      client_id,
      token.now(),
      client_secret_seconds,
    )
  }
  let named =
    list.all([client_id, team_id, key_id], fn(value) {
      string.trim(value) != ""
    })
  // Signing once at startup proves the key is a usable P-256 key.
  let valid = case named, client_secret() {
    True, Ok(_) -> Ok(Nil)
    False, _ ->
      Error(service.Invalid("Apple requires a Services ID, team ID and key ID"))
    True, Error(Nil) ->
      Error(service.Invalid(
        "Apple private key must be the PEM-encoded P-256 key from its .p8 file",
      ))
  }
  provider.new(
    "apple",
    "Apple",
    valid,
    fn(auth) {
      // Apple documents no PKCE support, so none is sent: state, the nonce and
      // the browser binding tie the answer to this attempt.
      authorize_url
      <> "?"
      <> uri.query_to_string([
        #("client_id", client_id),
        #("redirect_uri", auth.redirect_uri),
        #("response_type", "code"),
        #("response_mode", "form_post"),
        #("scope", "email"),
        #("state", auth.state),
        #("nonce", auth.nonce),
      ])
    },
    fn(exchange) {
      use client_secret <- result.try(
        client_secret()
        |> result.replace_error(service.Internal("Apple client secret failed")),
      )
      use response <- result.try(
        post(send, token_request, [
          #("grant_type", "authorization_code"),
          #("code", secret.reveal(exchange.code)),
          #("client_id", client_id),
          #("client_secret", client_secret),
          #("redirect_uri", exchange.redirect_uri),
        ]),
      )
      use signed <- result.try(
        json.parse(
          response,
          decode.field("id_token", decode.string, decode.success),
        )
        |> result.replace_error(service.Unauthorized),
      )
      let fetch_keys = fn() { send(keys_request) }
      use keys <- result.try(provider_keys.get(
        keys_cache,
        "Apple signing keys",
        False,
        fetch_keys,
      ))
      use payload <- result.try(case verify_signature(signed, keys) {
        Ok(payload) -> Ok(payload)
        Error(_) -> {
          // A new signing key may appear before the cached set expires.
          use keys <- result.try(provider_keys.get(
            keys_cache,
            "Apple signing keys",
            True,
            fetch_keys,
          ))
          verify_signature(signed, keys)
          |> result.replace_error(service.Unauthorized)
        }
      })
      claims(payload, client_id, exchange.nonce_digest)
    },
  )
}

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
      |> result.replace_error(service.Internal("Apple request failed"))
    },
    "Apple request failed",
  )
}

fn post(
  send: fn(Request(String)) -> service.Result(Response(String)),
  req: Request(String),
  fields: List(#(String, String)),
) -> service.Result(String) {
  use res <- result.try(send(
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/x-www-form-urlencoded")
    |> request.set_body(uri.query_to_string(fields)),
  ))
  case res.status == 200 && string.byte_size(res.body) <= 1_048_576 {
    True -> Ok(res.body)
    False -> Error(service.Unauthorized)
  }
}

@external(erlang, "howdy_auth_oidc_ffi", "verify")
fn verify_signature(signed: String, keys: String) -> Result(String, Nil)

fn claims(
  payload: String,
  client_id: String,
  nonce_digest: String,
) -> service.Result(provider.Identity) {
  let audience =
    decode.one_of(decode.string |> decode.map(fn(a) { [a] }), [
      decode.list(decode.string),
    ])
  // Apple has sent these booleans as JSON strings.
  let flag =
    decode.one_of(decode.bool, [
      decode.string |> decode.map(fn(text) { text == "true" }),
    ])
  let decoder = {
    use iss <- decode.field("iss", decode.string)
    use sub <- decode.field("sub", decode.string)
    use aud <- decode.field("aud", audience)
    use exp <- decode.field("exp", decode.int)
    use iat <- decode.field("iat", decode.int)
    use nonce <- decode.field("nonce", decode.string)
    // Absent when the user has withheld it from this Services ID before.
    use email <- decode.optional_field("email", "", decode.string)
    use verified <- decode.optional_field("email_verified", False, flag)
    decode.success(#(iss, sub, aud, exp, iat, nonce, email, verified))
  }
  use data <- result.try(
    json.parse(payload, decoder) |> result.replace_error(service.Unauthorized),
  )
  let #(iss, sub, aud, exp, iat, nonce, email, verified) = data
  let now = token.now()
  case
    iss == issuer
    && sub != ""
    && string.byte_size(sub) <= 255
    && aud == [client_id]
    && exp > now
    && iat <= now + 60
    && iat < exp
    && token.constant_time_equal(token.digest(nonce), nonce_digest)
  {
    // Apple verifies every address it releases, its private relay included.
    // Without one the identity can still sign in to an account it is linked to.
    True ->
      Ok(provider.Identity(
        issuer,
        sub,
        email,
        email != "" && verified,
        option.None,
      ))
    False -> Error(service.Unauthorized)
  }
}
