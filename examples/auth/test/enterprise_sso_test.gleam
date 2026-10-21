import flows/enterprise_sso
import gleam/bit_array
import gleam/crypto
import gleam/http/response
import gleam/option.{Some}
import gleam/string
import howdy/auth
import howdy/auth/connection
import howdy/auth/connections
import howdy/auth/user
import howdy/testing
import support.{from_browser}

/// A self-signed certificate standing in for the customer's SAML signing
/// certificate. Only its public half is needed to configure a connection.
const idp_certificate = "-----BEGIN CERTIFICATE-----
MIIDETCCAfmgAwIBAgIUZxJrVUeF7IJaP2u4EytF9NWsRwowDQYJKoZIhvcNAQEL
BQAwGDEWMBQGA1UEAwwNaWRwLmFjbWUudGVzdDAeFw0yNjA5MjQxMzQ2NTBaFw0z
NjA5MjExMzQ2NTBaMBgxFjAUBgNVBAMMDWlkcC5hY21lLnRlc3QwggEiMA0GCSqG
SIb3DQEBAQUAA4IBDwAwggEKAoIBAQC6kbMeVDPp089R1M7IL9NqJEju1jceJdbJ
f+miKRzS9Al3yJ5jW1zJSVpsJRcDAocApvK49DzgdrvuYtubxxy1cfz0JJ0RfQ3g
bACKg8cD/y5yWf++QUBDTTSL/dcn7VArx8CTNw0L7/Tb+6VYHJrlwEBhLIlAO813
L1WLWcBIHxAs5z0lrs4aE6mFxfaH0wqEOOwTrra2R+/rUtWyhDh1ixiFkQhhJ+6I
74DpgYlWHWF661eOl+ynce+KHEa1cusd/fK0IXygrQRNm5ebJsnM/DdyaJlVU8AH
A+Ppxwgrwoijf3XgMtmDXCE5Ve+PxB+49TKGP5sJfeTZDSidrVEnAgMBAAGjUzBR
MB0GA1UdDgQWBBTXasD6x9UlWPhSTB9/uUDYbMo7jjAfBgNVHSMEGDAWgBTXasD6
x9UlWPhSTB9/uUDYbMo7jjAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUA
A4IBAQCakZrDL/uUfYZKisjjTAWahU3EBTcHJBT/PVvpzuXc715WRXWU+NKXHPQM
buHG8BxN4SsbekA55yJwCN7GOOu2v48TTzeQXFDIdTNnq8YpdVircTDSTEUieQOY
BCc4AaCJ3YK1PzDnvFwXXtkRWajrOkQXJZVCSU1WMDaodQ+eYCYKJuGcmC3W+kqC
8+hYzBs16yXjDg69aZy1LxScqMh8OKKArm4ozgPQJplYFBmUAfGkvrCAa0r4qXdU
vGRIi29fJccEuBezrRrE3MLoiob4BeaLY6L0PM/E7Mkaaz0GtIJfdMUAh8wF5JRf
CKkjP2ujOxleoaygm9h+dRc9QYjW
-----END CERTIFICATE-----
"

fn onboarded(db, deliver) -> auth.Auth {
  let sso_key =
    crypto.strong_random_bytes(32) |> bit_array.base64_url_encode(False)
  let identity = enterprise_sso.configure(db, deliver, sso_key:)
  let assert Ok(_) =
    enterprise_sso.onboard(
      identity,
      id: "acme",
      name: "Acme",
      protocol: connection.Saml(
        entity_id: "https://idp.acme.test/metadata",
        sso_url: "https://idp.acme.test/sso",
        certificates: [idp_certificate],
      ),
      domains: ["acme.test"],
      by: user.System,
    )
  identity
}

pub fn the_address_picks_the_connection_test() {
  use db <- support.with_database
  let #(_, deliver) = support.mailbox()
  let app = onboarded(db, deliver) |> enterprise_sso.app

  let page = testing.get("/login") |> testing.send(app)
  assert string.contains(testing.text(page), "action=\"/auth/sso/login\"")

  let started =
    testing.post_form("/auth/sso/login", [#("email", "ada@acme.test")])
    |> from_browser
    |> testing.send(app)
  assert started.status == 303
  let assert Ok(location) = response.get_header(started, "location")
  assert string.starts_with(location, "https://idp.acme.test/sso?SAMLRequest=")

  // No connection serves this domain: back to the sign-in page.
  let elsewhere =
    testing.post_form("/auth/sso/login", [#("email", "ada@example.com")])
    |> from_browser
    |> testing.send(app)
  assert response.get_header(elsewhere, "location") == Ok("/login")
}

pub fn saml_customers_get_service_provider_metadata_test() {
  use db <- support.with_database
  let #(_, deliver) = support.mailbox()
  let app = onboarded(db, deliver) |> enterprise_sso.app

  let metadata = testing.get("/auth/sso/acme/metadata") |> testing.send(app)
  assert metadata.status == 200
  // One URL is the entity ID (audience) and the assertion consumer service.
  assert string.contains(
    testing.text(metadata),
    "http://localhost:8787/auth/sso/acme/callback",
  )
}

pub fn enforcement_makes_sso_the_only_way_in_test() {
  use db <- support.with_database
  let #(inbox, deliver) = support.mailbox()
  let identity = onboarded(db, deliver)
  // A member of acme's group inside its domain, and a contractor outside it.
  let assert Ok(_) =
    auth.provision(
      auth.in_group(identity, "acme"),
      "ada@acme.test",
      by: user.System,
    )
  let assert Ok(_) =
    auth.provision(
      auth.in_group(identity, "acme"),
      "contractor@example.com",
      by: user.System,
    )
  let assert Ok(Nil) = auth.request_token(identity, "ada@acme.test", auth.Login)
  assert support.next_email(inbox).email == "ada@acme.test"

  let assert Ok(_) = connections.enforce(identity, "acme", by: user.System)

  // Covered members get no token (the reply is unchanged); guests still do.
  let assert Ok(Nil) = auth.request_token(identity, "ada@acme.test", auth.Login)
  assert support.no_email(inbox)
  let assert Ok(Nil) =
    auth.request_token(identity, "contractor@example.com", auth.Login)
  assert support.next_email(inbox).email == "contractor@example.com"
  assert auth.sso_for_email(identity, "ada@acme.test") == Ok(Some("acme"))
}
