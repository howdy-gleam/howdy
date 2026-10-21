//// Microsoft Entra ID OpenID Connect server flow. Only identity scopes are
//// requested; Microsoft access and refresh tokens are never stored or
//// returned. Email claims barely exist on Microsoft accounts: many consumer
//// identities carry no mail claim at all, so a provider sign-in proves who
//// signed in, while a new local account still needs an email Howdy verified
//// itself, or an explicit link from an existing account.

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

const consumer_tenant = "9188040d-6c67-4c5b-b112-36a304b66dad"

const identity_tenants = ["common", "organizations", "consumers"]

pub fn new(
  client_id client_id: String,
  client_secret client_secret: String,
  tenant tenant: String,
) -> Provider {
  with_transport(client_id, client_secret, tenant, send)
}

/// Internal network seam: tests exercise the real signature and claims verifier.
@internal
pub fn with_transport(
  client_id: String,
  client_secret: String,
  tenant: String,
  send: fn(Request(String)) -> service.Result(Response(String)),
) -> Provider {
  let tenant = string.lowercase(tenant)
  let keys_cache = provider_keys.new()
  let client_secret = secret.wrap(client_secret)
  let valid = case
    string.trim(client_id) != ""
    && secret.reveal(client_secret) != ""
    && valid_tenant(tenant)
  {
    True -> Ok(Nil)
    False ->
      Error(service.Invalid(
        "Microsoft Entra requires a client ID, client secret and tenant",
      ))
  }
  let metadata_cache = provider_keys.new()
  // Every URL the flow needs is built from the tenant here, once, so a
  // tenant that does not form a URL fails installation, never a sign-in.
  let requests = {
    use keys <- result.try(
      request.to(authority(tenant, "/discovery/v2.0/keys")),
    )
    use token <- result.try(request.to(authority(tenant, "/oauth2/v2.0/token")))
    use metadata <- result.try(
      request.to(authority(tenant, "/v2.0/.well-known/openid-configuration")),
    )
    Ok(#(keys, token, metadata))
  }
  let valid = case valid, requests {
    Ok(Nil), Error(Nil) ->
      Error(service.Invalid("Microsoft Entra tenant does not form a URL"))
    _, _ -> valid
  }
  let #(keys_request, token_request, metadata_request) =
    result.unwrap(requests, #(request.new(), request.new(), request.new()))
  provider.new(
    "entra",
    "Microsoft",
    valid,
    fn(auth) {
      authority(tenant, "/oauth2/v2.0/authorize")
      <> "?"
      <> uri.query_to_string([
        #("client_id", client_id),
        #("redirect_uri", auth.redirect_uri),
        #("response_type", "code"),
        #("response_mode", "query"),
        #("scope", "openid email profile"),
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
        "Microsoft signing keys",
        False,
        fetch_keys,
      ))
      use payload <- result.try(case verify_signature(signed, keys) {
        Ok(payload) -> Ok(payload)
        Error(_) -> {
          // A new signing key may appear before the cached set expires.
          use keys <- result.try(provider_keys.get(
            keys_cache,
            "Microsoft signing keys",
            True,
            fetch_keys,
          ))
          verify_signature(signed, keys)
          |> result.replace_error(service.Unauthorized)
        }
      })
      use issuer <- result.try(expected_issuer(
        tenant,
        metadata_cache,
        metadata_request,
        send,
      ))
      claims(payload, client_id, tenant, issuer, exchange.nonce_digest)
    },
  )
}

fn authority(tenant: String, path: String) -> String {
  "https://login.microsoftonline.com/" <> tenant <> path
}

fn valid_tenant(tenant: String) -> Bool {
  case tenant {
    "" -> False
    "common" | "organizations" | "consumers" -> True
    _ -> {
      let characters = string.to_graphemes(string.lowercase(tenant))
      tenant == string.lowercase(tenant)
      && list.all(characters, fn(c) {
        string.contains("abcdefghijklmnopqrstuvwxyz0123456789-.", c)
      })
    }
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
      |> result.replace_error(service.Internal("Microsoft request failed"))
    },
    "Microsoft request failed",
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

@external(erlang, "howdy_auth_oidc_ffi", "verify_entra")
fn verify_signature(signed: String, keys: String) -> Result(String, Nil)

fn claims(
  payload: String,
  client_id: String,
  tenant: String,
  issuer: String,
  nonce_digest: String,
) -> service.Result(provider.Identity) {
  let decoder = {
    use iss <- decode.field("iss", decode.string)
    use sub <- decode.field("sub", decode.string)
    use aud <- decode.field("aud", decode.string)
    use exp <- decode.field("exp", decode.int)
    use iat <- decode.field("iat", decode.int)
    use tid <- decode.field("tid", decode.string)
    use nonce <- decode.field("nonce", decode.string)
    use email <- decode.optional_field(
      "email",
      None,
      decode.optional(decode.string),
    )
    use username <- decode.optional_field(
      "preferred_username",
      None,
      decode.optional(decode.string),
    )
    use nbf <- decode.optional_field("nbf", 0, decode.int)
    decode.success(#(iss, sub, aud, exp, iat, tid, nonce, email, username, nbf))
  }
  use #(iss, sub, aud, exp, iat, tid, nonce, email, username, nbf) <- result.try(
    json.parse(payload, decoder) |> result.replace_error(service.Unauthorized),
  )
  let now = token.now()
  case
    issuer_rule(iss, tid, tenant, issuer)
    && sub != ""
    && string.byte_size(sub) <= 255
    && aud == client_id
    && exp > now
    && iat <= now + 60
    && iat < exp
    && nbf <= now
    && token.constant_time_equal(token.digest(nonce), nonce_digest)
  {
    True ->
      Ok(provider.Identity(
        iss,
        sub,
        case email {
          Some(e) -> e
          None -> option.unwrap(username, "")
        },
        // Entra email and preferred_username claims are mutable hints,
        // not proof of mailbox ownership for local account linking.
        False,
        None,
      ))
    False -> Error(service.Unauthorized)
  }
}

fn issuer_rule(
  iss: String,
  tid: String,
  tenant: String,
  issuer: String,
) -> Bool {
  valid_tenant_id(tid)
  && iss == "https://login.microsoftonline.com/" <> tid <> "/v2.0"
  && case tenant {
    "common" -> True
    "organizations" -> tid != consumer_tenant
    "consumers" -> tid == consumer_tenant
    _ -> iss == issuer
  }
}

fn valid_tenant_id(tenant: String) -> Bool {
  case string.split(tenant, "-") {
    [a, b, c, d, e] ->
      string.byte_size(a) == 8
      && string.byte_size(b) == 4
      && string.byte_size(c) == 4
      && string.byte_size(d) == 4
      && string.byte_size(e) == 12
      && list.all(string.to_graphemes(a <> b <> c <> d <> e), fn(c) {
        string.contains("0123456789abcdef", c)
      })
    _ -> False
  }
}

// Domain tenant selectors resolve to a GUID issuer in Microsoft's metadata.
// Fetch only from the configured Microsoft authority, never a token-supplied URL.
fn expected_issuer(tenant, cache, req: Request(String), send) {
  case list.contains(identity_tenants, tenant) || valid_tenant_id(tenant) {
    True -> Ok(authority(tenant, "/v2.0"))
    False -> {
      use metadata <- result.try(
        provider_keys.get(cache, "Microsoft issuer metadata", False, fn() {
          send(req)
        }),
      )
      json.parse(
        metadata,
        decode.field("issuer", decode.string, decode.success),
      )
      |> result.replace_error(service.Unauthorized)
    }
  }
}
