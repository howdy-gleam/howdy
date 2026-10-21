//// Enterprise single sign-on connections: one customer's identity provider,
//// bound to the group its users sign in to. Manage them with
//// `howdy/auth/connections`, after enabling them with `auth.with_sso`.
////
//// A connection's identity provider is run by the customer, not by a party
//// Howdy can pin. It may assert any address, so an address is only believed
//// inside the connection's own `domains`, and its users only ever land in the
//// connection's group.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import gleam/uri
import howdy/auth/internal/keyring.{type Keyring}
import howdy/auth/internal/provider_keys
import howdy/auth/internal/sso_transport
import howdy/auth/secret
import howdy/auth/user
import howdy/service

/// Keep the encryption key outside the auth database; all nodes must use the
/// same stable, 32-byte base64url key. It may be the MFA key. Rotate it with
/// `with_decryption_keys` and `connections.reseal`.
pub opaque type Config {
  Config(keys: Keyring, send: sso_transport.Send, cache: provider_keys.Cache)
}

pub fn config(encryption_key: String) -> service.Result(Config) {
  use keys <- result.map(
    keyring.new(encryption_key) |> result.replace_error(invalid_key),
  )
  Config(keys, sso_transport.send, provider_keys.new())
}

const invalid_key = service.Invalid(
  "SSO encryption key must be 32 random bytes encoded as base64url",
)

/// Keys that still decrypt connections but never encrypt new ones, replacing
/// any given before. Rotate in the same three steps as `mfa.with_decryption_keys`,
/// finishing with `connections.reseal`.
pub fn with_decryption_keys(
  config: Config,
  keys: List(String),
) -> service.Result(Config) {
  use keys <- result.map(
    keyring.with_decryption_keys(config.keys, keys)
    |> result.replace_error(invalid_key),
  )
  Config(..config, keys:)
}

@internal
pub fn keys(config: Config) -> Keyring {
  config.keys
}

/// Internal network seam: tests exercise the real signature and claims
/// verifiers against a provider they play themselves.
@internal
pub fn with_transport(config: Config, send: sso_transport.Send) -> Config {
  Config(..config, send:)
}

@internal
pub fn transport(config: Config) -> sso_transport.Send {
  config.send
}

/// Discovery documents and signing keys, per URL, owned by the process that
/// constructed the configuration.
@internal
pub fn cache(config: Config) -> provider_keys.Cache {
  config.cache
}

/// Whether the connection is believed about this normalized address.
@internal
pub fn owns_email(connection: Connection, email: String) -> Bool {
  case string.split(email, "@") {
    [_, domain] -> list.contains(connection.domains, domain)
    _ -> False
  }
}

pub type Connection {
  Connection(
    id: String,
    group_id: String,
    /// Shown on the sign-in page, such as the customer's name.
    name: String,
    protocol: Protocol,
    /// Lowercase email domains that route to this connection, and the only
    /// ones whose asserted addresses it is believed about.
    domains: List(String),
    enabled: Bool,
    /// Whether the members it covers may sign in only through it; see
    /// `connections.enforce`.
    enforced: Bool,
    /// Whether a sign-in through it skips Howdy's own second factor; see
    /// `connections.trust_provider_mfa`.
    trusts_provider_mfa: Bool,
    created_at: Timestamp,
    updated_at: Timestamp,
  )
}

/// What the customer's identity provider administrator hands over.
pub type Protocol {
  /// OpenID Connect. Endpoints and keys are discovered at `issuer`, an HTTPS
  /// URL exactly as the provider publishes it.
  Oidc(issuer: String, client_id: String, client_secret: secret.Secret)
  /// SAML 2.0. `certificates` are the provider's PEM signing certificates:
  /// more than one only while it rotates. They are pinned; a certificate
  /// inside a response is never trusted.
  Saml(entity_id: String, sso_url: String, certificates: List(String))
}

/// Construct an `Oidc` protocol from plain text.
pub fn oidc(
  issuer issuer: String,
  client_id client_id: String,
  client_secret client_secret: String,
) -> Protocol {
  Oidc(issuer, client_id, secret.wrap(client_secret))
}

/// The client secret and certificates stay out of JSON.
pub fn to_json(connection: Connection) -> json.Json {
  json.object([
    #("id", json.string(connection.id)),
    #("group_id", json.string(connection.group_id)),
    #("name", json.string(connection.name)),
    #("kind", json.string(kind(connection.protocol))),
    #("domains", json.array(connection.domains, json.string)),
    #("enabled", json.bool(connection.enabled)),
    #("enforced", json.bool(connection.enforced)),
    #("trusts_provider_mfa", json.bool(connection.trusts_provider_mfa)),
    #("created_at", user.time_to_json(connection.created_at)),
    #("updated_at", user.time_to_json(connection.updated_at)),
  ])
}

@internal
pub fn kind(protocol: Protocol) -> String {
  case protocol {
    Oidc(..) -> "oidc"
    Saml(..) -> "saml"
  }
}

/// The name the customer's provider gives itself. Subjects mean something
/// only relative to it.
@internal
pub fn upstream(protocol: Protocol) -> String {
  case protocol {
    Oidc(issuer:, ..) -> "oidc " <> issuer
    Saml(entity_id:, ..) -> "saml " <> entity_id
  }
}

/// The issuer local identities are keyed under. It is the connection, never
/// the name a customer's provider gives itself, so one customer's provider
/// cannot assert its way into another's identities.
@internal
pub fn identity_issuer(id: String) -> String {
  "sso:" <> id
}

@internal
pub fn valid_protocol(protocol: Protocol) -> service.Result(Protocol) {
  case protocol {
    Oidc(issuer, client_id, client_secret) ->
      case
        https_url(issuer)
        && !string.ends_with(issuer, "/")
        && text(client_id, 512)
        && text(secret.reveal(client_secret), 2048)
      {
        True -> Ok(protocol)
        False ->
          Error(service.Invalid(
            "OIDC connections need an HTTPS issuer without a trailing slash, a client ID and a client secret",
          ))
      }
    Saml(entity_id, sso_url, certificates) ->
      case
        text(entity_id, 1024)
        && https_url(sso_url)
        && certificates != []
        && list.length(certificates) <= 4
        && list.all(certificates, valid_certificate)
      {
        True -> Ok(protocol)
        False ->
          Error(service.Invalid(
            "SAML connections need an entity ID, an HTTPS sign-on URL and one to four PEM certificates",
          ))
      }
  }
}

/// Lowercase, deduplicated, and shaped like a registrable domain.
@internal
pub fn valid_domains(domains: List(String)) -> service.Result(List(String)) {
  let domains =
    list.map(domains, fn(d) { string.lowercase(string.trim(d)) }) |> list.unique
  let allowed = "abcdefghijklmnopqrstuvwxyz0123456789.-"
  case
    list.length(domains) <= 50
    && list.all(domains, fn(d) {
      string.byte_size(d) <= 253
      && string.contains(d, ".")
      && !string.starts_with(d, ".")
      && !string.ends_with(d, ".")
      && !string.contains(d, "..")
      && list.all(string.to_graphemes(d), string.contains(allowed, _))
    })
  {
    True -> Ok(domains)
    False ->
      Error(service.Invalid(
        "SSO domains are at most 50 ASCII domain names such as example.com",
      ))
  }
}

fn text(value: String, limit: Int) -> Bool {
  string.trim(value) == value && value != "" && string.byte_size(value) <= limit
}

fn https_url(value: String) -> Bool {
  case uri.parse(value) {
    Ok(uri.Uri(
      scheme: Some("https"),
      userinfo: None,
      host: Some(host),
      fragment: None,
      ..,
    )) -> host != "" && text(value, 2048)
    _ -> False
  }
}

@external(erlang, "howdy_auth_sso_ffi", "valid_certificate")
fn valid_certificate(pem: String) -> Bool

/// The stored form of a protocol, sealed to its connection: a row copied
/// under another id does not open.
@internal
pub fn seal(
  config: Config,
  id: String,
  protocol: Protocol,
) -> service.Result(String) {
  let plain =
    json.to_string(case protocol {
      Oidc(issuer, client_id, client_secret) ->
        json.object([
          #("issuer", json.string(issuer)),
          #("client_id", json.string(client_id)),
          #("client_secret", json.string(secret.reveal(client_secret))),
        ])
      Saml(entity_id, sso_url, certificates) ->
        json.object([
          #("entity_id", json.string(entity_id)),
          #("sso_url", json.string(sso_url)),
          #("certificates", json.array(certificates, json.string)),
        ])
    })
  keyring.seal(config.keys, id, plain)
  |> result.replace_error(service.Internal("SSO encryption failed"))
}

@internal
pub fn open(
  config: Config,
  id: String,
  kind: String,
  sealed: String,
) -> service.Result(Protocol) {
  let failed = service.Internal("SSO connection could not be decrypted")
  use plain <- result.try(
    keyring.open(config.keys, id, sealed)
    |> result.replace_error(failed),
  )
  let decoder = case kind {
    "oidc" -> {
      use issuer <- decode.field("issuer", decode.string)
      use client_id <- decode.field("client_id", decode.string)
      use client_secret <- decode.field("client_secret", decode.string)
      decode.success(Oidc(issuer, client_id, secret.wrap(client_secret)))
    }
    _ -> {
      use entity_id <- decode.field("entity_id", decode.string)
      use sso_url <- decode.field("sso_url", decode.string)
      use certificates <- decode.field(
        "certificates",
        decode.list(decode.string),
      )
      decode.success(Saml(entity_id, sso_url, certificates))
    }
  }
  json.parse(plain, decoder) |> result.replace_error(failed)
}
