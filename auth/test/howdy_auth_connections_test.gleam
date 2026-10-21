//// SSO connections: configuration at rest, domains, and group binding.

import gleam/dynamic/decode
import gleam/json
import gleam/string
import gloo/repo
import howdy/auth
import howdy/auth/connection
import howdy/auth/connections
import howdy/auth/group
import howdy/auth/groups
import howdy/auth/internal/token
import howdy/auth/secret
import howdy/auth/user
import howdy/service
import support.{count, exec, fixture}

/// A self-signed certificate for idp.example.com; its key was discarded.
const certificate = "-----BEGIN CERTIFICATE-----
MIIDFTCCAf2gAwIBAgIUNPtY0p1M4BqN/73r5Hk2gZduAZswDQYJKoZIhvcNAQEL
BQAwGjEYMBYGA1UEAwwPaWRwLmV4YW1wbGUuY29tMB4XDTI2MDkyMDIwMjkwMloX
DTM2MDkxNzIwMjkwMlowGjEYMBYGA1UEAwwPaWRwLmV4YW1wbGUuY29tMIIBIjAN
BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAuEJQUIw122EYSlfCgygCQi1/G5I3
8GL0c1VpTqsJX/wE5zpHQ5EdICNeKx1BD9cBiZYFutLv+z085JNZ1jqpK8//Njpz
6lXllZIMuIKgjreMy4k2FhmkflYQzOZXNFymxCkTAO7k43icSMiDZEDNAzzrwHo1
jk8fPnniygS1C1VwZb7Bhgg/7yB5YUa1Sy8mar+7/Z83DIQhf48NkgsIn8zYrb1w
7kEcbL8i51wn++oLTLXxJHYpUqgNxt4V/NQ7zFrvCHesMsy4BAn9WSqp1KloVveb
Rdft/nxeAnr8y1rz2CKvvwINnsyVtSnMnEipZ7d7bAyO0OPYTI1F3yaFPwIDAQAB
o1MwUTAdBgNVHQ4EFgQU4T8867BlksOPdZBOqJ+hdmC60N8wHwYDVR0jBBgwFoAU
4T8867BlksOPdZBOqJ+hdmC60N8wDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0B
AQsFAAOCAQEAcFp9yNlxj4bjs6BWH/oa/6FamHlNq30VYTzKU7XlL+NDTY/yeYkb
GiSivLIDjjpV9XTt6a5s5poIx/GqaS+K6XlsbAUI7q0fBGsz/i8enEBZ/EOitOI+
XDYDiy2u8j/wfFXv+BvJ7FLgGR95y362KPgHz17JIj5muBGexQg2A7piXn8poI5e
Wdo3CJsPeuvEXbsb3qzFHzQGt6ddKWZql3g6M5k944tx19nNX8x8vZD3+4zSkveV
pcLHD/xaGee0YRrO7Z9/fVhgNTIe2sX/KjdBUpHp9d2T1wNrWVZngo2o9+0/1rVK
PDWD1t/a3yIdIWhHJVN6btv2qf3xNeISVg==
-----END CERTIFICATE-----
"

fn with_sso(identity: auth.Auth) -> auth.Auth {
  let assert Ok(config) = connection.config(token.new())
  auth.with_sso(identity, config)
}

fn okta() -> connection.Protocol {
  connection.oidc(
    issuer: "https://acme.okta.example",
    client_id: "client",
    client_secret: "hunter2-client-secret",
  )
}

fn saml() -> connection.Protocol {
  connection.Saml(
    "https://idp.example.com/metadata",
    "https://idp.example.com/sso",
    [certificate],
  )
}

pub fn connections_are_refused_until_sso_is_enabled_test() {
  use _, identity, _, _ <- fixture
  assert !auth.sso_enabled(identity)
  assert connections.list(identity) == Error(service.Forbidden)
  let assert Error(service.Forbidden) =
    connections.create(
      identity,
      group: group.default_id,
      name: "Acme",
      protocol: okta(),
      domains: [],
      by: user.System,
    )
  let assert Error(service.Invalid(_)) = connection.config("too-short")
}

pub fn a_connection_round_trips_with_its_secret_sealed_at_rest_test() {
  use database, identity, _, _ <- fixture
  let identity = with_sso(identity)
  let assert Ok(created) =
    connections.create_with_id(
      identity,
      id: "acme",
      group: group.default_id,
      name: " Acme ",
      protocol: okta(),
      domains: ["Acme.com", "acme.com", "acme.co.uk"],
      by: user.System,
    )
  assert created.name == "Acme"
  assert created.domains == ["acme.co.uk", "acme.com"]
  assert created.enabled
  let assert Ok(connection.Connection(
    protocol: connection.Oidc(issuer, client_id, client_secret),
    ..,
  )) = connections.get(identity, "acme")
  assert issuer == "https://acme.okta.example"
  assert client_id == "client"
  assert secret.reveal(client_secret) == "hunter2-client-secret"
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_sso_connections WHERE config LIKE '%hunter2%' OR config LIKE '%okta%'",
    )
    == 0
  assert !string.contains(
    json.to_string(connection.to_json(created)),
    "hunter2",
  )
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'sso.created' AND detail = 'acme'",
    )
    == 1
}

pub fn a_sealed_row_does_not_open_under_another_id_or_key_test() {
  use database, identity, _, _ <- fixture
  let first = with_sso(identity)
  let assert Ok(_) =
    connections.create_with_id(
      first,
      id: "acme",
      group: group.default_id,
      name: "Acme",
      protocol: okta(),
      domains: [],
      by: user.System,
    )
  let assert Error(service.Internal(_)) =
    connections.get(with_sso(identity), "acme")
  exec(database, "UPDATE howdy_auth_sso_connections SET id = 'globex'")
  let assert Error(service.Internal(_)) = connections.get(first, "globex")
}

pub fn protocols_domains_and_ids_are_validated_test() {
  use _, identity, _, _ <- fixture
  let identity = with_sso(identity)
  let create = fn(id, protocol, domains) {
    connections.create_with_id(
      identity,
      id:,
      group: group.default_id,
      name: "Acme",
      protocol:,
      domains:,
      by: user.System,
    )
  }
  let assert Error(service.Invalid(_)) = create("has space", okta(), [])
  let assert Error(service.Invalid(_)) =
    create("a", connection.oidc("http://acme.okta.example", "c", "s"), [])
  let assert Error(service.Invalid(_)) =
    create("a", connection.oidc("https://acme.okta.example/", "c", "s"), [])
  let assert Error(service.Invalid(_)) =
    create("a", connection.oidc("https://acme.okta.example", "c", ""), [])
  let assert Error(service.Invalid(_)) =
    create(
      "a",
      connection.Saml("entity", "https://idp.example.com/sso", [
        "-----BEGIN CERTIFICATE-----\nbm90IGEgY2VydA==\n-----END CERTIFICATE-----\n",
      ]),
      [],
    )
  let assert Error(service.Invalid(_)) =
    create(
      "a",
      connection.Saml("entity", "https://idp.example.com/sso", []),
      [],
    )
  let assert Error(service.Invalid(_)) = create("a", okta(), ["localhost"])
  let assert Error(service.Invalid(_)) = create("a", okta(), ["ex ample.com"])
  let assert Ok(_) = create("a", saml(), ["example.com"])
  let assert Error(service.Conflict(_)) = create("a", okta(), [])
}

pub fn a_domain_routes_to_one_connection_test() {
  use _, identity, _, _ <- fixture
  let identity = with_sso(identity)
  let create = fn(id, domains) {
    connections.create_with_id(
      identity,
      id:,
      group: group.default_id,
      name: id,
      protocol: okta(),
      domains:,
      by: user.System,
    )
  }
  let assert Ok(_) = create("acme", ["acme.com"])
  let assert Error(service.Conflict(_)) = create("globex", ["acme.com"])
  // The failed create rolled back whole.
  let assert Error(service.NotFound(_)) = connections.get(identity, "globex")
  let assert Ok(_) = create("globex", ["globex.com"])
  let assert Error(service.Conflict(_)) =
    connections.set_domains(
      identity,
      "globex",
      to: ["globex.com", "acme.com"],
      by: user.System,
    )
  let assert Ok(globex) = connections.get(identity, "globex")
  assert globex.domains == ["globex.com"]
  let assert Ok(_) =
    connections.set_domains(identity, "acme", to: [], by: user.System)
  let assert Ok(globex) =
    connections.set_domains(
      identity,
      "globex",
      to: ["globex.com", "acme.com"],
      by: user.System,
    )
  assert globex.domains == ["acme.com", "globex.com"]
}

pub fn connections_bind_to_an_existing_group_test() {
  use _, identity, _, _ <- fixture
  let single = with_sso(identity)
  let assert Error(service.Invalid(_)) =
    connections.create(
      single,
      group: "acme",
      name: "Acme",
      protocol: okta(),
      domains: [],
      by: user.System,
    )
  let assert Ok(identity) = auth.with_groups(identity, group.OneGroupPerUser)
  let identity = with_sso(identity)
  let assert Error(service.NotFound("group")) =
    connections.create(
      identity,
      group: "acme",
      name: "Acme",
      protocol: okta(),
      domains: [],
      by: user.System,
    )
  let assert Ok(_) =
    groups.create_with_id(identity, id: "acme", name: "Acme", by: user.System)
  let assert Ok(created) =
    connections.create(
      identity,
      group: "acme",
      name: "Acme",
      protocol: saml(),
      domains: [],
      by: user.System,
    )
  let assert Ok([listed]) = connections.in_group(identity, "acme")
  assert listed.id == created.id
  assert connections.in_group(identity, group.default_id) == Ok([])
  // The connection goes with its group.
  let assert Ok(Nil) = groups.delete(identity, "acme", by: user.System)
  assert connections.list(identity) == Ok([])
}

pub fn a_connection_is_renamed_reconfigured_disabled_and_deleted_test() {
  use database, identity, _, _ <- fixture
  let identity = with_sso(identity)
  let assert Ok(_) =
    connections.create_with_id(
      identity,
      id: "acme",
      group: group.default_id,
      name: "Acme",
      protocol: okta(),
      domains: ["acme.com"],
      by: user.System,
    )
  let assert Ok(renamed) =
    connections.rename(identity, "acme", to: "Acme Corp", by: user.System)
  assert renamed.name == "Acme Corp"
  let assert Ok(moved) =
    connections.set_protocol(identity, "acme", to: saml(), by: user.System)
  let assert connection.Saml(certificates: [pem], ..) = moved.protocol
  assert pem == certificate
  let assert Ok(disabled) =
    connections.disable(identity, "acme", by: user.System)
  assert !disabled.enabled
  let assert Ok(enabled) = connections.enable(identity, "acme", by: user.System)
  assert enabled.enabled
  let assert Error(service.NotFound(_)) =
    connections.rename(identity, "nope", to: "x", by: user.System)
  let assert Ok(Nil) = connections.delete(identity, "acme", by: user.System)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_sso_domains") == 0
  let assert Error(service.NotFound(_)) = connections.get(identity, "acme")
}

pub fn connections_reseal_under_a_rotated_key_test() {
  use database, identity, _, _ <- fixture
  let old = token.new()
  let new = token.new()
  let assert Ok(before) = connection.config(old)
  let assert Ok(_) =
    connections.create_with_id(
      auth.with_sso(identity, before),
      id: "acme",
      group: group.default_id,
      name: "Acme",
      protocol: okta(),
      domains: ["acme.com"],
      by: user.System,
    )
  let sealed = fn() {
    let assert Ok([value]) =
      repo.all(
        database,
        "SELECT config FROM howdy_auth_sso_connections",
        [],
        decode.field(0, decode.string, decode.success),
      )
    value
  }
  let original = sealed()
  let assert Ok(after) = connection.config(new)
  let assert Error(service.Internal(message)) =
    connections.reseal(auth.with_sso(identity, after))
  assert string.contains(message, "acme")
  let assert Ok(rotating) = connection.with_decryption_keys(after, [old])
  let rotating = auth.with_sso(identity, rotating)
  let assert Ok(_) = connections.get(rotating, "acme")
  assert connections.reseal(rotating) == Ok(1)
  assert connections.reseal(rotating) == Ok(0)
  assert sealed() != original
  let assert Ok(connection.Connection(
    protocol: connection.Oidc(client_secret:, ..),
    ..,
  )) = connections.get(auth.with_sso(identity, after), "acme")
  assert secret.reveal(client_secret) == "hunter2-client-secret"
}
