//// Any OpenID Connect provider: Okta, Auth0, Keycloak, GitLab, Zitadel and
//// the rest. Endpoints and signing keys are discovered at `issuer`, and ID
//// tokens are checked exactly as for enterprise SSO connections: signature
//// against the issuer's own keys, then issuer, audience, lifetime and nonce.
//// Only identity scopes are requested; provider tokens are never stored.
////
//// ```gleam
//// let assert Ok(identity) =
////   auth.with_provider(identity, oidc.new(
////     id: "gitlab",
////     name: "GitLab",
////     issuer: "https://gitlab.com",
////     client_id: gitlab_client_id,
////     client_secret: gitlab_client_secret,
////     authoritative_for: [],
////   ))
//// ```
////
//// Discovery happens when the first sign-in begins, and is cached for five
//// minutes, so an unreachable provider fails that sign-in rather than startup.

import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import howdy/auth/internal/oidc
import howdy/auth/internal/provider_keys
import howdy/auth/provider.{type Provider}
import howdy/auth/secret
import howdy/service

/// `issuer` is the exact `iss` the provider puts in its tokens, with no
/// trailing slash unless it has one there too; discovery must return it.
///
/// `authoritative_for` lists the email domains this provider is the
/// authority for, such as a company's own domain on its own Keycloak. A
/// verified address in one of them may create a new account; any other
/// address must register by email first and then link, because a provider
/// verifying an address once does not make it that address's owner. Pass
/// `[]` for a public provider where anyone can sign up.
pub fn new(
  id id: String,
  name name: String,
  issuer issuer: String,
  client_id client_id: String,
  client_secret client_secret: String,
  authoritative_for domains: List(String),
) -> Provider {
  with_transport(id, name, issuer, client_id, client_secret, domains, send)
}

/// Internal network seam: tests play the provider over the real verifiers.
@internal
pub fn with_transport(
  id: String,
  name: String,
  issuer: String,
  client_id: String,
  client_secret: String,
  domains: List(String),
  send: fn(Request(String)) -> service.Result(Response(String)),
) -> Provider {
  let domains = list.map(domains, string.lowercase)
  let valid = case
    provider.valid_id(id),
    string.trim(name) != "" && string.byte_size(name) <= 100,
    provider.https(issuer)
    && result.is_ok(request.to(issuer <> "/.well-known/openid-configuration")),
    string.trim(client_id) != "" && client_secret != "",
    list.all(domains, domain)
  {
    False, _, _, _, _ ->
      Error(service.Invalid(
        "provider id must be 1 to 32 lowercase letters, digits or hyphens",
      ))
    _, False, _, _, _ ->
      Error(service.Invalid("provider name must contain 1 to 100 bytes"))
    _, _, False, _, _ ->
      Error(service.Invalid("OpenID Connect issuer must be an HTTPS URL"))
    _, _, _, False, _ ->
      Error(service.Invalid(
        "OpenID Connect requires a client ID and client secret",
      ))
    _, _, _, _, False ->
      Error(service.Invalid("authoritative domains must be domain names"))
    True, True, True, True, True -> Ok(Nil)
  }
  let client =
    oidc.Client(
      issuer:,
      client_id:,
      client_secret: secret.wrap(client_secret),
      send:,
      cache: provider_keys.new(),
    )
  provider.discovered(
    id,
    string.trim(name),
    valid,
    issuer,
    fn(request) {
      use metadata <- result.try(oidc.discover(client))
      Ok(oidc.authorization_url(client, metadata, request))
    },
    fn(exchange) {
      use metadata <- result.try(oidc.discover(client))
      use claims <- result.try(oidc.exchange(client, metadata, exchange))
      let authoritative =
        claims.email_verified == Some(True)
        && case string.split(claims.email, "@") {
          [_, found] -> list.contains(domains, found)
          _ -> False
        }
      Ok(provider.Identity(
        issuer,
        claims.subject,
        claims.email,
        authoritative,
        option.None,
      ))
    },
  )
}

fn domain(value: String) -> Bool {
  string.contains(value, ".")
  && !string.starts_with(value, ".")
  && !string.ends_with(value, ".")
  && list.all(string.to_graphemes(value), fn(c) {
    string.contains("abcdefghijklmnopqrstuvwxyz0123456789.-", c)
  })
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
      |> result.replace_error(service.Internal("OpenID Connect request failed"))
    },
    "OpenID Connect request failed",
  )
}
