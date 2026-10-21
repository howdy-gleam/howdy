//// OpenID Connect relying party, shared by SSO connections and the generic
//// `providers/oidc`. Everything is discovered at the configured issuer and
//// nowhere else: never from a token, and never from a redirect. Only
//// identity scopes are requested; provider tokens are never stored.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import howdy/auth/internal/address
import howdy/auth/internal/provider_keys
import howdy/auth/internal/token
import howdy/auth/provider
import howdy/auth/secret
import howdy/service

/// Discovery documents rarely carry cache headers.
const metadata_seconds = 300

pub type Client {
  Client(
    issuer: String,
    client_id: String,
    client_secret: secret.Secret,
    send: fn(Request(String)) -> service.Result(Response(String)),
    cache: provider_keys.Cache,
  )
}

pub opaque type Metadata {
  Metadata(authorize: String, token: String, keys: String, basic: Bool)
}

/// What a verified ID token says about its subject. `email` is normalized,
/// or empty when absent or unusable.
pub type Claims {
  Claims(subject: String, email: String, email_verified: Option(Bool))
}

fn fetch(
  client: Client,
  url: String,
  refresh: Bool,
  floor: Int,
) -> service.Result(String) {
  use req <- result.try(
    request.to(url) |> result.replace_error(service.Unauthorized),
  )
  provider_keys.get_keyed(client.cache, url, refresh, floor, fn() {
    client.send(req)
  })
}

/// The document must name the issuer it was fetched from, and every endpoint
/// must itself be HTTPS and form a request. Endpoints may live on other
/// hosts, as Google's do.
pub fn discover(client: Client) -> service.Result(Metadata) {
  use body <- result.try(fetch(
    client,
    client.issuer <> "/.well-known/openid-configuration",
    False,
    metadata_seconds,
  ))
  let decoder = {
    use found <- decode.field("issuer", decode.string)
    use authorize <- decode.field("authorization_endpoint", decode.string)
    use token <- decode.field("token_endpoint", decode.string)
    use keys <- decode.field("jwks_uri", decode.string)
    use methods <- decode.optional_field(
      "token_endpoint_auth_methods_supported",
      // The specification's default when the field is absent.
      ["client_secret_basic"],
      decode.list(decode.string),
    )
    decode.success(#(found, authorize, token, keys, methods))
  }
  case json.parse(body, decoder) {
    Ok(#(found, authorize, token, keys, methods)) ->
      case
        found == client.issuer
        && list.all([authorize, token, keys], https)
        && list.all([token, keys], requestable)
      {
        True ->
          Ok(Metadata(
            authorize,
            token,
            keys,
            !list.contains(methods, "client_secret_post"),
          ))
        False -> Error(service.Unauthorized)
      }
    Error(_) -> Error(service.Unauthorized)
  }
}

fn requestable(url: String) -> Bool {
  result.is_ok(request.to(url))
}

pub fn https(url: String) -> Bool {
  case uri.parse(url) {
    Ok(uri.Uri(
      scheme: Some("https"),
      userinfo: None,
      host: Some(host),
      fragment: None,
      ..,
    )) -> host != "" && string.byte_size(url) <= 2048
    _ -> False
  }
}

pub fn authorization_url(
  client: Client,
  metadata: Metadata,
  auth: provider.Authorization,
) -> String {
  metadata.authorize
  <> case string.contains(metadata.authorize, "?") {
    True -> "&"
    False -> "?"
  }
  <> uri.query_to_string([
    #("client_id", client.client_id),
    #("redirect_uri", auth.redirect_uri),
    #("response_type", "code"),
    #("scope", "openid email profile"),
    #("state", auth.state),
    #("nonce", auth.nonce),
    #("code_challenge", auth.challenge),
    #("code_challenge_method", "S256"),
  ])
}

/// Redeem the code and verify the ID token it returns: signature against the
/// issuer's own keys, then issuer, audience, lifetime and nonce.
pub fn exchange(
  client: Client,
  metadata: Metadata,
  exchange: provider.Exchange,
) -> service.Result(Claims) {
  use req <- result.try(
    request.to(metadata.token) |> result.replace_error(service.Unauthorized),
  )
  let fields = [
    #("grant_type", "authorization_code"),
    #("code", secret.reveal(exchange.code)),
    #("redirect_uri", exchange.redirect_uri),
    #("code_verifier", secret.reveal(exchange.verifier)),
  ]
  let #(req, fields) = case metadata.basic {
    True -> #(
      request.set_header(
        req,
        "authorization",
        "Basic "
          <> bit_array.base64_encode(
          <<
            uri.percent_encode(client.client_id):utf8,
            ":",
            uri.percent_encode(secret.reveal(client.client_secret)):utf8,
          >>,
          True,
        ),
      ),
      fields,
    )
    False -> #(req, [
      #("client_id", client.client_id),
      #("client_secret", secret.reveal(client.client_secret)),
      ..fields
    ])
  }
  use res <- result.try(client.send(
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/x-www-form-urlencoded")
    |> request.set_header("accept", "application/json")
    |> request.set_body(uri.query_to_string(fields)),
  ))
  use body <- result.try(
    case res.status == 200 && string.byte_size(res.body) <= 1_048_576 {
      True -> Ok(res.body)
      False -> Error(service.Unauthorized)
    },
  )
  use signed <- result.try(
    json.parse(body, decode.field("id_token", decode.string, decode.success))
    |> result.replace_error(service.Unauthorized),
  )
  use keys <- result.try(fetch(client, metadata.keys, False, 0))
  use payload <- result.try(case verify_signature(signed, keys) {
    Ok(payload) -> Ok(payload)
    Error(_) -> {
      // A new signing key may appear before the cached set expires.
      use keys <- result.try(fetch(client, metadata.keys, True, 0))
      verify_signature(signed, keys)
      |> result.replace_error(service.Unauthorized)
    }
  })
  claims(payload, client, exchange.nonce_digest)
}

@external(erlang, "howdy_auth_oidc_ffi", "verify")
fn verify_signature(signed: String, keys: String) -> Result(String, Nil)

fn claims(
  payload: String,
  client: Client,
  nonce_digest: String,
) -> service.Result(Claims) {
  let decoder = {
    use iss <- decode.field("iss", decode.string)
    use sub <- decode.field("sub", decode.string)
    use aud <- decode.field(
      "aud",
      decode.one_of(decode.string |> decode.map(fn(a) { [a] }), [
        decode.list(decode.string),
      ]),
    )
    use azp <- decode.optional_field(
      "azp",
      None,
      decode.optional(decode.string),
    )
    use exp <- decode.field("exp", decode.int)
    use iat <- decode.field("iat", decode.int)
    use nbf <- decode.optional_field("nbf", 0, decode.int)
    use nonce <- decode.field("nonce", decode.string)
    use email <- decode.optional_field(
      "email",
      None,
      decode.optional(decode.string),
    )
    use verified <- decode.optional_field(
      "email_verified",
      None,
      decode.optional(decode.bool),
    )
    decode.success(#(
      #(iss, sub, aud, azp),
      #(exp, iat, nbf, nonce),
      #(email, verified),
    ))
  }
  use #(#(iss, sub, aud, azp), #(exp, iat, nbf, nonce), #(email, verified)) <- result.try(
    json.parse(payload, decoder) |> result.replace_error(service.Unauthorized),
  )
  let now = token.now()
  case
    iss == client.issuer
    && sub != ""
    && string.byte_size(sub) <= 255
    && audience(aud, azp, client.client_id)
    && exp > now
    && iat <= now + 60
    && iat < exp
    && nbf <= now + 60
    && token.constant_time_equal(token.digest(nonce), nonce_digest)
  {
    True -> {
      let email =
        option.to_result(email, Nil)
        |> result.try(fn(e) {
          address.normalize_email(e) |> result.replace_error(Nil)
        })
        |> result.unwrap("")
      Ok(Claims(sub, email, verified))
    }
    False -> Error(service.Unauthorized)
  }
}

/// Sole audience, or one of several with this client as the authorized party.
fn audience(aud: List(String), azp: Option(String), client_id: String) -> Bool {
  case aud, azp {
    [only], None -> only == client_id
    [only], Some(party) -> only == client_id && party == client_id
    many, Some(party) -> list.contains(many, client_id) && party == client_id
    _, None -> False
  }
}
