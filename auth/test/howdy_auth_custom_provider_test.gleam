//// Providers built outside the package: `provider.custom`, and the generic
//// `providers/oidc` over real RSA signatures on synthetic ID tokens.

import gleam/dynamic/decode
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri
import gloo/repo
import howdy/auth
import howdy/auth/internal/token
import howdy/auth/provider
import howdy/auth/providers/oidc
import howdy/auth/secret
import howdy/service
import support.{count, fixture, signup}

const callback = "/auth/providers/corp/callback"

fn parameter(url: String, name: String) -> String {
  let assert Ok(url) = uri.parse(url)
  let assert Some(query) = url.query
  let assert Ok(fields) = uri.parse_query(query)
  let assert Ok(value) = list.key_find(fields, name)
  value
}

fn begin(identity: auth.Auth) -> auth.ProviderStart {
  let assert Ok(start) =
    auth.begin_provider(identity, "corp", callback, "client-one")
  start
}

fn finish(identity, start: auth.ProviderStart, code: String) {
  auth.finish_provider(
    identity,
    "corp",
    callback,
    parameter(start.url, "state"),
    secret.reveal(start.browser_token),
    Some(code),
    None,
  )
}

// -- custom ------------------------------------------------------------------

/// A provider whose "code" is `nonce|subject|email|authoritative`, so each
/// test chooses what it returns. It checks the nonce as an OIDC one would.
fn corp(issuer: String) -> provider.Provider {
  provider.custom(
    id: "corp",
    name: "Corp",
    issuer:,
    authorize: fn(request) {
      "https://corp.test/authorize?"
      <> uri.query_to_string([
        #("redirect_uri", request.redirect_uri),
        #("state", request.state),
        #("nonce", request.nonce),
        #("code_challenge", request.challenge),
      ])
    },
    verify: fn(exchange) {
      let assert [nonce, subject, email, authoritative] =
        string.split(secret.reveal(exchange.code), "|")
      assert exchange.redirect_uri == "https://example.test" <> callback
      assert string.byte_size(secret.reveal(exchange.verifier)) == 43
      case provider.nonce_matches(exchange, nonce) {
        True -> Ok(provider.Verified(subject, email, authoritative == "yes"))
        False -> Error(service.Unauthorized)
      }
    },
  )
}

fn code(start: auth.ProviderStart, subject, email, authoritative) -> String {
  string.join(
    [parameter(start.url, "nonce"), subject, email, authoritative],
    "|",
  )
}

pub fn a_custom_provider_signs_in_through_the_shared_runtime_test() {
  use database, identity, _, _ <- fixture
  let assert Ok(identity) =
    auth.with_provider(identity, corp("https://corp.test"))
  assert auth.providers(identity) == [#("corp", "Corp")]
  let start = begin(identity)
  assert string.starts_with(start.url, "https://corp.test/authorize?")
  assert parameter(start.url, "redirect_uri")
    == "https://example.test" <> callback
  let assert Ok(auth.ProviderSession(session)) =
    finish(identity, start, code(start, "u-1", "ada@corp.test", "yes"))
  assert session.user.email == "ada@corp.test"
  // The same subject returns to the same account; the attempt is spent.
  let again = begin(identity)
  let assert Ok(auth.ProviderSession(second)) =
    finish(identity, again, code(again, "u-1", "renamed@corp.test", "no"))
  assert second.user.id == session.user.id
  let assert Error(service.Unauthorized) =
    finish(identity, again, code(again, "u-1", "ada@corp.test", "yes"))
  // A wrong nonce, an error or an empty subject signs nobody in.
  let third = begin(identity)
  let assert Error(service.Unauthorized) =
    finish(identity, third, "wrong|u-1|ada@corp.test|yes")
  let fourth = begin(identity)
  let assert Error(service.Unauthorized) =
    finish(identity, fourth, code(fourth, "", "x@corp.test", "yes"))
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 1
}

pub fn custom_accounts_are_kept_apart_from_every_other_issuer_test() {
  use database, identity, _, _ <- fixture
  // Even claiming Google's issuer cannot reach Google's linked accounts.
  let assert Ok(identity) =
    auth.with_provider(identity, corp("https://accounts.google.com"))
  let start = begin(identity)
  let assert Ok(auth.ProviderSession(_)) =
    finish(identity, start, code(start, "42", "ada@corp.test", "yes"))
  let assert Ok(issuers) =
    repo.all(
      database,
      "SELECT issuer FROM howdy_auth_provider_identities",
      [],
      decode.field(0, decode.string, decode.success),
    )
  assert issuers == ["custom:https://accounts.google.com"]
}

pub fn an_unauthoritative_address_never_takes_an_account_test() {
  use database, identity, _, mailbox <- fixture
  let existing = signup(identity, mailbox, "ada@corp.test")
  let assert Ok(identity) =
    auth.with_provider(identity, corp("https://corp.test"))
  // Neither a new account from an address the provider does not own...
  let start = begin(identity)
  let assert Error(service.Forbidden) =
    finish(identity, start, code(start, "u-2", "new@corp.test", "no"))
  // ...nor someone else's account because the addresses match.
  let again = begin(identity)
  let assert Error(service.Unauthorized) =
    finish(identity, again, code(again, "u-3", "ada@corp.test", "yes"))
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 1
  assert existing.user.email == "ada@corp.test"
}

pub fn custom_providers_are_validated_when_installed_test() {
  use _, identity, _, _ <- fixture
  let invalid = fn(provider) {
    case auth.with_provider(identity, provider) {
      Error(service.Invalid(_)) -> True
      _ -> False
    }
  }
  let make = fn(id, name, issuer) {
    provider.custom(id:, name:, issuer:, authorize: fn(_) { "" }, verify: fn(_) {
      Error(service.Unauthorized)
    })
  }
  assert invalid(make("Corp", "Corp", "https://corp.test"))
  assert invalid(make("corp/x", "Corp", "https://corp.test"))
  assert invalid(make(string.repeat("a", 33), "Corp", "https://corp.test"))
  assert invalid(make("corp", " ", "https://corp.test"))
  assert invalid(make("corp", "Corp", "http://corp.test"))
  assert invalid(make("corp", "Corp", "https://corp.test?tenant=1"))
  let assert Ok(one) = auth.with_provider(identity, corp("https://corp.test"))
  // Two providers may share neither an id nor an issuer.
  assert auth.with_provider(one, make("corp", "Other", "https://other.test"))
    |> is_invalid
  assert auth.with_provider(one, make("other", "Other", "https://corp.test"))
    |> is_invalid
}

fn is_invalid(result) -> Bool {
  case result {
    Error(service.Invalid(_)) -> True
    _ -> False
  }
}

// -- generic OpenID Connect --------------------------------------------------

const issuer = "https://id.corp.test"

const header = "{\"alg\":\"RS256\",\"kid\":\"test-key\"}"

@external(erlang, "provider_test_ffi", "sign")
fn sign(payload: String, header: String) -> String

@external(erlang, "provider_test_ffi", "jwks")
fn jwks() -> String

/// The provider: discovery, keys, and a token endpoint returning the code
/// itself as the ID token. `up` False plays it being unreachable.
fn idp(up: Bool) {
  fn(req: Request(String)) {
    assert req.host == "id.corp.test"
    case up, req.path {
      False, _ -> Error(service.Internal("OpenID Connect request failed"))
      _, "/.well-known/openid-configuration" ->
        Ok(
          response.new(200)
          |> response.set_body(
            json.to_string(
              json.object([
                #("issuer", json.string(issuer)),
                #("authorization_endpoint", json.string(issuer <> "/authorize")),
                #("token_endpoint", json.string(issuer <> "/token")),
                #("jwks_uri", json.string(issuer <> "/keys")),
              ]),
            ),
          ),
        )
      _, "/token" -> {
        let assert Ok(fields) = uri.parse_query(req.body)
        let assert Ok(code) = list.key_find(fields, "code")
        Ok(
          response.new(200)
          |> response.set_body(
            json.to_string(json.object([#("id_token", json.string(code))])),
          ),
        )
      }
      _, "/keys" -> Ok(response.new(200) |> response.set_body(jwks()))
      _, _ -> panic as "unexpected provider request"
    }
  }
}

fn generic(domains: List(String), up: Bool) -> provider.Provider {
  oidc.with_transport(
    "corp",
    "Corp ID",
    issuer,
    "client",
    "hunter2",
    domains,
    idp(up),
  )
}

fn id_token(start: auth.ProviderStart, changes: List(#(String, json.Json))) {
  [
    #("iss", json.string(issuer)),
    #("sub", json.string("0001")),
    #("aud", json.string("client")),
    #("exp", json.int(token.now() + 3600)),
    #("iat", json.int(token.now())),
    #("nonce", json.string(parameter(start.url, "nonce"))),
    #("email", json.string("Ada@Corp.test")),
    #("email_verified", json.bool(True)),
  ]
  |> list.fold(changes, _, fn(fields, change) {
    list.key_set(fields, change.0, change.1)
  })
  |> json.object
  |> json.to_string
  |> sign(header)
}

pub fn any_openid_connect_issuer_signs_in_test() {
  use database, identity, _, _ <- fixture
  let assert Ok(identity) =
    auth.with_provider(identity, generic(["corp.test"], True))
  let start = begin(identity)
  assert string.starts_with(start.url, issuer <> "/authorize?")
  assert parameter(start.url, "scope") == "openid email profile"
  assert parameter(start.url, "code_challenge_method") == "S256"
  let assert Ok(auth.ProviderSession(session)) =
    finish(identity, start, id_token(start, []))
  assert session.user.email == "ada@corp.test"
  let assert Ok(issuers) =
    repo.all(
      database,
      "SELECT issuer FROM howdy_auth_provider_identities",
      [],
      decode.field(0, decode.string, decode.success),
    )
  assert issuers == [issuer]
}

pub fn openid_connect_addresses_need_an_authoritative_domain_test() {
  use _, identity, _, _ <- fixture
  let refused = fn(identity, changes) {
    let start = begin(identity)
    finish(identity, start, id_token(start, changes))
    == Error(service.Forbidden)
  }
  let assert Ok(public) = auth.with_provider(identity, generic([], True))
  assert refused(public, [])
  let assert Ok(corp) =
    auth.with_provider(identity, generic(["corp.test"], True))
  assert refused(corp, [#("email", json.string("ada@elsewhere.test"))])
  assert refused(corp, [#("email_verified", json.bool(False))])
  assert refused(corp, [#("email_verified", json.null())])
}

pub fn openid_connect_tokens_are_verified_test() {
  use _, identity, _, _ <- fixture
  let assert Ok(identity) =
    auth.with_provider(identity, generic(["corp.test"], True))
  list.each(
    [
      #("iss", json.string("https://evil.test")),
      #("aud", json.string("someone-else")),
      #("exp", json.int(token.now() - 10)),
      #("nonce", json.string("replayed")),
    ],
    fn(change) {
      let start = begin(identity)
      assert finish(identity, start, id_token(start, [change]))
        == Error(service.Unauthorized)
    },
  )
}

pub fn an_unreachable_provider_fails_the_sign_in_not_startup_test() {
  use database, identity, _, _ <- fixture
  let assert Ok(identity) =
    auth.with_provider(identity, generic(["corp.test"], False))
  let assert Error(_) =
    auth.begin_provider(identity, "corp", callback, "client-one")
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_provider_attempts")
    == 0
  // Issuers that are not plain HTTPS URLs, or cannot form the discovery
  // request, are refused at installation rather than failing a sign-in.
  list.each(
    [
      "http://id.corp.test",
      "https://id.corp.test#frag",
      "https://user@id.corp.test",
      "https:///path",
      "https://",
      "id.corp.test",
    ],
    fn(issuer) {
      assert oidc.new(
          id: "corp",
          name: "Corp",
          issuer:,
          client_id: "client",
          client_secret: "hunter2",
          authoritative_for: [],
        )
        |> auth.with_provider(identity, _)
        |> is_invalid
    },
  )
}
