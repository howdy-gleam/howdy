import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri
import howdy/auth
import howdy/auth/internal/token
import howdy/auth/provider
import howdy/auth/providers/entra
import howdy/auth/providers/facebook
import howdy/auth/providers/github
import howdy/auth/secret
import howdy/service
import support.{fixture, signup}

const tenant = "12345678-1234-1234-1234-123456789abc"

const consumer = "9188040d-6c67-4c5b-b112-36a304b66dad"

@external(erlang, "provider_test_ffi", "sign")
fn sign(payload: String, header: String) -> String

@external(erlang, "provider_test_ffi", "jwks")
fn jwks() -> String

fn exchange() {
  provider.Exchange(
    secret.wrap("code"),
    "https://example.test/callback",
    secret.wrap("verifier"),
    token.digest("nonce"),
  )
}

fn ok(body) {
  Ok(response.new(200) |> response.set_body(body))
}

fn fields(req: request.Request(String)) {
  assert req.method == http.Post
  let assert Ok(fields) = uri.parse_query(req.body)
  assert list.key_find(fields, "client_id") == Ok("client")
  assert list.key_find(fields, "client_secret") == Ok("secret")
  assert list.key_find(fields, "redirect_uri")
    == Ok("https://example.test/callback")
  fields
}

pub fn facebook_missing_email_is_valid_identity_test() {
  list.each(["{\"id\":\"42\"}", "{\"id\":\"42\",\"email\":null}"], fn(profile) {
    let p =
      facebook.with_transport("client", "secret", fn(req) {
        case req.path {
          "/v23.0/oauth/access_token" -> {
            assert list.key_find(fields(req), "code") == Ok("code")
            ok("{\"access_token\":\"access\"}")
          }
          "/v23.0/me" -> ok(profile)
          _ -> panic
        }
      })
    assert provider.exchange(p, exchange())
      == Ok(provider.Identity("https://www.facebook.com", "42", "", False, None))
  })
}

fn github_provider(profile, emails) {
  github.with_transport("client", "secret", fn(req) {
    case req.path {
      "/login/oauth/access_token" -> {
        assert list.key_find(fields(req), "code_verifier") == Ok("verifier")
        assert request.get_header(req, "accept") == Ok("application/json")
        ok("{\"access_token\":\"access\"}")
      }
      "/user" | "/user/emails" -> {
        assert request.get_header(req, "authorization") == Ok("Bearer access")
        assert request.get_header(req, "user-agent") == Ok("howdy-auth")
        case req.path {
          "/user" -> ok(profile)
          _ -> ok(emails)
        }
      }
      _ -> panic
    }
  })
}

pub fn github_verified_primary_email_and_pkce_test() {
  let p =
    github_provider(
      "{\"id\":42,\"email\":null}",
      "[{\"email\":\"other@example.test\",\"primary\":false,\"verified\":true},{\"email\":\"ada@example.test\",\"primary\":true,\"verified\":true}]",
    )
  let assert Ok(url) =
    provider.authorization_url(
      p,
      provider.Authorization(
        "https://example.test/callback",
        "state",
        "nonce",
        "challenge",
      ),
    )
  let assert Ok(url) = uri.parse(url)
  let assert Some(query) = url.query
  let assert Ok(params) = uri.parse_query(query)
  assert list.key_find(params, "code_challenge") == Ok("challenge")
  assert list.key_find(params, "code_challenge_method") == Ok("S256")
  assert provider.exchange(p, exchange())
    == Ok(provider.Identity(
      "https://github.com",
      "42",
      "ada@example.test",
      True,
      None,
    ))
}

pub fn github_unverified_or_absent_email_is_not_authoritative_test() {
  let p =
    github_provider(
      "{\"id\":42,\"email\":\"stated@example.test\"}",
      "[{\"email\":\"stated@example.test\",\"primary\":true,\"verified\":false}]",
    )
  assert provider.exchange(p, exchange())
    == Ok(provider.Identity(
      "https://github.com",
      "42",
      "stated@example.test",
      False,
      None,
    ))
  let p = github_provider("{\"id\":42}", "[]")
  assert provider.exchange(p, exchange())
    == Ok(provider.Identity("https://github.com", "42", "", False, None))
}

fn signed(changes: List(#(String, json.Json))) {
  let defaults = [
    #(
      "iss",
      json.string("https://login.microsoftonline.com/" <> tenant <> "/v2.0"),
    ),
    #("tid", json.string(tenant)),
    #("sub", json.string("subject")),
    #("aud", json.string("client")),
    #("nonce", json.string("nonce")),
    #("exp", json.int(token.now() + 3600)),
    #("iat", json.int(token.now())),
  ]
  let claims =
    list.fold(changes, defaults, fn(all, field) {
      list.key_set(all, field.0, field.1)
    })
  sign(
    json.to_string(json.object(claims)),
    "{\"alg\":\"RS256\",\"kid\":\"test-key\"}",
  )
}

fn microsoft(configured_tenant, signed) {
  entra.with_transport("client", "secret", configured_tenant, fn(req) {
    case string.ends_with(req.path, "/token") {
      True -> {
        assert list.key_find(fields(req), "code_verifier") == Ok("verifier")
        ok(json.to_string(json.object([#("id_token", json.string(signed))])))
      }
      False ->
        case string.ends_with(req.path, "/.well-known/openid-configuration") {
          True ->
            ok(
              "{\"issuer\":\"https://login.microsoftonline.com/"
              <> tenant
              <> "/v2.0\"}",
            )
          False ->
            ok(string.replace(
              jwks(),
              "\"kty\":",
              "\"issuer\":\"https://login.microsoftonline.com/{tenantid}/v2.0\",\"kty\":",
            ))
        }
    }
  })
}

pub fn entra_tenant_ids_domains_and_aliases_test() {
  list.each(
    [tenant, "common", "organizations", "example.onmicrosoft.com"],
    fn(config) {
      let p = microsoft(config, signed([]))
      assert provider.validate(p) == Ok(Nil)
      assert provider.exchange(p, exchange())
        == Ok(provider.Identity(
          "https://login.microsoftonline.com/" <> tenant <> "/v2.0",
          "subject",
          "",
          False,
          None,
        ))
    },
  )
  let p =
    microsoft(
      "consumers",
      signed([
        #("tid", json.string(consumer)),
        #(
          "iss",
          json.string(
            "https://login.microsoftonline.com/" <> consumer <> "/v2.0",
          ),
        ),
      ]),
    )
  let assert Ok(_) = provider.exchange(p, exchange())
}

pub fn entra_rejects_invalid_claims_and_account_types_test() {
  list.each(
    [
      #("nonce", json.string("wrong")),
      #("aud", json.string("wrong")),
      #("iss", json.string("https://attacker.test")),
      #("tid", json.string("not-a-guid")),
      #("exp", json.int(token.now() - 1)),
      #("iat", json.int(token.now() + 120)),
      #("nbf", json.int(token.now() + 120)),
      #("sub", json.string("")),
    ],
    fn(change) {
      assert provider.exchange(
          microsoft("common", signed([change])),
          exchange(),
        )
        == Error(service.Unauthorized)
    },
  )
  assert provider.exchange(microsoft("consumers", signed([])), exchange())
    == Error(service.Unauthorized)
  let personal =
    signed([
      #("tid", json.string(consumer)),
      #(
        "iss",
        json.string("https://login.microsoftonline.com/" <> consumer <> "/v2.0"),
      ),
    ])
  assert provider.exchange(microsoft("organizations", personal), exchange())
    == Error(service.Unauthorized)
  assert provider.exchange(microsoft(tenant, personal), exchange())
    == Error(service.Unauthorized)
}

pub fn oauth_failures_do_not_produce_identities_test() {
  list.each([facebook.with_transport, github.with_transport], fn(make) {
    list.each(["{}", "{\"access_token\":\"\"}", "not json"], fn(body) {
      let p = make("client", "secret", fn(_) { ok(body) })
      assert provider.exchange(p, exchange()) == Error(service.Unauthorized)
    })
    let p =
      make("client", "secret", fn(_) {
        Ok(response.new(401) |> response.set_body("{}"))
      })
    assert provider.exchange(p, exchange()) == Error(service.Unauthorized)
  })
}

pub fn entra_key_scope_signature_and_email_trust_test() {
  list.each(
    [
      jwks(),
      string.replace(
        jwks(),
        "\"kty\":",
        "\"issuer\":\"https://attacker.test\",\"kty\":",
      ),
    ],
    fn(keys) {
      let p =
        entra.with_transport("client", "secret", "common", fn(req) {
          case string.ends_with(req.path, "/token") {
            True ->
              ok(
                json.to_string(
                  json.object([#("id_token", json.string(signed([])))]),
                ),
              )
            False -> ok(keys)
          }
        })
      assert provider.exchange(p, exchange()) == Error(service.Unauthorized)
    },
  )
  assert provider.exchange(microsoft("common", "not.a.token"), exchange())
    == Error(service.Unauthorized)
  let p =
    microsoft(
      "common",
      signed([
        #("email", json.string("ada@example.test")),
        #("email_verified", json.bool(True)),
      ]),
    )
  let assert Ok(identity) = provider.exchange(p, exchange())
  assert identity.email == "ada@example.test"
  assert !identity.email_authoritative
}

fn parameter(url, name) {
  let assert Ok(url) = uri.parse(url)
  let assert Some(query) = url.query
  let assert Ok(params) = uri.parse_query(query)
  let assert Ok(value) = list.key_find(params, name)
  value
}

pub fn facebook_link_and_subsequent_signin_without_email_test() {
  use _, identity, _, mailbox <- fixture
  let p =
    facebook.with_transport("client", "secret", fn(req) {
      case req.path {
        "/v23.0/oauth/access_token" -> ok("{\"access_token\":\"access\"}")
        _ -> ok("{\"id\":\"42\"}")
      }
    })
  let assert Ok(identity) = auth.with_provider(identity, p)
  let callback = "/auth/providers/facebook/callback"
  let finish = fn(start: auth.ProviderStart, principal) {
    auth.finish_provider(
      identity,
      "facebook",
      callback,
      parameter(start.url, "state"),
      secret.reveal(start.browser_token),
      Some("code"),
      principal,
    )
  }
  let assert Ok(start) =
    auth.begin_provider(identity, "facebook", callback, "browser")
  assert finish(start, None) == Error(service.Forbidden)
  let session = signup(identity, mailbox, "ada@example.test")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let assert Ok(start) =
    auth.begin_provider_link(identity, principal, "facebook", callback)
  assert finish(start, Some(principal)) == Ok(auth.ProviderLinked)
  let assert Ok(start) =
    auth.begin_provider(identity, "facebook", callback, "browser")
  let assert Ok(auth.ProviderSession(signed_in)) = finish(start, None)
  assert signed_in.user.id == session.user.id
  assert finish(start, None) == Error(service.Unauthorized)
}

pub fn entra_is_validated_when_installed_test() {
  use _, identity, _, _ <- fixture
  let invalid = fn(provider) {
    case auth.with_provider(identity, provider) {
      Error(service.Invalid(_)) -> True
      _ -> False
    }
  }
  // A tenant that cannot form Microsoft's URLs is refused at installation,
  // never left to fail a sign-in.
  assert invalid(entra.new("client", "secret", ""))
  assert invalid(entra.new("client", "secret", "contoso/../common"))
  assert invalid(entra.new("client", "secret", "contoso.com?x=1"))
  assert invalid(entra.new("client", "secret", "contoso.com#frag"))
  assert invalid(entra.new("client", "secret", "a b"))
  assert invalid(entra.new("", "secret", tenant))
  assert invalid(entra.new("client", "", tenant))
  let assert Ok(_) =
    auth.with_provider(identity, entra.new("client", "secret", tenant))
  let assert Ok(_) =
    auth.with_provider(identity, entra.new("client", "secret", "contoso.com"))
}
