//// Google OpenID Connect server flow. Only identity scopes are requested;
//// Google access and refresh tokens are never stored or returned.

import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import howdy/auth/internal/provider_keys
import howdy/auth/internal/token
import howdy/auth/provider.{type Provider}
import howdy/auth/secret
import howdy/service

const issuer = "https://accounts.google.com"

const authorize_url = "https://accounts.google.com/o/oauth2/v2/auth"

const token_url = "https://oauth2.googleapis.com/token"

const keys_url = "https://www.googleapis.com/oauth2/v3/certs"

pub fn new(
  client_id client_id: String,
  client_secret client_secret: String,
) -> Provider {
  with_transport(client_id, client_secret, send)
}

/// Enforce the verified `hd` claim, as well as hinting to Google's chooser.
pub fn require_hosted_domain(provider: Provider, domain: String) -> Provider {
  provider.require_domain(provider, domain)
}

/// Internal network seam: tests exercise the real signature and claims verifier.
@internal
pub fn with_transport(
  client_id: String,
  client_secret: String,
  send: fn(Request(String)) -> service.Result(Response(String)),
) -> Provider {
  let keys_cache = provider_keys.new()
  let client_secret = secret.wrap(client_secret)
  // Fixed URLs parse once here, at installation, so no sign-in can fail on
  // building a request from a constant.
  let assert Ok(token_request) = request.to(token_url)
  let assert Ok(keys_request) = request.to(keys_url)
  let valid = case
    string.trim(client_id) != "" && secret.reveal(client_secret) != ""
  {
    True -> Ok(Nil)
    False ->
      Error(service.Invalid("Google requires a client ID and client secret"))
  }
  provider.new(
    "google",
    "Google",
    valid,
    fn(auth) {
      authorize_url
      <> "?"
      <> uri.query_to_string([
        #("client_id", client_id),
        #("redirect_uri", auth.redirect_uri),
        #("response_type", "code"),
        #("scope", "openid email"),
        #("state", auth.state),
        #("nonce", auth.nonce),
        #("code_challenge", auth.challenge),
        #("code_challenge_method", "S256"),
      ])
    },
    fn(exchange) {
      use response <- result.try(
        post(send, token_request, [
          #("grant_type", "authorization_code"),
          #("code", secret.reveal(exchange.code)),
          #("client_id", client_id),
          #("client_secret", secret.reveal(client_secret)),
          #("redirect_uri", exchange.redirect_uri),
          #("code_verifier", secret.reveal(exchange.verifier)),
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
        "Google signing keys",
        False,
        fetch_keys,
      ))
      use payload <- result.try(case verify_signature(signed, keys) {
        Ok(payload) -> Ok(payload)
        Error(_) -> {
          // A new signing key may appear before the cached set expires.
          use keys <- result.try(provider_keys.get(
            keys_cache,
            "Google signing keys",
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
      |> result.replace_error(service.Internal("Google request failed"))
    },
    "Google request failed",
  )
}

fn post(send, req: Request(String), fields) {
  use res <- result.try(send(
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/x-www-form-urlencoded")
    |> request.set_body(uri.query_to_string(fields)),
  ))
  success_body(res)
}

fn success_body(res: Response(String)) -> service.Result(String) {
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
  let decoder = {
    use iss <- decode.field("iss", decode.string)
    use sub <- decode.field("sub", decode.string)
    use aud <- decode.field("aud", audience)
    use azp <- decode.optional_field(
      "azp",
      None,
      decode.optional(decode.string),
    )
    use exp <- decode.field("exp", decode.int)
    use iat <- decode.field("iat", decode.int)
    use nonce <- decode.field("nonce", decode.string)
    use email <- decode.field("email", decode.string)
    use verified <- decode.field("email_verified", decode.bool)
    use hd <- decode.optional_field("hd", None, decode.optional(decode.string))
    use nbf <- decode.optional_field("nbf", 0, decode.int)
    decode.success(#(
      iss,
      sub,
      aud,
      azp,
      exp,
      iat,
      nonce,
      email,
      verified,
      hd,
      nbf,
    ))
  }
  use data <- result.try(
    json.parse(payload, decoder) |> result.replace_error(service.Unauthorized),
  )
  let #(iss, sub, aud, azp, exp, iat, nonce, email, verified, hd, nbf) = data
  let now = token.now()
  let presenter_ok = case azp, aud {
    Some(presenter), _ -> presenter == client_id
    None, [_] -> True
    _, _ -> False
  }
  case
    { iss == issuer || iss == "accounts.google.com" }
    && sub != ""
    && string.byte_size(sub) <= 255
    && list.contains(aud, client_id)
    && presenter_ok
    && exp > now
    && iat <= now + 60
    && iat < exp
    && nbf <= now
    && token.constant_time_equal(token.digest(nonce), nonce_digest)
    && verified
  {
    True ->
      Ok(provider.Identity(
        issuer,
        sub,
        email,
        string.ends_with(email, "@gmail.com")
          || case hd {
          Some(domain) -> domain != ""
          None -> False
        },
        hd,
      ))
    False -> Error(service.Unauthorized)
  }
}
