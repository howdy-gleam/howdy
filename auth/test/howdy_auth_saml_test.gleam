//// SSO over SAML 2.0. Responses are really signed (enveloped RSA-SHA256 over
//// exclusive canonical XML) by a provider the test plays, then attacked.
//// Every path uses the production parser and signature verifier.

import gleam/bit_array
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri
import howdy
import howdy/auth
import howdy/auth/connection
import howdy/auth/connections
import howdy/auth/group
import howdy/auth/internal/token
import howdy/auth/routes
import howdy/auth/secret
import howdy/auth/user
import howdy/service
import howdy/testing
import support.{count, fixture}

const entity = "https://idp.test/metadata"

const acs = "https://example.test/auth/sso/acme/callback"

const callback = "/auth/sso/acme/callback"

@external(erlang, "provider_test_ffi", "certificate")
fn certificate() -> String

@external(erlang, "provider_test_ffi", "saml_sign")
fn sign(xml: String, id: String) -> String

@external(erlang, "provider_test_ffi", "saml_sign_other")
fn sign_with_another_key(xml: String, id: String) -> String

@external(erlang, "provider_test_ffi", "inflate")
fn inflate(encoded: String) -> String

@external(erlang, "provider_test_ffi", "instant")
fn instant(seconds: Int) -> String

@external(erlang, "howdy_auth_saml_ffi", "atoms_spent")
fn atoms_spent() -> Int

/// What a test may change about an otherwise valid response.
type Shape {
  Shape(
    destination: String,
    recipient: String,
    audience: String,
    issuer: String,
    status: String,
    name_id: String,
    email: String,
    not_before: Int,
    not_on_or_after: Int,
    /// Replaces the request ID the response answers.
    in_response_to: Option(String),
    extra: String,
  )
}

fn valid() -> Shape {
  Shape(
    destination: acs,
    recipient: acs,
    audience: acs,
    issuer: entity,
    status: "urn:oasis:names:tc:SAML:2.0:status:Success",
    name_id: "ada-persistent-id",
    email: "Ada@Acme.com",
    not_before: token.now() - 30,
    not_on_or_after: token.now() + 300,
    in_response_to: None,
    extra: "",
  )
}

/// The Response and its Assertion, with a marker where each signature goes.
fn document(shape: Shape, request_id: String) -> String {
  let request_id = option.unwrap(shape.in_response_to, request_id)
  "<samlp:Response xmlns:samlp=\"urn:oasis:names:tc:SAML:2.0:protocol\" xmlns:saml=\"urn:oasis:names:tc:SAML:2.0:assertion\" ID=\"response\" Version=\"2.0\" IssueInstant=\""
  <> instant(token.now())
  <> "\" Destination=\""
  <> shape.destination
  <> "\" InResponseTo=\""
  <> request_id
  <> "\"><saml:Issuer>"
  <> shape.issuer
  <> "</saml:Issuer><!--sign:response--><samlp:Status><samlp:StatusCode Value=\""
  <> shape.status
  <> "\"/></samlp:Status>"
  <> assertion(shape, request_id, "assertion")
  <> shape.extra
  <> "</samlp:Response>"
}

fn assertion(shape: Shape, request_id: String, id: String) -> String {
  "<saml:Assertion xmlns:saml=\"urn:oasis:names:tc:SAML:2.0:assertion\" ID=\""
  <> id
  <> "\" Version=\"2.0\" IssueInstant=\""
  <> instant(token.now())
  <> "\"><saml:Issuer>"
  <> shape.issuer
  <> "</saml:Issuer><!--sign:"
  <> id
  <> "--><saml:Subject><saml:NameID Format=\"urn:oasis:names:tc:SAML:2.0:nameid-format:persistent\">"
  <> shape.name_id
  <> "</saml:NameID><saml:SubjectConfirmation Method=\"urn:oasis:names:tc:SAML:2.0:cm:bearer\"><saml:SubjectConfirmationData InResponseTo=\""
  <> request_id
  <> "\" NotOnOrAfter=\""
  <> instant(shape.not_on_or_after)
  <> "\" Recipient=\""
  <> shape.recipient
  <> "\"/></saml:SubjectConfirmation></saml:Subject><saml:Conditions NotBefore=\""
  <> instant(shape.not_before)
  <> "\" NotOnOrAfter=\""
  <> instant(shape.not_on_or_after)
  <> "\"><saml:AudienceRestriction><saml:Audience>"
  <> shape.audience
  <> "</saml:Audience></saml:AudienceRestriction></saml:Conditions><saml:AttributeStatement><saml:Attribute Name=\"http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress\"><saml:AttributeValue>"
  <> shape.email
  <> "</saml:AttributeValue></saml:Attribute></saml:AttributeStatement></saml:Assertion>"
}

fn unmark(xml: String) -> String {
  xml
  |> string.replace("<!--sign:response-->", "")
  |> string.replace("<!--sign:assertion-->", "")
  |> string.replace("<!--sign:evil-->", "")
}

fn encode(xml: String) -> String {
  bit_array.base64_encode(<<unmark(xml):utf8>>, True)
}

/// As Okta and Entra sign by default: the assertion only.
fn signed_assertion(shape: Shape, request_id: String) -> String {
  document(shape, request_id) |> sign("assertion")
}

fn acme(run: fn(_, auth.Auth) -> a) -> a {
  use database, identity, _, _ <- fixture
  let assert Ok(config) = connection.config(token.new())
  let identity = auth.with_sso(identity, config)
  let assert Ok(_) =
    connections.create_with_id(
      identity,
      id: "acme",
      group: group.default_id,
      name: "Acme",
      protocol: connection.Saml(entity, "https://idp.test/sso?tenant=acme", [
        certificate(),
      ]),
      domains: ["acme.com"],
      by: user.System,
    )
  run(database, identity)
}

fn parameter(url: String, name: String) -> String {
  let assert Ok(url) = uri.parse(url)
  let assert Some(query) = url.query
  let assert Ok(fields) = uri.parse_query(query)
  let assert Ok(value) = list.key_find(fields, name)
  value
}

/// The ID of the AuthnRequest a sign-in redirected the browser with.
fn request_id(start: auth.ProviderStart) -> String {
  let request = inflate(parameter(start.url, "SAMLRequest"))
  let assert [_, rest] = string.split(request, " ID=\"")
  let assert [id, ..] = string.split(rest, "\"")
  id
}

fn begin(identity: auth.Auth) -> auth.ProviderStart {
  let assert Ok(start) = auth.begin_sso(identity, "acme", callback, "client")
  start
}

fn finish(identity: auth.Auth, start: auth.ProviderStart, xml: String) {
  auth.finish_sso(
    identity,
    "acme",
    callback,
    parameter(start.url, "RelayState"),
    secret.reveal(start.browser_token),
    Some(encode(xml)),
    None,
  )
}

fn refused(identity: auth.Auth, build: fn(String) -> String) -> Nil {
  let start = begin(identity)
  let assert Error(service.Unauthorized) =
    finish(identity, start, build(request_id(start)))
  Nil
}

pub fn a_signed_assertion_signs_the_user_in_test() {
  use database, identity <- acme
  let start = begin(identity)
  assert string.starts_with(start.url, "https://idp.test/sso?tenant=acme&")
  let request = inflate(parameter(start.url, "SAMLRequest"))
  assert string.contains(request, "AssertionConsumerServiceURL=\"" <> acs)
  assert string.contains(request, "<saml:Issuer>" <> acs <> "</saml:Issuer>")
  assert string.contains(
    request,
    "Destination=\"https://idp.test/sso?tenant=acme\"",
  )
  let assert Ok(auth.ProviderSession(session)) =
    finish(identity, start, signed_assertion(valid(), request_id(start)))
  assert session.user.email == "ada@acme.com"
  // The response answered one request, and that request is spent.
  let assert Error(service.Unauthorized) =
    finish(identity, start, signed_assertion(valid(), request_id(start)))
  let again = begin(identity)
  let assert Ok(auth.ProviderSession(second)) =
    finish(
      identity,
      again,
      signed_assertion(
        Shape(..valid(), email: "renamed@acme.com"),
        request_id(again),
      ),
    )
  assert second.user.id == session.user.id
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 1
}

pub fn an_address_as_the_name_id_serves_when_no_attribute_does_test() {
  use _, identity <- acme
  let start = begin(identity)
  let xml =
    document(Shape(..valid(), name_id: "Grace@Acme.com"), request_id(start))
  let assert [before, rest] = string.split(xml, "<saml:AttributeStatement>")
  let assert [_, after] = string.split(rest, "</saml:AttributeStatement>")
  let assert Ok(auth.ProviderSession(session)) =
    finish(identity, start, sign(before <> after, "assertion"))
  assert session.user.email == "grace@acme.com"
}

pub fn a_signed_response_covers_its_assertion_test() {
  use _, identity <- acme
  let start = begin(identity)
  let assert Ok(auth.ProviderSession(_)) =
    finish(
      identity,
      start,
      document(valid(), request_id(start)) |> sign("response"),
    )
  // Both signed, assertion first, as Entra can be configured to.
  let start = begin(identity)
  let assert Ok(auth.ProviderSession(_)) =
    finish(
      identity,
      start,
      document(valid(), request_id(start))
        |> sign("assertion")
        |> sign("response"),
    )
}

pub fn signatures_are_required_pinned_and_cover_what_is_read_test() {
  use _, identity <- acme
  // Unsigned.
  refused(identity, document(valid(), _))
  // Signed by a key that is not the connection's.
  refused(identity, fn(id) {
    document(valid(), id) |> sign_with_another_key("assertion")
  })
  // Altered after signing.
  refused(identity, fn(id) {
    signed_assertion(valid(), id)
    |> string.replace("ada-persistent-id", "eve-persistent-id")
  })
  refused(identity, fn(id) {
    signed_assertion(valid(), id)
    |> string.replace("Ada@Acme.com", "ceo@acme.com")
  })
  // A valid response signature does not excuse a bad assertion signature.
  refused(identity, fn(id) {
    document(valid(), id)
    |> sign_with_another_key("assertion")
    |> sign("response")
  })
  // Wrapping: a second, unsigned assertion beside or inside the signed one.
  let evil = fn(id) {
    assertion(
      Shape(..valid(), name_id: "eve", email: "ceo@acme.com"),
      id,
      "evil",
    )
  }
  refused(identity, fn(id) {
    document(Shape(..valid(), extra: evil(id)), id) |> sign("assertion")
  })
  refused(identity, fn(id) {
    signed_assertion(valid(), id)
    |> string.replace(
      "<samlp:Status>",
      "<samlp:Extensions>" <> evil(id) <> "</samlp:Extensions><samlp:Status>",
    )
  })
  // The signed assertion hidden away, with the forgery where claims are read.
  refused(identity, fn(id) {
    let genuine = signed_assertion(valid(), id)
    let assert [before, rest] = string.split(genuine, "<saml:Assertion ")
    let assert [body, after] = string.split(rest, "</saml:Assertion>")
    before
    <> evil(id)
    <> "<samlp:Extensions><saml:Assertion "
    <> body
    <> "</saml:Assertion></samlp:Extensions>"
    <> after
  })
  // A reference to some other element than the one carrying the signature.
  refused(identity, fn(id) {
    signed_assertion(valid(), id)
    |> string.replace("URI=\"#assertion\"", "URI=\"#response\"")
  })
  // SHA-1, and a document type, are refused before anything is verified.
  refused(identity, fn(id) {
    signed_assertion(valid(), id) |> string.replace("rsa-sha256", "rsa-sha1")
  })
  refused(identity, fn(id) {
    "<!DOCTYPE r [<!ENTITY x \"y\">]>" <> signed_assertion(valid(), id)
  })
  refused(identity, fn(id) {
    signed_assertion(valid(), id)
    |> string.replace(
      "<saml:Assertion ",
      "<saml:EncryptedAssertion/><saml:Assertion ",
    )
  })
}

pub fn a_comment_cannot_shorten_a_signed_value_test() {
  use _, identity <- acme
  // Canonical XML ignores comments, so this passes signature verification;
  // what matters is that the whole value is read, not the part before it.
  let start = begin(identity)
  let xml =
    signed_assertion(
      Shape(..valid(), email: "ada@acme.com.evil.test"),
      request_id(start),
    )
    |> string.replace("ada@acme.com.evil.test", "ada@acme.com<!---->.evil.test")
  let assert Error(service.Forbidden) = finish(identity, start, xml)
}

pub fn conditions_are_enforced_test() {
  use _, identity <- acme
  let wrong = fn(shape: Shape) { refused(identity, signed_assertion(shape, _)) }
  wrong(Shape(..valid(), destination: "https://evil.test/acs"))
  wrong(Shape(..valid(), recipient: "https://evil.test/acs"))
  wrong(Shape(..valid(), audience: "https://other-sp.test"))
  wrong(Shape(..valid(), issuer: "https://another-idp.test/metadata"))
  wrong(
    Shape(..valid(), status: "urn:oasis:names:tc:SAML:2.0:status:Responder"),
  )
  wrong(Shape(..valid(), not_on_or_after: token.now() - 120))
  wrong(Shape(..valid(), not_before: token.now() + 600))
  wrong(Shape(..valid(), name_id: ""))
  // Answering some other request: another browser's, or none (IdP-initiated).
  wrong(Shape(..valid(), in_response_to: Some("_" <> token.new())))
  wrong(Shape(..valid(), in_response_to: Some("")))
  // The address is believed only inside the connection's domains.
  let start = begin(identity)
  let assert Error(service.Forbidden) =
    finish(
      identity,
      start,
      signed_assertion(
        Shape(..valid(), email: "ada@globex.com"),
        request_id(start),
      ),
    )
  // Not base64, not XML, and far too large.
  let start = begin(identity)
  let assert Error(service.Unauthorized) =
    auth.finish_sso(
      identity,
      "acme",
      callback,
      parameter(start.url, "RelayState"),
      secret.reveal(start.browser_token),
      Some("%%%"),
      None,
    )
  refused(identity, fn(_) { "not xml" })
  refused(identity, fn(id) {
    signed_assertion(valid(), id) <> string.repeat(" ", 300_000)
  })
}

pub fn browser_routes_test() {
  use _, identity <- acme
  let app =
    howdy.new()
    |> howdy.controller(routes.sso(
      identity,
      at: "/auth",
      success_path: "/account",
      failure_path: "/login",
    ))
    |> howdy.controller(routes.api(identity, at: "/api/auth"))
  let metadata = testing.get("/auth/sso/acme/metadata") |> testing.send(app)
  assert metadata.status == 200
  assert string.contains(testing.text(metadata), "entityID=\"" <> acs <> "\"")
  assert string.contains(testing.text(metadata), "Location=\"" <> acs <> "\"")
  let started =
    testing.post_form("/auth/sso/acme/login", [])
    |> testing.header("origin", "https://example.test")
    |> testing.send(app)
  let assert Ok(location) = response.get_header(started, "location")
  // The provider posts back from its own site: only SameSite=None arrives.
  let assert Ok(browser) =
    list.key_find(testing.cookies(started), "__Host-howdy_sso_post_acme")
  let assert Ok(set) =
    list.find_map(started.headers, fn(header) {
      case header.0 == "set-cookie" && string.contains(header.1, "_post_acme") {
        True -> Ok(header.1)
        False -> Error(Nil)
      }
    })
  assert string.contains(set, "SameSite=None") && string.contains(set, "Secure")
  let request = inflate(parameter(location, "SAMLRequest"))
  let assert [_, rest] = string.split(request, " ID=\"")
  let assert [id, ..] = string.split(rest, "\"")
  let post = fn(cookies: List(#(String, String))) {
    list.fold(
      cookies,
      testing.post_form(callback, [
        #("SAMLResponse", encode(signed_assertion(valid(), id))),
        #("RelayState", parameter(location, "RelayState")),
      ])
        |> testing.header("origin", "https://idp.test"),
      fn(req, c) { testing.cookie(req, c.0, c.1) },
    )
    |> testing.send(app)
  }
  // Another browser, holding the response but not the cookie, gets nowhere.
  let stolen = post([])
  assert response.get_header(stolen, "location") == Ok("/login")
  let completed = post([#("__Host-howdy_sso_post_acme", browser)])
  assert response.get_header(completed, "location") == Ok("/account")
  let assert Ok(session) =
    list.key_find(testing.cookies(completed), auth.cookie_name(identity))
  let me =
    testing.get("/api/auth/me")
    |> testing.cookie(auth.cookie_name(identity), session)
    |> testing.send(app)
  assert me.status == 200
  let replay = post([#("__Host-howdy_sso_post_acme", browser)])
  assert response.get_header(replay, "location") == Ok("/login")
}

pub fn a_response_over_the_atom_budget_is_refused_without_spending_test() {
  use _, identity <- acme
  let spent = atoms_spent()
  // 5001 names this node has never seen, on the unsigned Response element,
  // so only the budget stands between this document and a sign-in.
  let attributes =
    list.repeat("x", 5001)
    |> list.index_map(fn(_, n) { " howdyfresh" <> int.to_string(n) <> "=\"x\"" })
    |> string.concat
  refused(identity, fn(request_id) {
    signed_assertion(valid(), request_id)
    |> string.replace("ID=\"response\"", "ID=\"response\"" <> attributes)
  })
  // Refused before parsing, so nothing was spent, and the next sign-in with
  // ordinary names still goes through.
  assert atoms_spent() == spent
  let start = begin(identity)
  let assert Ok(_) =
    finish(identity, start, signed_assertion(valid(), request_id(start)))
}
