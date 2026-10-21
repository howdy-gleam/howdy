//// External identity providers. Install one with `auth.with_provider`.
////
//// The built-in constructors in `howdy/auth/providers` cover Google, GitHub,
//// Facebook, Microsoft Entra, Apple and any OpenID Connect issuer
//// (`providers/oidc`). For anything else, `custom` takes the two steps of
//// an OAuth 2.0 authorization-code flow and leaves everything around them
//// (state, PKCE, nonce, cookies, linking, MFA and sessions) to Howdy.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import howdy/auth/internal/token
import howdy/auth/secret
import howdy/service

pub opaque type Provider {
  Provider(
    id: String,
    name: String,
    valid: service.Result(Nil),
    authorize: fn(Authorization) -> service.Result(String),
    verify: fn(Exchange) -> service.Result(Identity),
    issuer: Option(String),
  )
}

/// What to put in the provider's authorization URL. Send `redirect_uri` and
/// `state` unchanged. `challenge` is a PKCE S256 code challenge: send it as
/// `code_challenge` with `code_challenge_method=S256` if the provider
/// supports PKCE. `nonce` is for OpenID Connect providers; others ignore it.
pub type Authorization {
  Authorization(
    redirect_uri: String,
    state: String,
    nonce: String,
    challenge: String,
  )
}

/// A returning callback, with `state` already checked. Redeem `code` at the
/// provider's token endpoint with this `redirect_uri` and, if you sent a
/// challenge, `verifier` as `code_verifier`. An OpenID Connect ID token's
/// nonce must pass `nonce_matches`.
pub type Exchange {
  Exchange(
    code: secret.Secret,
    redirect_uri: String,
    verifier: secret.Secret,
    nonce_digest: String,
  )
}

/// Who the provider says signed in, returned by a `custom` provider's
/// `verify`.
///
/// `subject` is the provider's stable, unique identifier for the account,
/// never an email address or anything else its owner can change: accounts are
/// linked by it. At most 255 bytes.
///
/// `email` is the address the provider reports, or empty. Howdy never
/// attaches a provider sign-in to an existing account because the addresses
/// match; the user links it from the account page. The address only matters
/// when the provider sign-in creates a new account, which needs
/// `email_authoritative`: set it only when the provider is the authority for
/// that address, as Google is for `@gmail.com`, not merely when it once
/// verified the address. Setting it wrongly lets anyone who can make an
/// account at the provider claim an address that is not theirs. When
/// unsure, leave it False: new users then register by email and link.
pub type Verified {
  Verified(subject: String, email: String, email_authoritative: Bool)
}

/// Verified by the provider, before local account policy is applied.
@internal
pub type Identity {
  Identity(
    issuer: String,
    subject: String,
    email: String,
    email_authoritative: Bool,
    hosted_domain: Option(String),
  )
}

/// A provider of your own. `id` names it in routes and cookies: lowercase
/// letters, digits and hyphens, at most 32. `name` is shown on sign-in pages.
/// `issuer` is the provider's HTTPS URL; its accounts are recorded under it,
/// kept apart from every built-in provider and SSO connection, so changing it
/// later forgets every linked account. Two installed providers may not share
/// one.
///
/// `authorize` returns the URL to send the browser to. `verify` redeems the
/// code and returns the account; return `Error(service.Unauthorized)` for
/// anything the provider refuses or that fails to parse. Bound the size of
/// responses you read, and do not log them: they carry the user's tokens.
/// Any provider access token is yours to discard; Howdy stores none.
///
/// ```gleam
/// let assert Ok(identity) =
///   auth.with_provider(identity, provider.custom(
///     id: "gitea",
///     name: "Gitea",
///     issuer: "https://git.example.com",
///     authorize: fn(request) {
///       "https://git.example.com/login/oauth/authorize?" <> uri.query_to_string([
///         #("client_id", client_id),
///         #("redirect_uri", request.redirect_uri),
///         #("response_type", "code"),
///         #("state", request.state),
///         #("code_challenge", request.challenge),
///         #("code_challenge_method", "S256"),
///       ])
///     },
///     verify: fn(exchange) { gitea_account(exchange) },
///   ))
/// ```
pub fn custom(
  id id: String,
  name name: String,
  issuer issuer: String,
  authorize authorize: fn(Authorization) -> String,
  verify verify: fn(Exchange) -> service.Result(Verified),
) -> Provider {
  let valid = case valid_id(id), string.trim(name), https(issuer) {
    False, _, _ ->
      Error(service.Invalid(
        "provider id must be 1 to 32 lowercase letters, digits or hyphens",
      ))
    _, "", _ -> Error(service.Invalid("provider name is required"))
    _, _, False ->
      Error(service.Invalid("provider issuer must be an HTTPS URL"))
    True, _, True ->
      case string.byte_size(name) <= 100 {
        True -> Ok(Nil)
        False -> Error(service.Invalid("provider name is at most 100 bytes"))
      }
  }
  Provider(
    id:,
    name: string.trim(name),
    valid:,
    authorize: fn(request) { Ok(authorize(request)) },
    verify: fn(exchange) {
      use found <- result.try(verify(exchange))
      case found.subject != "" && string.byte_size(found.subject) <= 255 {
        True ->
          Ok(Identity(
            custom_issuer(issuer),
            found.subject,
            found.email,
            found.email_authoritative,
            None,
          ))
        False -> Error(service.Unauthorized)
      }
    },
    issuer: Some(issuer),
  )
}

/// Whether an ID token's `nonce` claim is the one this sign-in sent.
pub fn nonce_matches(exchange: Exchange, nonce: String) -> Bool {
  token.constant_time_equal(token.digest(nonce), exchange.nonce_digest)
}

/// The issuer a `custom` provider's accounts are recorded under.
fn custom_issuer(issuer: String) -> String {
  "custom:" <> issuer
}

@internal
pub fn valid_id(id: String) -> Bool {
  id != ""
  && string.byte_size(id) <= 32
  && list.all(string.to_graphemes(id), fn(c) {
    string.contains("abcdefghijklmnopqrstuvwxyz0123456789-", c)
  })
}

@internal
pub fn https(url: String) -> Bool {
  case uri.parse(url) {
    Ok(uri.Uri(
      scheme: Some("https"),
      userinfo: None,
      host: Some(host),
      fragment: None,
      query: None,
      ..,
    )) -> host != "" && string.byte_size(url) <= 2048
    _ -> False
  }
}

@internal
pub fn new(
  id: String,
  name: String,
  valid: service.Result(Nil),
  authorize: fn(Authorization) -> String,
  verify: fn(Exchange) -> service.Result(Identity),
) -> Provider {
  Provider(
    id,
    name,
    valid,
    fn(request) { Ok(authorize(request)) },
    verify,
    None,
  )
}

/// For providers configured from discovery: building the URL can fail.
/// `issuer` is recorded to refuse installing two providers for one issuer.
@internal
pub fn discovered(
  id: String,
  name: String,
  valid: service.Result(Nil),
  issuer: String,
  authorize: fn(Authorization) -> service.Result(String),
  verify: fn(Exchange) -> service.Result(Identity),
) -> Provider {
  Provider(id, name, valid, authorize, verify, Some(issuer))
}

pub fn id(provider: Provider) -> String {
  provider.id
}

pub fn name(provider: Provider) -> String {
  provider.name
}

/// The issuer a custom or OpenID Connect provider declared, if any.
@internal
pub fn issuer(provider: Provider) -> Option(String) {
  provider.issuer
}

@internal
pub fn validate(provider: Provider) -> service.Result(Nil) {
  provider.valid
}

@internal
pub fn authorization_url(
  provider: Provider,
  request: Authorization,
) -> service.Result(String) {
  provider.authorize(request)
}

@internal
pub fn exchange(
  provider: Provider,
  request: Exchange,
) -> service.Result(Identity) {
  provider.verify(request)
}

@internal
pub fn require_domain(provider: Provider, domain: String) -> Provider {
  let valid = case
    domain != "" && string.contains(domain, ".") && list_domain(domain)
  {
    True -> provider.valid
    False -> Error(service.Invalid("invalid Google hosted domain"))
  }
  Provider(
    ..provider,
    valid:,
    authorize: fn(request) {
      provider.authorize(request)
      |> result.map(fn(url) { url <> "&hd=" <> uri.percent_encode(domain) })
    },
    verify: fn(request) {
      use identity <- result.try(provider.verify(request))
      case identity.hosted_domain {
        Some(found) if found == domain -> Ok(identity)
        Some(_) | None -> Error(service.Forbidden)
      }
    },
  )
}

fn list_domain(domain: String) -> Bool {
  case domain {
    "" -> True
    _ -> {
      let assert Ok(#(first, rest)) = string.pop_grapheme(domain)
      string.contains("abcdefghijklmnopqrstuvwxyz0123456789.-", first)
      && list_domain(rest)
    }
  }
}
