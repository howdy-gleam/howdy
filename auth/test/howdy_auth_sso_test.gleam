//// SSO over OpenID Connect. Real RSA signatures over synthetic ID tokens; only
//// the customer's provider is played by the test. Every path uses the
//// production discovery, signature and claims verifiers.

import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import gloo/repo.{type Repo}
import howdy
import howdy/auth
import howdy/auth/connection
import howdy/auth/connections
import howdy/auth/group
import howdy/auth/groups
import howdy/auth/internal/sso_transport
import howdy/auth/internal/token
import howdy/auth/mfa
import howdy/auth/routes
import howdy/auth/secret
import howdy/auth/user
import howdy/locale
import howdy/service
import howdy/testing
import support.{count, fixture, signup}

const issuer = "https://acme.okta.example"

const callback = "/auth/sso/acme/callback"

const header = "{\"alg\":\"RS256\",\"kid\":\"test-key\"}"

@external(erlang, "provider_test_ffi", "sign")
fn sign(payload: String, header: String) -> String

@external(erlang, "provider_test_ffi", "jwks")
fn jwks() -> String

@external(erlang, "howdy_auth_sso_ffi", "public_host")
fn public_host(host: String) -> Bool

@external(erlang, "howdy_auth_test_ffi", "with_pinned_idp")
fn with_pinned_idp(
  host: String,
  body: String,
  run: fn() -> a,
) -> #(a, #(String, String))

fn discovery(changes: List(#(String, json.Json))) -> String {
  [
    #("issuer", json.string(issuer)),
    #("authorization_endpoint", json.string(issuer <> "/authorize")),
    #("token_endpoint", json.string(issuer <> "/token")),
    #("jwks_uri", json.string(issuer <> "/keys")),
    #(
      "token_endpoint_auth_methods_supported",
      json.array(["client_secret_basic", "client_secret_post"], json.string),
    ),
  ]
  |> list.fold(changes, _, fn(fields, change) {
    list.key_set(fields, change.0, change.1)
  })
  |> json.object
  |> json.to_string
}

/// The customer's provider. The authorization code is the ID token to return.
fn idp(metadata: String) {
  fn(req: Request(String)) {
    assert req.scheme == http.Https
    assert req.host == "acme.okta.example"
    case req.path {
      "/.well-known/openid-configuration" ->
        Ok(response.new(200) |> response.set_body(metadata))
      "/token" -> {
        assert req.method == http.Post
        let assert Ok(fields) = uri.parse_query(req.body)
        // The provider accepts only the method its metadata advertises.
        let header = request.get_header(req, "authorization")
        let posts =
          string.contains(metadata, "\"token_endpoint_auth_methods_supported\"")
          && string.contains(metadata, "client_secret_post")
        assert result.is_ok(header) == !posts
        case header {
          Ok(basic) -> {
            let credentials =
              bit_array.base64_encode(<<"client:hunter2":utf8>>, True)
            assert basic == "Basic " <> credentials
            assert list.key_find(fields, "client_secret") == Error(Nil)
          }
          Error(Nil) -> {
            assert list.key_find(fields, "client_id") == Ok("client")
            assert list.key_find(fields, "client_secret") == Ok("hunter2")
          }
        }
        let assert Ok(verifier) = list.key_find(fields, "code_verifier")
        assert string.byte_size(verifier) == 43
        let assert Ok(code) = list.key_find(fields, "code")
        Ok(
          response.new(200)
          |> response.set_body(
            json.to_string(json.object([#("id_token", json.string(code))])),
          ),
        )
      }
      "/keys" -> Ok(response.new(200) |> response.set_body(jwks()))
      _ -> panic as "unexpected provider request"
    }
  }
}

fn with_sso(identity: auth.Auth, metadata: String) -> auth.Auth {
  let assert Ok(config) = connection.config(token.new())
  auth.with_sso(identity, connection.with_transport(config, idp(metadata)))
}

fn connect(identity: auth.Auth, id: String, group_id: String, domains) {
  let assert Ok(created) =
    connections.create_with_id(
      identity,
      id:,
      group: group_id,
      name: id,
      protocol: connection.oidc(issuer, "client", "hunter2"),
      domains:,
      by: user.System,
    )
  created
}

/// Default group, one connection `acme` believed about acme.com.
fn acme(run: fn(Repo, auth.Auth, process.Subject(auth.Delivery)) -> a) -> a {
  use database, identity, _, mailbox <- fixture
  let identity = with_sso(identity, discovery([]))
  connect(identity, "acme", group.default_id, ["acme.com"])
  run(database, identity, mailbox)
}

fn parameter(url: String, name: String) -> String {
  let assert Ok(url) = uri.parse(url)
  let assert Some(query) = url.query
  let assert Ok(fields) = uri.parse_query(query)
  let assert Ok(value) = list.key_find(fields, name)
  value
}

fn signed(url: String, changes: List(#(String, json.Json))) -> String {
  [
    #("iss", json.string(issuer)),
    #("sub", json.string("00u-ada")),
    #("aud", json.string("client")),
    #("exp", json.int(token.now() + 3600)),
    #("iat", json.int(token.now())),
    #("nonce", json.string(parameter(url, "nonce"))),
    #("email", json.string("Ada@Acme.com")),
  ]
  |> list.fold(changes, _, fn(fields, change) {
    list.key_set(fields, change.0, change.1)
  })
  |> json.object
  |> json.to_string
  |> sign(header)
}

fn begin(identity: auth.Auth, id: String) -> auth.ProviderStart {
  let assert Ok(start) =
    auth.begin_sso(
      identity,
      id,
      "/auth/sso/" <> id <> "/callback",
      "client-one",
    )
  start
}

fn finish(identity, id, start: auth.ProviderStart, changes, principal) {
  auth.finish_sso(
    identity,
    id,
    "/auth/sso/" <> id <> "/callback",
    parameter(start.url, "state"),
    secret_of(start),
    Some(signed(start.url, changes)),
    principal,
  )
}

fn secret_of(start: auth.ProviderStart) -> String {
  secret.reveal(start.browser_token)
}

fn principal_of(identity: auth.Auth, session: auth.Session) {
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  principal
}

pub fn a_first_sign_in_provisions_the_user_without_public_registration_test() {
  use database, _, _, _ <- fixture
  // Never `allow_registration`: the connection is what lets its users in.
  let assert Ok(closed) =
    auth.new(database, "https://example.test", fn(_) { Ok(Nil) })
  let identity = with_sso(closed, discovery([])) |> auth.in_locale("de")
  connect(identity, "acme", group.default_id, ["acme.com"])
  let start = begin(identity, "acme")
  assert string.starts_with(start.url, issuer <> "/authorize?")
  assert parameter(start.url, "client_id") == "client"
  assert parameter(start.url, "redirect_uri")
    == "https://example.test" <> callback
  assert parameter(start.url, "code_challenge_method") == "S256"
  let assert Ok(auth.ProviderSession(session)) =
    finish(identity, "acme", start, [], None)
  assert session.user.email == "ada@acme.com"
  assert session.user.group_id == group.default_id
  assert principal_of(identity, session).user.locale == Some("de")
  let assert Ok([info]) =
    auth.sessions(identity, principal_of(identity, session))
  assert info.method == auth.Provider("sso:acme")
  // The same subject signs in to the same account, and the attempt is spent.
  let again = begin(identity, "acme")
  let assert Ok(auth.ProviderSession(second)) =
    finish(
      identity,
      "acme",
      again,
      [#("email", json.string("new@acme.com"))],
      None,
    )
  assert second.user.id == session.user.id
  let assert Error(service.Unauthorized) =
    finish(identity, "acme", again, [], None)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 1
}

pub fn an_address_is_believed_only_inside_the_connections_domains_test() {
  use database, identity, _ <- acme
  let refused = fn(changes) {
    let assert Error(service.Forbidden) =
      finish(identity, "acme", begin(identity, "acme"), changes, None)
    Nil
  }
  refused([#("email", json.string("ada@globex.com"))])
  refused([#("email", json.string("ada@acme.com.evil.test"))])
  refused([#("email", json.string("ada@evil.test@acme.com"))])
  refused([#("email", json.null())])
  refused([#("email_verified", json.bool(False))])
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 0
}

pub fn a_covered_members_existing_account_is_taken_up_test() {
  use database, identity, mailbox <- acme
  let local = signup(identity, mailbox, "ada@acme.com")
  let assert Ok(auth.ProviderSession(session)) =
    finish(identity, "acme", begin(identity, "acme"), [], None)
  assert session.user.id == local.user.id
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 1
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'provider.linked' AND detail = 'sso:acme' AND actor_id = ''",
    )
    == 1
  // The account now answers to that subject alone: another person at the
  // provider asserting the same address does not get it too.
  let assert Error(service.Coded(_, service.Conflict(_))) =
    finish(
      identity,
      "acme",
      begin(identity, "acme"),
      [#("sub", json.string("00u-someone-else"))],
      None,
    )
  // A suspended account is not revived by its provider.
  let assert Ok(Nil) = auth.suspend(identity, local.user.id, by: user.System)
  let assert Error(service.Unauthorized) =
    finish(identity, "acme", begin(identity, "acme"), [], None)
}

pub fn an_account_outside_the_domains_links_deliberately_test() {
  use database, identity, mailbox <- acme
  let guest = signup(identity, mailbox, "bob@contractor.test")
  let as_bob = [
    #("sub", json.string("00u-bob")),
    #("email", json.string("bob@contractor.test")),
  ]
  let assert Error(service.Forbidden) =
    finish(identity, "acme", begin(identity, "acme"), as_bob, None)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_provider_identities")
    == 0
  let principal = principal_of(identity, guest)
  let assert Ok(start) =
    auth.begin_sso_link(identity, principal, "acme", callback)
  // The link needs the session that began it.
  let assert Error(service.Unauthorized) =
    finish(identity, "acme", start, as_bob, None)
  let assert Ok(start) =
    auth.begin_sso_link(identity, principal, "acme", callback)
  let assert Ok(auth.ProviderLinked) =
    finish(identity, "acme", start, as_bob, Some(principal))
  assert auth.linked_providers(identity, principal)
    |> result_map_ids
    == ["sso:acme"]
  let assert Ok(auth.ProviderSession(session)) =
    finish(identity, "acme", begin(identity, "acme"), as_bob, None)
  assert session.user.id == guest.user.id
}

pub fn an_account_in_another_group_is_never_taken_up_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_groups(identity, group.OneGroupPerUser)
  let identity = with_sso(identity, discovery([]))
  let assert Ok(_) =
    groups.create_with_id(identity, id: "acme", name: "Acme", by: user.System)
  let assert Ok(_) =
    groups.create_with_id(identity, id: "other", name: "Other", by: user.System)
  connect(identity, "acme", "acme", ["acme.com"])
  let elsewhere =
    signup(auth.in_group(identity, "other"), mailbox, "ada@acme.com")
  assert elsewhere.user.group_id == "other"
  let assert Error(service.Unauthorized) =
    finish(identity, "acme", begin(identity, "acme"), [], None)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_provider_identities")
    == 0
}

fn result_map_ids(found) {
  let assert Ok(links) = found
  list.map(links, fn(link: #(String, String)) { link.0 })
}

pub fn token_claims_are_verified_test() {
  use _, identity, _ <- acme
  let refused = fn(changes) {
    let assert Error(service.Unauthorized) =
      finish(identity, "acme", begin(identity, "acme"), changes, None)
    Nil
  }
  refused([#("iss", json.string("https://globex.okta.example"))])
  refused([#("aud", json.string("another-client"))])
  refused([#("aud", json.array(["client", "other"], json.string))])
  refused([
    #("aud", json.array(["client", "other"], json.string)),
    #("azp", json.string("other")),
  ])
  refused([#("azp", json.string("other"))])
  refused([#("nonce", json.string("someone-elses-nonce"))])
  refused([#("exp", json.int(token.now() - 1))])
  refused([#("iat", json.int(token.now() + 600))])
  refused([#("nbf", json.int(token.now() + 600))])
  refused([#("sub", json.string(""))])
  let start = begin(identity, "acme")
  let assert Ok(auth.ProviderSession(_)) =
    finish(
      identity,
      "acme",
      start,
      [
        #("aud", json.array(["client", "other"], json.string)),
        #("azp", json.string("client")),
      ],
      None,
    )
  // An unsigned or differently signed token never reaches the claims.
  let start = begin(identity, "acme")
  let assert Error(service.Unauthorized) =
    auth.finish_sso(
      identity,
      "acme",
      callback,
      parameter(start.url, "state"),
      secret_of(start),
      Some(sign("{}", "{\"alg\":\"none\",\"kid\":\"test-key\"}")),
      None,
    )
  // Cancelled consent spends the attempt.
  let start = begin(identity, "acme")
  let assert Error(service.Unauthorized) =
    auth.finish_sso(
      identity,
      "acme",
      callback,
      parameter(start.url, "state"),
      secret_of(start),
      None,
      None,
    )
  let assert Error(service.Unauthorized) =
    finish(identity, "acme", start, [], None)
}

pub fn discovery_is_pinned_to_the_configured_issuer_test() {
  use _, identity, _, _ <- fixture
  let refused = fn(changes) {
    let identity = with_sso(identity, discovery(changes))
    connect(identity, "acme", group.default_id, ["acme.com"])
    let assert Error(service.Unauthorized) =
      auth.begin_sso(identity, "acme", callback, "")
    let assert Ok(Nil) = connections.delete(identity, "acme", by: user.System)
    Nil
  }
  refused([#("issuer", json.string("https://evil.test"))])
  refused([#("issuer", json.string(issuer <> "/"))])
  refused([#("token_endpoint", json.string("http://acme.okta.example/token"))])
  refused([#("jwks_uri", json.string("file:///etc/passwd"))])
  refused([
    #("authorization_endpoint", json.string("javascript:alert(1)")),
  ])
}

pub fn the_client_authenticates_as_the_provider_supports_test() {
  use _, identity, _, _ <- fixture
  // No `client_secret_post`, and then no list at all: both mean Basic, which
  // the provider played here asserts on.
  let methods = "token_endpoint_auth_methods_supported"
  list.each(
    [
      #(
        "basic",
        discovery([#(methods, json.array(["client_secret_basic"], json.string))]),
      ),
      #("absent", string.replace(discovery([]), methods, "ignored")),
    ],
    fn(provider) {
      let #(who, metadata) = provider
      let identity = with_sso(identity, metadata)
      connect(identity, "acme", group.default_id, ["acme.com"])
      let assert Ok(auth.ProviderSession(_)) =
        finish(
          identity,
          "acme",
          begin(identity, "acme"),
          [
            #("sub", json.string(who)),
            #("email", json.string(who <> "@acme.com")),
          ],
          None,
        )
      let assert Ok(Nil) = connections.delete(identity, "acme", by: user.System)
    },
  )
}

pub fn connections_cannot_reach_into_each_other_test() {
  use database, identity, _, _ <- fixture
  let assert Ok(identity) = auth.with_groups(identity, group.OneGroupPerUser)
  let identity = with_sso(identity, discovery([]))
  let assert Ok(_) =
    groups.create_with_id(identity, id: "acme", name: "Acme", by: user.System)
  let assert Ok(_) =
    groups.create_with_id(
      identity,
      id: "globex",
      name: "Globex",
      by: user.System,
    )
  connect(identity, "acme", "acme", ["acme.com"])
  connect(identity, "globex", "globex", ["globex.com"])
  let assert Ok(auth.ProviderSession(ada)) =
    finish(identity, "acme", begin(identity, "acme"), [], None)
  assert ada.user.group_id == "acme"
  // Globex's provider asserts Acme's address, then Acme's subject.
  let assert Error(service.Forbidden) =
    finish(identity, "globex", begin(identity, "globex"), [], None)
  let assert Ok(auth.ProviderSession(other)) =
    finish(
      identity,
      "globex",
      begin(identity, "globex"),
      [#("email", json.string("eve@globex.com"))],
      None,
    )
  assert other.user.id != ada.user.id
  assert other.user.group_id == "globex"
  // An attempt begun at one connection cannot finish at another.
  let start = begin(identity, "acme")
  let assert Error(service.Unauthorized) =
    auth.finish_sso(
      identity,
      "globex",
      "/auth/sso/globex/callback",
      parameter(start.url, "state"),
      secret_of(start),
      Some(signed(start.url, [])),
      None,
    )
  // Bound to another group, the connection is out of reach.
  let assert Error(service.Unauthorized) =
    auth.begin_sso(auth.in_group(identity, "globex"), "acme", callback, "")
  // A member of one group cannot link to another group's connection.
  let assert Error(service.Forbidden) =
    auth.begin_sso_link(
      identity,
      principal_of(identity, other),
      "acme",
      callback,
    )
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 2
}

pub fn a_disabled_or_deleted_connection_stops_signing_in_test() {
  use _, identity, _ <- acme
  let assert Ok(auth.ProviderSession(session)) =
    finish(identity, "acme", begin(identity, "acme"), [], None)
  let waiting = begin(identity, "acme")
  let assert Ok(_) = connections.disable(identity, "acme", by: user.System)
  let assert Error(service.NotFound(_)) =
    auth.begin_sso(identity, "acme", callback, "")
  let assert Error(service.NotFound(_)) =
    finish(identity, "acme", waiting, [], None)
  assert auth.sso_for_email(identity, "ada@acme.com") == Ok(None)
  // The session lives on, but proves nothing for sensitive operations.
  let principal = principal_of(identity, session)
  let assert Error(service.Forbidden) =
    auth.unlink_provider(identity, principal, "sso:acme")
  let assert Ok(_) = connections.enable(identity, "acme", by: user.System)
  assert auth.sso_for_email(identity, " Ada@ACME.com ") == Ok(Some("acme"))
  assert auth.sso_for_email(identity, "ada@globex.com") == Ok(None)
  let assert Error(service.NotFound(_)) =
    auth.begin_sso(identity, "missing", "/auth/sso/missing/callback", "")
}

pub fn pointing_a_connection_at_another_provider_forgets_its_identities_test() {
  use database, identity, _ <- acme
  let assert Ok(auth.ProviderSession(_)) =
    finish(identity, "acme", begin(identity, "acme"), [], None)
  let identities = fn() {
    count(database, "SELECT COUNT(*) FROM howdy_auth_provider_identities")
  }
  let assert Ok(_) =
    connections.set_protocol(
      identity,
      "acme",
      to: connection.oidc(issuer, "client", "rotated-secret"),
      by: user.System,
    )
  assert identities() == 1
  let assert Ok(_) =
    connections.set_protocol(
      identity,
      "acme",
      to: connection.oidc("https://acme.entra.example", "client", "hunter2"),
      by: user.System,
    )
  assert identities() == 0
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 1
}

pub fn sso_is_refused_until_enabled_test() {
  use _, identity, _, _ <- fixture
  let assert Error(service.Forbidden) =
    auth.begin_sso(identity, "acme", callback, "")
  assert auth.sso_for_email(identity, "ada@acme.com")
    == Error(service.Forbidden)
}

pub fn only_public_addresses_are_fetched_test() {
  list.each(
    [
      "127.0.0.1", "localhost", "10.1.2.3", "172.16.0.1", "192.168.1.1",
      "169.254.169.254", "100.64.0.1", "0.0.0.0", "224.0.0.1", "::1",
      "::ffff:127.0.0.1", "::ffff:10.0.0.1", "64:ff9b::a00:1", "fe80::1",
      "fd00::1", "2001:db8::1", "", "does-not-resolve.invalid",
    ],
    fn(host) {
      assert !public_host(host) as host
    },
  )
  assert public_host("8.8.8.8")
  assert public_host("2606:4700:4700::1111")
}

fn provider_request(host: String) -> Request(String) {
  request.new()
  |> request.set_scheme(http.Https)
  |> request.set_host(host)
  |> request.set_path("/keys")
}

pub fn names_resolving_to_private_addresses_are_never_requested_test() {
  list.each(["localhost", "127.0.0.1", "169.254.169.254", "::1"], fn(host) {
    assert sso_transport.send(provider_request(host))
      == Error(service.Internal("SSO provider request failed"))
      as host
  })
}

/// The name is resolved once: the connection goes to the vetted address,
/// while the name itself travels as the Host header and the TLS server name
/// the certificate is checked against.
pub fn provider_requests_connect_to_the_vetted_address_test() {
  let host = "idp.example.test"
  let #(answer, #(sni, head)) =
    with_pinned_idp(host, "{\"keys\":[]}", fn() {
      sso_transport.send(provider_request(host))
    })
  let assert Ok(res) = answer
  assert res.status == 200
  assert res.body == "{\"keys\":[]}"
  assert sni == host
  let head = string.lowercase(head)
  assert string.starts_with(head, "get /keys http/1.1\r\n")
  assert string.contains(head, "\r\nhost: " <> host <> "\r\n")
  assert !string.contains(head, "127.0.0.1")
}

pub fn browser_routes_test() {
  use _, identity, _ <- acme
  let identity =
    auth.with_locales(
      identity,
      locale.negotiator(["en", "de"], default: "en")
        |> locale.from_accept_language,
    )
  let app =
    howdy.new()
    |> howdy.controller(routes.sso(
      identity,
      at: "/auth",
      success_path: "/account",
      failure_path: "/login",
    ))
    |> howdy.controller(routes.api(identity, at: "/api/auth"))
  let rejected =
    testing.post_form("/auth/sso/login", [#("email", "ada@acme.com")])
    |> testing.send(app)
  assert rejected.status == 403
  let rejected =
    testing.post_form("/auth/sso/acme/login", [])
    |> testing.header("origin", "https://attacker.test")
    |> testing.send(app)
  assert rejected.status == 403
  let unknown =
    testing.post_form("/auth/sso/login", [#("email", "ada@globex.com")])
    |> testing.header("origin", "https://example.test")
    |> testing.send(app)
  assert response.get_header(unknown, "location") == Ok("/login")
  assert testing.cookies(unknown) == []
  let started =
    testing.post_form("/auth/sso/login", [#("email", "ada@acme.com")])
    |> testing.header("origin", "https://example.test")
    |> testing.send(app)
  assert started.status == 303
  assert response.get_header(started, "cache-control") == Ok("no-store")
  let assert Ok(location) = response.get_header(started, "location")
  assert string.starts_with(location, issuer <> "/authorize?")
  let assert Ok(browser) =
    list.key_find(testing.cookies(started), "__Host-howdy_sso_acme")
  let callback_url =
    callback
    <> "?"
    <> uri.query_to_string([
      #("state", parameter(location, "state")),
      #("code", signed(location, [])),
    ])
  // Another browser, holding the URL but not the cookie, gets nowhere.
  let stolen = testing.get(callback_url) |> testing.send(app)
  assert response.get_header(stolen, "location") == Ok("/login")
  let started =
    testing.post_form("/auth/sso/acme/login", [])
    |> testing.header("origin", "https://example.test")
    |> testing.send(app)
  let assert Ok(location) = response.get_header(started, "location")
  let cookie_name = "__Host-howdy_sso_acme"
  let assert Ok(browser_two) =
    list.key_find(testing.cookies(started), cookie_name)
  assert browser_two != browser
  let callback_url =
    callback
    <> "?"
    <> uri.query_to_string([
      #("state", parameter(location, "state")),
      #("code", signed(location, [])),
    ])
  let completed =
    testing.get(callback_url)
    |> testing.cookie(cookie_name, browser_two)
    |> testing.header("accept-language", "de-CH, en;q=0.5")
    |> testing.send(app)
  assert response.get_header(completed, "location") == Ok("/account")
  let assert Ok(session) =
    list.key_find(testing.cookies(completed), auth.cookie_name(identity))
  let assert Ok(principal) = auth.authenticate(identity, session)
  assert principal.user.locale == Some("de")
  let me =
    testing.get("/api/auth/me")
    |> testing.cookie(auth.cookie_name(identity), session)
    |> testing.send(app)
  assert me.status == 200
  let replay =
    testing.get(callback_url)
    |> testing.cookie(cookie_name, browser_two)
    |> testing.send(app)
  assert response.get_header(replay, "location") == Ok("/login")
  let missing =
    testing.post_form("/auth/sso/nope/login", [])
    |> testing.header("origin", "https://example.test")
    |> testing.send(app)
  assert missing.status == 404
}

// --- Enforcement -------------------------------------------------------------

const password = "an uncommon orchard phrase 947!"

fn password_signup(
  identity: auth.Auth,
  mailbox: process.Subject(auth.Delivery),
  email: String,
) -> auth.Session {
  let assert Ok(Nil) = auth.register_password(identity, email, password)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let assert Ok(session) =
    auth.exchange(identity, secret.reveal(delivery.token))
  session
}

fn live(identity: auth.Auth, session: auth.Session) -> Bool {
  result.is_ok(auth.authenticate(identity, secret.reveal(session.token)))
}

fn nothing_sent(mailbox: process.Subject(auth.Delivery)) -> Bool {
  process.receive(mailbox, 50) == Error(Nil)
}

pub fn covered_members_sign_in_only_through_an_enforced_connection_test() {
  use _, identity, mailbox <- acme
  let assert Ok(identity) = auth.with_passwords(identity)
  let ada = password_signup(identity, mailbox, "ada@acme.com")
  let guest = password_signup(identity, mailbox, "bob@contractor.test")
  let assert Ok(enforced) =
    connections.enforce(identity, "acme", by: user.System)
  assert enforced.enforced
  assert string.contains(
    json.to_string(connection.to_json(enforced)),
    "\"enforced\":true",
  )
  // Covered members are signed out; a guest outside the domains is untouched.
  assert !live(identity, ada)
  assert live(identity, guest)
  let assert Ok(_) =
    auth.login_password(identity, "bob@contractor.test", password)
  // The right password is refused exactly as a wrong one is.
  assert auth.login_password(identity, "ada@acme.com", password)
    == auth.login_password(identity, "ada@acme.com", "not the password at all")
  let assert Error(service.Unauthorized) =
    auth.login_password(identity, "ada@acme.com", password)
  // Tokens that could never be redeemed are not sent, to members or to new
  // addresses that would be covered; the reply does not change.
  assert auth.request_token(identity, "ada@acme.com", auth.Login) == Ok(Nil)
  assert auth.request_token(identity, "carol@acme.com", auth.Register)
    == Ok(Nil)
  assert nothing_sent(mailbox)
  // Through the connection, the existing account is taken up and signed in.
  let assert Ok(auth.ProviderSession(session)) =
    finish(identity, "acme", begin(identity, "acme"), [], None)
  assert session.user.id == ada.user.id
  assert live(identity, session)
  // Enforcement lapses with the connection, and ends when told to.
  let assert Ok(_) = connections.disable(identity, "acme", by: user.System)
  let assert Ok(_) = auth.login_password(identity, "ada@acme.com", password)
  let assert Ok(_) = connections.enable(identity, "acme", by: user.System)
  let assert Error(service.Unauthorized) =
    auth.login_password(identity, "ada@acme.com", password)
  let assert Ok(relaxed) =
    connections.stop_enforcing(identity, "acme", by: user.System)
  assert !relaxed.enforced
  let assert Ok(_) = auth.login_password(identity, "ada@acme.com", password)
}

pub fn a_token_from_before_enforcement_is_not_redeemed_after_it_test() {
  use database, identity, mailbox <- acme
  let _ = signup(identity, mailbox, "ada@acme.com")
  let assert Ok(Nil) = auth.request_token(identity, "ada@acme.com", auth.Login)
  let assert Ok(login) = process.receive(mailbox, 1000)
  let assert Ok(Nil) =
    auth.request_token(identity, "carol@acme.com", auth.Register)
  let assert Ok(registration) = process.receive(mailbox, 1000)
  let assert Ok(_) = connections.enforce(identity, "acme", by: user.System)
  let assert Error(service.Unauthorized) =
    auth.exchange(identity, secret.reveal(login.token))
  // The refused registration leaves no account behind.
  let assert Error(service.Unauthorized) =
    auth.exchange(identity, secret.reveal(registration.token))
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 1
}

pub fn enforcement_follows_the_connections_domains_and_group_test() {
  use _, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_groups(identity, group.OneGroupPerUser)
  let identity = with_sso(identity, discovery([]))
  let assert Ok(_) =
    groups.create_with_id(identity, id: "acme", name: "Acme", by: user.System)
  let assert Ok(_) =
    groups.create_with_id(identity, id: "other", name: "Other", by: user.System)
  connect(identity, "empty", "acme", [])
  let assert Error(service.Invalid(_)) =
    connections.enforce(identity, "empty", by: user.System)
  connect(identity, "acme", "acme", ["acme.com"])
  let assert Ok(_) = connections.enforce(identity, "acme", by: user.System)
  // The same domain in another group is not the connection's to govern.
  let elsewhere =
    signup(auth.in_group(identity, "other"), mailbox, "ada@acme.com")
  assert live(identity, elsewhere)
  let assert Ok(Nil) = auth.request_token(identity, "ada@acme.com", auth.Login)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let assert Ok(_) = auth.exchange(identity, secret.reveal(delivery.token))
  // A domain added to an enforced connection signs out those it now covers.
  let partner =
    signup(auth.in_group(identity, "acme"), mailbox, "eve@partner.test")
  assert live(identity, partner)
  let assert Ok(_) =
    connections.set_domains(
      identity,
      "acme",
      to: ["acme.com", "partner.test"],
      by: user.System,
    )
  assert !live(identity, partner)
  assert live(identity, elsewhere)
  assert auth.request_token(identity, "eve@partner.test", auth.Login) == Ok(Nil)
  assert nothing_sent(mailbox)
}

// --- Second factors ----------------------------------------------------------

@external(erlang, "howdy_auth_test_ffi", "totp_code")
fn totp_code(seed: String, seconds: Int) -> String

fn with_mfa(identity: auth.Auth) -> auth.Auth {
  let assert Ok(config) = mfa.new("Howdy tests", token.new())
  auth.with_mfa(identity, config)
}

/// Enrol TOTP on the session's account; the recovery codes.
fn enroll(identity: auth.Auth, session: auth.Session) -> List(secret.Secret) {
  let principal = principal_of(identity, session)
  let assert Ok(setup) = auth.begin_mfa(identity, principal, auth.Totp)
  let assert Some(key) = setup.key
  let assert Ok(codes) =
    auth.confirm_mfa(
      identity,
      principal,
      secret.reveal(setup.challenge),
      totp_code(secret.reveal(key), token.now()),
    )
  codes
}

pub fn howdys_second_factor_follows_the_provider_unless_it_is_trusted_test() {
  use database, identity, _ <- acme
  let identity = with_mfa(identity)
  let assert Ok(auth.ProviderSession(first)) =
    finish(identity, "acme", begin(identity, "acme"), [], None)
  let assert [code, ..] = enroll(identity, first)
  let trusted_events = fn() {
    count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'mfa.provider_trusted' AND detail = 'sso:acme'",
    )
  }
  // By default the provider is the first factor and Howdy's is still asked.
  let assert Ok(auth.ProviderSecondFactor(challenge)) =
    finish(identity, "acme", begin(identity, "acme"), [], None)
  let assert Ok(completed) =
    auth.verify_mfa(
      identity,
      secret.reveal(challenge.token),
      auth.RecoveryCode,
      secret.reveal(code),
      False,
    )
  let proven = principal_of(identity, completed.session)
  assert trusted_events() == 0
  let assert Ok(trusting) =
    connections.trust_provider_mfa(identity, "acme", by: user.System)
  assert trusting.trusts_provider_mfa
  let assert Ok(auth.ProviderSession(session)) =
    finish(identity, "acme", begin(identity, "acme"), [], None)
  assert session.user.id == first.user.id
  assert trusted_events() == 1
  // The factor was skipped, not proven: this session cannot manage it, and
  // the one that did prove it still can.
  let skipped = principal_of(identity, session)
  let assert Error(service.Forbidden) =
    auth.regenerate_recovery_codes(identity, skipped)
  let assert Error(service.Forbidden) = auth.disable_mfa(identity, skipped)
  let assert Ok(_) = auth.regenerate_recovery_codes(identity, proven)
  // A member without a factor is simply signed in, and nothing is recorded.
  let assert Ok(auth.ProviderSession(_)) =
    finish(
      identity,
      "acme",
      begin(identity, "acme"),
      [
        #("sub", json.string("00u-grace")),
        #("email", json.string("grace@acme.com")),
      ],
      None,
    )
  assert trusted_events() == 1
  let assert Ok(asking) =
    connections.require_local_mfa(identity, "acme", by: user.System)
  assert !asking.trusts_provider_mfa
  let assert Ok(auth.ProviderSecondFactor(_)) =
    finish(identity, "acme", begin(identity, "acme"), [], None)
}

pub fn trusting_one_connection_changes_no_other_way_in_test() {
  use _, identity, mailbox <- acme
  let identity = with_mfa(identity)
  let local = signup(identity, mailbox, "ada@acme.com")
  let _ = enroll(identity, local)
  let assert Ok(_) =
    connections.trust_provider_mfa(identity, "acme", by: user.System)
  let assert Ok(Nil) = auth.request_token(identity, "ada@acme.com", auth.Login)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let assert Ok(auth.SecondFactor(_)) =
    auth.exchange_step(identity, secret.reveal(delivery.token), "test")
}

pub fn a_covered_member_with_a_factor_completes_sign_in_under_enforcement_test() {
  use _, identity, mailbox <- acme
  let identity = with_mfa(identity)
  let local = signup(identity, mailbox, "ada@acme.com")
  let assert [code, ..] = enroll(identity, local)
  let assert Ok(_) = connections.enforce(identity, "acme", by: user.System)
  let assert Ok(auth.ProviderSecondFactor(challenge)) =
    finish(identity, "acme", begin(identity, "acme"), [], None)
  let assert Ok(completed) =
    auth.verify_mfa(
      identity,
      secret.reveal(challenge.token),
      auth.RecoveryCode,
      secret.reveal(code),
      False,
    )
  assert completed.session.user.id == local.user.id
  assert live(identity, completed.session)
}
