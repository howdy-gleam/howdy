//// Real RSA signatures over synthetic ID tokens; only Google's HTTP transport
//// is replaced. Every browser/headless path uses the production verifier.

import gleam/bit_array
import gleam/dynamic/decode
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
import gloo/repo
import gloo/sql
import howdy
import howdy/auth
import howdy/auth/group
import howdy/auth/groups
import howdy/auth/internal/token
import howdy/auth/pages
import howdy/auth/providers/google
import howdy/auth/routes
import howdy/auth/secret
import howdy/auth/session_store
import howdy/auth/user
import howdy/locale
import howdy/migration
import howdy/service
import howdy/testing
import support.{count, exec, fixture, signup, with_repo}

const callback = "/auth/providers/google/callback"

const header = "{\"alg\":\"RS256\",\"kid\":\"test-key\"}"

@external(erlang, "provider_test_ffi", "sign")
fn sign(payload: String, header: String) -> String

@external(erlang, "provider_test_ffi", "jwks")
fn jwks() -> String

fn transport(req: Request(String)) {
  case req.path {
    "/token" -> {
      assert req.method == http.Post
      assert req.host == "oauth2.googleapis.com"
      let assert Ok(fields) = uri.parse_query(req.body)
      assert list.key_find(fields, "client_id") == Ok("test-client")
      assert list.key_find(fields, "client_secret") == Ok("test-secret")
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
    "/oauth2/v3/certs" -> {
      assert req.host == "www.googleapis.com"
      Ok(response.new(200) |> response.set_body(jwks()))
    }
    _ -> panic as "unexpected Google request"
  }
}

fn configured(identity: auth.Auth) -> auth.Auth {
  let assert Ok(identity) =
    auth.with_provider(
      identity,
      google.with_transport("test-client", "test-secret", transport),
    )
  identity
}

fn parameters(url: String) {
  let assert Ok(url) = uri.parse(url)
  let assert Some(query) = url.query
  let assert Ok(fields) = uri.parse_query(query)
  fields
}

fn parameter(url, name) {
  let assert Ok(value) = list.key_find(parameters(url), name)
  value
}

fn signed(
  start: auth.ProviderStart,
  changes: List(#(String, json.Json)),
) -> String {
  signed_url(start.url, changes)
}

fn signed_url(url, changes: List(#(String, json.Json))) {
  let fields = [
    #("iss", json.string("https://accounts.google.com")),
    #("sub", json.string("google-subject")),
    #("aud", json.string("test-client")),
    #("exp", json.int(token.now() + 3600)),
    #("iat", json.int(token.now())),
    #("nonce", json.string(parameter(url, "nonce"))),
    #("email", json.string("ada@gmail.com")),
    #("email_verified", json.bool(True)),
  ]
  let fields =
    list.fold(changes, fields, fn(fields, change) {
      list.key_set(fields, change.0, change.1)
    })
  sign(json.to_string(json.object(fields)), header)
}

fn begin(identity) {
  let assert Ok(start) =
    auth.begin_provider(identity, "google", callback, "client-one")
  start
}

fn finish(identity, start: auth.ProviderStart, code, principal) {
  auth.finish_provider(
    identity,
    "google",
    callback,
    parameter(start.url, "state"),
    secret.reveal(start.browser_token),
    Some(code),
    principal,
  )
}

pub fn google_registration_session_and_subject_identity_test() {
  use database, identity, _, _ <- fixture
  let identity = configured(identity) |> auth.in_locale("de")
  let start = begin(identity)
  assert parameter(start.url, "scope") == "openid email"
  assert parameter(start.url, "redirect_uri")
    == "https://example.test" <> callback
  assert parameter(start.url, "code_challenge_method") == "S256"
  let assert Ok([verifier]) =
    repo.all(
      database,
      "SELECT verifier FROM howdy_auth_provider_attempts",
      [],
      decode.field(0, decode.string, decode.success),
    )
  assert parameter(start.url, "code_challenge") == token.digest(verifier)
  let code = signed(start, [])
  let assert Ok(auth.ProviderSession(session)) =
    finish(identity, start, code, None)
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  assert principal.user.locale == Some("de")
  let assert Ok([info]) = auth.sessions(identity, principal)
  assert info.method == auth.Provider("google")
  assert info.client == "client-one"
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_provider_attempts")
    == 0
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_provider_identities")
    == 1
  assert finish(identity, start, code, None) == Error(service.Unauthorized)
  let next = begin(identity)
  let assert Ok(auth.ProviderSession(again)) =
    finish(
      identity,
      next,
      signed(next, [#("email", json.string("renamed@gmail.com"))]),
      None,
    )
  assert again.user.id == session.user.id
  assert again.user.email == "ada@gmail.com"
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 1
  let assert Ok(identity) = auth.with_passwords(identity)
  assert auth.set_password(
      identity,
      principal,
      "uncommon orchard passphrase 937!",
    )
    == Error(service.Forbidden)
}

pub fn invalid_tokens_never_create_accounts_test() {
  use database, identity, _, _ <- fixture
  let identity = configured(identity)
  let cases = [
    #("iss", json.string("https://attacker.test")),
    #("aud", json.string("another-client")),
    #("azp", json.string("another-client")),
    #("aud", json.array(["test-client", "other"], json.string)),
    #("exp", json.int(token.now() - 1)),
    #("iat", json.int(token.now() + 120)),
    #("nbf", json.int(token.now() + 120)),
    #("nonce", json.string("wrong")),
    #("sub", json.string("")),
    #("email_verified", json.bool(False)),
  ]
  list.each(cases, fn(change) {
    let start = begin(identity)
    assert finish(identity, start, signed(start, [change]), None)
      == Error(service.Unauthorized)
  })
  list.each(
    [
      "not.a.jwt",
      "",
      sign("{}", "{\"alg\":\"none\",\"kid\":\"test-key\"}"),
      sign("{}", "{\"alg\":\"HS256\",\"kid\":\"test-key\"}"),
      sign("{}", "{\"alg\":\"RS256\",\"kid\":\"unknown\"}"),
    ],
    fn(code) {
      let start = begin(identity)
      assert finish(identity, start, code, None) == Error(service.Unauthorized)
    },
  )
  let start = begin(identity)
  let parts = string.split(signed(start, []), ".")
  let assert [head, payload, _] = parts
  assert finish(identity, start, head <> "." <> payload <> ".AAAA", None)
    == Error(service.Unauthorized)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 0
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_provider_attempts")
    == 0
}

pub fn state_binding_expiry_cancellation_and_closed_registration_test() {
  use database, identity, _, _ <- fixture
  let identity = configured(identity)
  let start = begin(identity)
  let code = signed(start, [])
  assert auth.finish_provider(
      identity,
      "google",
      callback,
      parameter(start.url, "state"),
      token.new(),
      Some(code),
      None,
    )
    == Error(service.Unauthorized)
  assert auth.finish_provider(
      identity,
      "google",
      "/wrong/callback",
      parameter(start.url, "state"),
      secret.reveal(start.browser_token),
      Some(code),
      None,
    )
    == Error(service.Unauthorized)
  assert auth.finish_provider(
      identity,
      "google",
      callback,
      parameter(start.url, "state"),
      secret.reveal(start.browser_token),
      None,
      None,
    )
    == Error(service.Unauthorized)
  assert finish(identity, start, code, None) == Error(service.Unauthorized)
  let expired = begin(identity)
  exec(database, "UPDATE howdy_auth_provider_attempts SET expires_at = 0")
  assert finish(identity, expired, signed(expired, []), None)
    == Error(service.Unauthorized)
  let assert Ok(closed) =
    auth.new_without_email(database, "https://example.test")
  let closed = configured(closed)
  let start = begin(identity)
  assert finish(closed, start, signed(start, []), None)
    == Error(service.Forbidden)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 0
}

pub fn existing_email_requires_explicit_link_and_session_binding_test() {
  use database, identity, _, mailbox <- fixture
  let session = signup(identity, mailbox, "ada@gmail.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let identity = configured(identity)
  let login = begin(identity)
  assert finish(identity, login, signed(login, []), None)
    == Error(service.Unauthorized)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_provider_identities")
    == 0
  let assert Ok(link) =
    auth.begin_provider_link(identity, principal, "google", callback)
  assert finish(identity, link, signed(link, []), None)
    == Error(service.Unauthorized)
  let assert Ok(link) =
    auth.begin_provider_link(identity, principal, "google", callback)
  assert finish(identity, link, signed(link, []), Some(principal))
    == Ok(auth.ProviderLinked)
  let login = begin(identity)
  let assert Ok(auth.ProviderSession(google_session)) =
    finish(identity, login, signed(login, []), None)
  assert google_session.user.id == session.user.id
  // A different subject cannot replace the link; users keep one per issuer.
  let assert Ok(link) =
    auth.begin_provider_link(identity, principal, "google", callback)
  let assert Error(service.Coded(_, service.Conflict(_))) =
    finish(
      identity,
      link,
      signed(link, [#("sub", json.string("another-subject"))]),
      Some(principal),
    )
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_provider_identities")
    == 1
  let assert Ok(link) =
    auth.begin_provider_link(identity, principal, "google", callback)
  let assert Ok(Nil) = auth.logout(identity, principal)
  assert finish(identity, link, signed(link, []), Some(principal))
    == Error(service.Unauthorized)
}

pub fn suspended_account_and_old_link_session_are_rejected_test() {
  use database, identity, _, _ <- fixture
  let identity = configured(identity)
  let start = begin(identity)
  let assert Ok(auth.ProviderSession(session)) =
    finish(identity, start, signed(start, []), None)
  let assert Ok(p) = auth.authenticate(identity, secret.reveal(session.token))
  exec(database, "UPDATE howdy_auth_sessions SET created_at = 0")
  assert auth.begin_provider_link(identity, p, "google", callback)
    == Error(service.Forbidden)
  let assert Ok(Nil) = auth.suspend(identity, session.user.id, by: user.System)
  let start = begin(identity)
  assert finish(identity, start, signed(start, []), None)
    == Error(service.Unauthorized)
}

pub fn hosted_domain_is_enforced_and_third_party_emails_require_local_verification_test() {
  use database, identity, _, mailbox <- fixture
  let provider =
    google.with_transport("test-client", "test-secret", transport)
    |> google.require_hosted_domain("example.com")
  let assert Ok(restricted) = auth.with_provider(identity, provider)
  let start = begin(restricted)
  assert parameter(start.url, "hd") == "example.com"
  assert finish(restricted, start, signed(start, []), None)
    == Error(service.Forbidden)
  let start = begin(restricted)
  let assert Ok(auth.ProviderSession(_)) =
    finish(
      restricted,
      start,
      signed(start, [
        #("hd", json.string("example.com")),
        #("email", json.string("ada@example.com")),
      ]),
      None,
    )
  let identity = configured(identity)
  let start = begin(identity)
  let changes = [
    #("sub", json.string("third-party")),
    #("email", json.string("grace@external.test")),
  ]
  assert finish(identity, start, signed(start, changes), None)
    == Error(service.Forbidden)
  let session = signup(identity, mailbox, "grace@external.test")
  let assert Ok(p) = auth.authenticate(identity, secret.reveal(session.token))
  let assert Ok(link) =
    auth.begin_provider_link(identity, p, "google", callback)
  assert finish(identity, link, signed(link, changes), Some(p))
    == Ok(auth.ProviderLinked)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_provider_identities")
    == 2
}

pub fn per_group_identity_isolation_and_mode_conversion_test() {
  use database, identity, _, _ <- fixture
  let assert Ok(identity) =
    auth.with_groups(configured(identity), group.AccountPerGroup)
  let assert Ok(a) = groups.create(identity, "A", by: user.System)
  let assert Ok(b) = groups.create(identity, "B", by: user.System)
  let one = auth.in_group(identity, a.id)
  let two = auth.in_group(identity, b.id)
  let start = begin(one)
  assert finish(two, start, signed(start, []), None)
    == Error(service.Unauthorized)
  let start = begin(one)
  let assert Ok(auth.ProviderSession(first)) =
    finish(one, start, signed(start, []), None)
  let start = begin(two)
  let assert Ok(auth.ProviderSession(second)) =
    finish(
      two,
      start,
      signed(start, [#("email", json.string("different@gmail.com"))]),
      None,
    )
  assert first.user.id != second.user.id
  assert first.user.group_id == a.id
  assert second.user.group_id == b.id
  // Even with distinct emails, the same external subject cannot be collapsed.
  let assert Error(service.Conflict(_)) =
    auth.with_groups(identity, group.OneGroupPerUser)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_provider_identities")
    == 2
}

pub fn external_session_store_and_google_only_configuration_test() {
  use database, _, _, _ <- fixture
  let assert Ok(identity) =
    auth.new_without_email(database, "https://example.test")
  let identity =
    identity
    |> auth.allow_registration
    |> configured
    |> auth.with_session_store(session_store.memory())
  assert !auth.email_tokens_enabled(identity)
  assert auth.request_token(identity, "ada@gmail.com", auth.Register)
    == Error(service.Forbidden)
  let start = begin(identity)
  let assert Ok(auth.ProviderSession(session)) =
    finish(identity, start, signed(start, []), None)
  let assert Ok(p) = auth.authenticate(identity, secret.reveal(session.token))
  let assert Ok([info]) = auth.sessions(identity, p)
  assert info.method == auth.Provider("google")
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_sessions") == 0
  let assert Error(service.Invalid(_)) =
    auth.with_provider(identity, google.new("", ""))
  let assert Error(service.Invalid(_)) =
    auth.with_provider(identity, google.new("client", "secret"))
  assert auth.providers(identity) == [#("google", "Google")]
}

pub fn browser_routes_and_starter_pages_test() {
  use _, identity, _, _ <- fixture
  let identity =
    configured(identity)
    |> auth.with_locales(
      locale.negotiator(["en", "de"], default: "en")
      |> locale.from_accept_language,
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
    |> howdy.controller(pages.routes(identity, at: "/auth", api_at: "/api/auth"))
  let path = "/auth/providers/google/login"
  let rejected = testing.post(path, json.null()) |> testing.send(app)
  assert rejected.status == 403
  let rejected =
    testing.post(path, json.null())
    |> testing.header("origin", "https://attacker.test")
    |> testing.send(app)
  assert rejected.status == 403
  let started =
    testing.post_form(path, [])
    |> testing.header("origin", "https://example.test")
    |> testing.send(app)
  assert started.status == 303
  assert response.get_header(started, "cache-control") == Ok("no-store")
  let assert Ok(location) = response.get_header(started, "location")
  let assert [#(cookie_name, browser)] = testing.cookies(started)
  assert string.starts_with(cookie_name, "__Host-")
  let callback_url =
    callback
    <> "?"
    <> uri.query_to_string([
      #("state", parameter(location, "state")),
      #("code", signed_url(location, [])),
    ])
  let completed =
    testing.get(callback_url)
    |> testing.cookie(cookie_name, browser)
    |> testing.header("accept-language", "de-CH, en;q=0.5")
    |> testing.send(app)
  assert response.get_header(completed, "location") == Ok("/account")
  let cookies = testing.cookies(completed)
  let assert Ok(session) = list.key_find(cookies, auth.cookie_name(identity))
  let assert Ok(principal) = auth.authenticate(identity, session)
  assert principal.user.locale == Some("de")
  let me =
    testing.get("/api/auth/me")
    |> testing.cookie(auth.cookie_name(identity), session)
    |> testing.send(app)
  assert me.status == 200
  let replay =
    testing.get(callback_url)
    |> testing.cookie(cookie_name, browser)
    |> testing.send(app)
  assert response.get_header(replay, "location") == Ok("/login")
  let page = testing.get("/auth/login?group=tenant") |> testing.send(app)
  assert string.contains(testing.text(page), "Continue with Google")
  assert string.contains(
    testing.text(page),
    "action=\"/auth/providers/google/login?group=tenant\"",
  )
}

pub fn provider_migration_preserves_existing_session_test() {
  use database <- with_repo
  let migration.Package(name, migrations) = auth.schema()
  let assert Ok(Nil) =
    migration.run(database, [migration.Package(name, list.take(migrations, 8))])
  exec(
    database,
    "INSERT INTO howdy_auth_users(id, email, login_key, group_id) VALUES ('existing', 'ada@example.test', 'ada@example.test', 'default')",
  )
  let secret = token.new()
  let assert Ok(_) =
    repo.execute(
      database,
      "INSERT INTO howdy_auth_sessions(digest, user_id, expires_at, created_at, last_seen_at, method, client) VALUES ($1, 'existing', $2, $3, $4, 'password', 'before-upgrade')",
      [
        sql.string(token.digest(secret)),
        sql.int(token.now() + 3600),
        sql.int(token.now()),
        sql.int(token.now()),
      ],
    )
  exec(
    database,
    "CREATE INDEX ops_session_expiry ON howdy_auth_sessions(expires_at)",
  )
  let assert Ok(Nil) = migration.run(database, [auth.schema()])
  // Migration must preserve permitted operator indexes along with live sessions.
  exec(database, "DROP INDEX ops_session_expiry")
  let assert Ok(identity) =
    auth.new_without_email(database, "https://example.test")
  let assert Ok(principal) = auth.authenticate(identity, secret)
  let assert Ok([info]) = auth.sessions(identity, principal)
  assert info.method == auth.Password
  assert info.client == "before-upgrade"
  assert migration.check(database, auth.schema()) == Ok(Nil)
}

pub fn concurrent_callbacks_issue_exactly_one_session_test() {
  use database, identity, _, _ <- fixture
  let identity = configured(identity)
  let start = begin(identity)
  let code = signed(start, [])
  let replies = process.new_subject()
  list.each([1, 2], fn(_) {
    let _ =
      process.spawn(fn() {
        process.send(replies, finish(identity, start, code, None))
      })
    Nil
  })
  let assert Ok(first) = process.receive(replies, 5000)
  let assert Ok(second) = process.receive(replies, 5000)
  assert list.length(list.filter([first, second], result.is_ok)) == 1
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_sessions") == 1
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 1
}

pub fn attempts_survive_runtime_restart_and_group_links_follow_moves_test() {
  use database, identity, _, _ <- fixture
  let assert Ok(identity) =
    auth.with_groups(configured(identity), group.OneGroupPerUser)
  let assert Ok(a) = groups.create(identity, "A", by: user.System)
  let assert Ok(b) = groups.create(identity, "B", by: user.System)
  let one = auth.in_group(identity, a.id)
  let start = begin(one)
  let assert Ok(restarted) =
    auth.new_without_email(database, "https://example.test")
  let restarted = restarted |> configured |> auth.allow_registration
  let assert Ok(auth.ProviderSession(session)) =
    finish(restarted, start, signed(start, []), None)
  let assert Ok(per_group) = auth.with_groups(restarted, group.AccountPerGroup)
  let pending = begin(auth.in_group(per_group, a.id))
  let assert Ok(_) =
    groups.move(per_group, session.user.id, to: b.id, by: user.System)
  assert finish(per_group, pending, signed(pending, []), None)
    == Error(service.Unauthorized)
  let moved = auth.in_group(per_group, b.id)
  let start = begin(moved)
  let assert Ok(auth.ProviderSession(again)) =
    finish(moved, start, signed(start, []), None)
  assert again.user.id == session.user.id
  let assert Ok(global) = auth.with_groups(per_group, group.OneGroupPerUser)
  let start = begin(global)
  let assert Ok(auth.ProviderSession(again)) =
    finish(global, start, signed(start, []), None)
  assert again.user.id == session.user.id
}

pub fn keys_cache_and_rotation_use_real_signature_verification_test() {
  use _, identity, _, _ <- fixture
  let requests = process.new_subject()
  process.send(requests, 0)
  let provider =
    google.with_transport("test-client", "test-secret", fn(req) {
      case req.path {
        "/oauth2/v3/certs" -> {
          let assert Ok(n) = process.receive(requests, 0)
          process.send(requests, n + 1)
          let keys = case n {
            0 -> jwks()
            _ -> string.replace(jwks(), "test-key", "rotated-key")
          }
          Ok(
            response.new(200)
            |> response.set_header("cache-control", "public, max-age=3600")
            |> response.set_body(keys),
          )
        }
        _ -> transport(req)
      }
    })
  let assert Ok(identity) = auth.with_provider(identity, provider)
  list.each([1, 2], fn(_) {
    let start = begin(identity)
    let assert Ok(_) = finish(identity, start, signed(start, []), None)
    Nil
  })
  let assert Ok(n) = process.receive(requests, 0)
  assert n == 1
  process.send(requests, n)
  let start = begin(identity)
  let assert [_, payload, _] = string.split(signed(start, []), ".")
  let assert Ok(bits) = bit_array.base64_url_decode(payload)
  let assert Ok(payload) = bit_array.to_string(bits)
  let rotated = sign(payload, string.replace(header, "test-key", "rotated-key"))
  let assert Ok(_) = finish(identity, start, rotated, None)
  assert process.receive(requests, 0) == Ok(2)
}

pub fn provider_failure_spends_attempt_and_creates_no_user_test() {
  use database, identity, _, _ <- fixture
  let provider =
    google.with_transport("test-client", "test-secret", fn(_) {
      Error(service.Internal("test transport unavailable"))
    })
  let assert Ok(identity) = auth.with_provider(identity, provider)
  let start = begin(identity)
  let assert Error(service.Internal(_)) =
    finish(identity, start, signed(start, []), None)
  assert finish(identity, start, signed(start, []), None)
    == Error(service.Unauthorized)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 0
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_provider_attempts")
    == 0
}
