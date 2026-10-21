//// Sign in with Apple: the signed client secret, Apple's claims, and the
//// cross-site POST that answers the browser flow.

import gleam/dynamic/decode
import gleam/http
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import gleam/uri
import howdy
import howdy/auth
import howdy/auth/internal/token
import howdy/auth/provider
import howdy/auth/providers/apple
import howdy/auth/routes
import howdy/auth/secret
import howdy/service
import howdy/testing
import support.{fixture}

@external(erlang, "provider_test_ffi", "sign")
fn sign(payload: String, header: String) -> String

@external(erlang, "provider_test_ffi", "jwks")
fn jwks() -> String

@external(erlang, "provider_test_ffi", "ec_pem")
fn key() -> String

@external(erlang, "provider_test_ffi", "ec_sec1_pem")
fn sec1_key() -> String

@external(erlang, "provider_test_ffi", "es256_verify")
fn es256_verify(jwt: String) -> Result(#(String, String), Nil)

const services_id = "com.example.web"

fn id_token(nonce: String, changes: List(#(String, json.Json))) {
  let defaults = [
    #("iss", json.string("https://appleid.apple.com")),
    #("sub", json.string("001234.abcdef.5678")),
    #("aud", json.string(services_id)),
    #("nonce", json.string(nonce)),
    #("exp", json.int(token.now() + 600)),
    #("iat", json.int(token.now())),
    #("email", json.string("ada@privaterelay.appleid.com")),
    #("email_verified", json.string("true")),
    #("is_private_email", json.string("true")),
  ]
  let claims =
    list.fold(changes, defaults, fn(all, field) {
      list.key_set(all, field.0, field.1)
    })
    // A null change removes the claim, as Apple omits what it does not share.
    |> list.filter(fn(field) { field.1 != json.null() })
  sign(
    json.to_string(json.object(claims)),
    "{\"alg\":\"RS256\",\"kid\":\"test-key\"}",
  )
}

/// Apple, answering every code with the id_token `issue` makes for it.
fn apple_with(private_key: String, issue: fn(String) -> String) {
  apple.with_transport(
    services_id,
    "TEAM123456",
    "KEY1234567",
    private_key,
    fn(req) {
      case req.path {
        "/auth/token" -> {
          assert req.method == http.Post
          let assert Ok(fields) = uri.parse_query(req.body)
          assert list.key_find(fields, "client_id") == Ok(services_id)
          assert list.key_find(fields, "redirect_uri")
            == Ok("https://example.test/callback")
            || list.key_find(fields, "redirect_uri")
            == Ok("https://example.test/auth/providers/apple/callback")
          // No PKCE, and the secret is a fresh ES256 JWT, not a shared string.
          assert list.key_find(fields, "code_verifier") == Error(Nil)
          let assert Ok(client_secret) = list.key_find(fields, "client_secret")
          let assert Ok(#(header, claims)) = es256_verify(client_secret)
          assert header == "{\"alg\":\"ES256\",\"kid\":\"KEY1234567\"}"
          let assert Ok(#(iss, sub, aud, iat, exp)) =
            json.parse(claims, {
              use iss <- decode.field("iss", decode.string)
              use sub <- decode.field("sub", decode.string)
              use aud <- decode.field("aud", decode.string)
              use iat <- decode.field("iat", decode.int)
              use exp <- decode.field("exp", decode.int)
              decode.success(#(iss, sub, aud, iat, exp))
            })
          assert iss == "TEAM123456"
          assert sub == services_id
          assert aud == "https://appleid.apple.com"
          assert iat <= token.now() && exp - iat == 300
          let assert Ok(code) = list.key_find(fields, "code")
          Ok(
            response.new(200)
            |> response.set_body(
              json.to_string(
                json.object([#("id_token", json.string(issue(code)))]),
              ),
            ),
          )
        }
        "/auth/keys" -> Ok(response.new(200) |> response.set_body(jwks()))
        _ -> Error(service.Internal("unexpected Apple request"))
      }
    },
  )
}

fn exchange(changes) {
  provider.exchange(
    apple_with(key(), fn(_) { id_token("nonce", changes) }),
    provider.Exchange(
      secret.wrap("code"),
      "https://example.test/callback",
      secret.wrap("verifier"),
      token.digest("nonce"),
    ),
  )
}

pub fn apple_signs_its_client_secret_and_verifies_the_identity_test() {
  assert exchange([])
    == Ok(provider.Identity(
      "https://appleid.apple.com",
      "001234.abcdef.5678",
      "ada@privaterelay.appleid.com",
      True,
      None,
    ))
  // Apple has sent `email_verified` both as a string and as a boolean.
  let assert Ok(identity) = exchange([#("email_verified", json.bool(True))])
  assert identity.email_authoritative
  let assert Ok(identity) =
    exchange([#("email_verified", json.string("false"))])
  assert !identity.email_authoritative
  // A user may share no address. The identity still signs in where linked.
  let assert Ok(identity) =
    exchange([#("email", json.null()), #("email_verified", json.null())])
  assert identity.email == "" && !identity.email_authoritative
}

pub fn apple_rejects_tokens_not_meant_for_this_attempt_test() {
  let refused = fn(changes) { exchange(changes) == Error(service.Unauthorized) }
  assert refused([#("iss", json.string("https://accounts.google.com"))])
  assert refused([#("aud", json.string("com.example.other"))])
  assert refused([
    #(
      "aud",
      json.preprocessed_array([
        json.string(services_id),
        json.string("com.example.other"),
      ]),
    ),
  ])
  assert refused([#("nonce", json.string("another"))])
  assert refused([#("exp", json.int(token.now() - 1))])
  assert refused([#("iat", json.int(token.now() + 3600))])
  assert refused([#("sub", json.string(""))])
}

pub fn apple_configuration_is_checked_at_startup_test() {
  use _, identity, _, _ <- fixture
  let configure = fn(client_id, private_key) {
    auth.with_provider(
      identity,
      apple.new(
        client_id:,
        team_id: "TEAM123456",
        key_id: "KEY1234567",
        private_key:,
      ),
    )
  }
  let assert Ok(configured) = configure(services_id, key())
  assert auth.providers(configured) == [#("apple", "Apple")]
  // The older SEC1 encoding of the same key is as good.
  assert result.is_ok(configure(services_id, sec1_key()))
  assert result.is_error(configure("", key()))
  assert result.is_error(configure(services_id, "not a key"))
  assert result.is_error(configure(services_id, ""))
}

fn parameter(url: String, name: String) -> String {
  let assert Ok(parsed) = uri.parse(url)
  let assert Ok(fields) = uri.parse_query(option.unwrap(parsed.query, ""))
  let assert Ok(value) = list.key_find(fields, name)
  value
}

pub fn apple_answers_by_cross_site_post_which_becomes_the_callback_get_test() {
  use _, identity, _, _ <- fixture
  // The code is the nonce, so the fake Apple can echo it into the id_token.
  let assert Ok(identity) =
    auth.with_provider(
      identity,
      apple_with(key(), fn(code) { id_token(code, []) }),
    )
  let app =
    howdy.new()
    |> howdy.controller(routes.providers(
      identity,
      at: "/auth",
      success_path: "/account",
      failure_path: "/login",
    ))
    |> howdy.controller(routes.api(identity, at: "/api/auth"))
  let started =
    testing.post_form("/auth/providers/apple/login", [])
    |> testing.header("origin", "https://example.test")
    |> testing.send(app)
  assert started.status == 303
  let assert Ok(location) = response.get_header(started, "location")
  assert string.starts_with(
    location,
    "https://appleid.apple.com/auth/authorize?",
  )
  assert parameter(location, "response_mode") == "form_post"
  assert parameter(location, "scope") == "email"
  assert parameter(location, "client_id") == services_id
  assert !string.contains(location, "code_challenge")
  let assert [#(cookie_name, browser)] = testing.cookies(started)
  let state = parameter(location, "state")
  let nonce = parameter(location, "nonce")

  // Apple posts from its own site: no Origin of ours, and no Lax cookie.
  let posted =
    testing.post_form("/auth/providers/apple/callback", [
      #("state", state),
      #("code", nonce),
      #("user", "{\"name\":{\"firstName\":\"Ada\"}}"),
    ])
    |> testing.header("origin", "https://appleid.apple.com")
    |> testing.send(app)
  assert posted.status == 303
  assert testing.cookies(posted) == []
  let assert Ok(next) = response.get_header(posted, "location")
  assert next
    == "/auth/providers/apple/callback?"
    <> uri.query_to_string([#("state", state), #("code", nonce)])

  // Without the browser's binding cookie the answer is worth nothing.
  let stolen = testing.get(next) |> testing.send(app)
  assert response.get_header(stolen, "location") == Ok("/login")

  // Replaying needs a new attempt, since that failure spent this one.
  let started =
    testing.post_form("/auth/providers/apple/login", [])
    |> testing.header("origin", "https://example.test")
    |> testing.send(app)
  let assert Ok(location) = response.get_header(started, "location")
  let assert [#(cookie_name_again, browser_again)] = testing.cookies(started)
  assert cookie_name_again == cookie_name
  let _ = browser
  let posted =
    testing.post_form("/auth/providers/apple/callback", [
      #("state", parameter(location, "state")),
      #("code", parameter(location, "nonce")),
    ])
    |> testing.send(app)
  let assert Ok(next) = response.get_header(posted, "location")
  let completed =
    testing.get(next)
    |> testing.cookie(cookie_name, browser_again)
    |> testing.send(app)
  assert response.get_header(completed, "location") == Ok("/account")
  let assert Ok(session) =
    list.key_find(testing.cookies(completed), auth.cookie_name(identity))
  let me =
    testing.get("/api/auth/me")
    |> testing.cookie(auth.cookie_name(identity), session)
    |> testing.send(app)
  assert me.status == 200
  assert string.contains(testing.text(me), "ada@privaterelay.appleid.com")

  // A refusal at Apple, and a hostile post, only ever lead to the local GET.
  let denied =
    testing.post_form("/auth/providers/apple/callback", [
      #("state", "s"),
      #("error", "user_cancelled_authorize"),
      #("redirect", "https://attacker.test/\r\nset-cookie: x=y"),
    ])
    |> testing.send(app)
  assert response.get_header(denied, "location")
    == Ok(
      "/auth/providers/apple/callback?state=s&error=user_cancelled_authorize",
    )
}
