import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request as gleam_http_request
import gleam/json
import gleam/list
import gleam/option as gleam_option
import gleam/string
import gloo/repo
import gloo/sql
import howdy
import howdy/auth
import howdy/auth/internal/cache
import howdy/auth/pages
import howdy/auth/password_hasher
import howdy/auth/policy
import howdy/auth/routes
import howdy/auth/secret
import howdy/auth/user
import howdy/authorization as access
import howdy/service
import howdy/testing
import support.{count, exec, fixture, signup}

const password = "an uncommon orchard phrase 947!"

@external(erlang, "howdy_auth_test_ffi", "advance_clock")
fn advance_clock(ms: Int, run: fn() -> a) -> a

fn credential(database, id, encoded) {
  let assert Ok(_) =
    repo.execute(
      database,
      "UPDATE howdy_auth_passwords SET encoded_hash = $1, normalized = 0 WHERE user_id = $2",
      [sql.string(encoded), sql.string(id)],
    )
}

fn stored_hash(database) {
  let assert Ok([encoded]) =
    repo.all(
      database,
      "SELECT encoded_hash FROM howdy_auth_passwords",
      [],
      decode.field(0, decode.string, decode.success),
    )
  encoded
}

pub fn origins_are_canonical_and_cookie_requests_work_test() {
  use database, _, _, _ <- fixture
  list.each(
    [
      #("https://Example.COM:443", "https://example.com"),
      #("http://LOCALHOST:80", "http://localhost"),
      #("http://[::1]:80", "http://[::1]"),
      #("http://[0:0:0:0:0:0:0:1]:80", "http://[::1]"),
      #("https://Example.COM:8443", "https://example.com:8443"),
    ],
    fn(pair) {
      let assert Ok(identity) = auth.new(database, pair.0, fn(_) { Ok(Nil) })
      assert auth.origin(identity) == pair.1
      let app =
        howdy.new() |> howdy.controller(routes.api(identity, at: "/auth"))
      // A canonical Origin passes CSRF and reaches token validation (401).
      assert testing.post("/auth/session", gleam_json_token())
        |> testing.header("origin", pair.1)
        |> testing.send(app)
        |> fn(r) { r.status }
        == 401
    },
  )
  let assert Error(service.Invalid(_)) =
    auth.new(database, "https://example.com:65536", fn(_) { Ok(Nil) })
}

fn gleam_json_token() {
  json.object([#("token", json.string("wrong"))])
}

pub fn returned_credentials_are_redacted_during_inspection_test() {
  use _, identity, _, mailbox <- fixture
  let assert Ok(Nil) =
    auth.request_token(identity, "ada@example.com", auth.Register)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert !string.contains(
    string.inspect(delivery),
    secret.reveal(delivery.token),
  )
  let assert Ok(session) =
    auth.exchange(identity, secret.reveal(delivery.token))
  assert !string.contains(string.inspect(session), secret.reveal(session.token))
  let assert Ok(_) = auth.authenticate(identity, secret.reveal(session.token))
}

pub fn attacker_client_does_not_lock_out_another_client_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let assert Ok(Nil) = auth.set_password(identity, principal, password)
  list.each(list.repeat(Nil, 5), fn(_) {
    assert auth.login_password_from(
        identity,
        "ada@example.com",
        "wrong",
        "attacker",
      )
      == Error(service.Unauthorized)
  })
  let assert Error(service.TooManyRequests(first_wait)) =
    auth.login_password_from(identity, "ada@example.com", password, "attacker")
  assert first_wait > 0 && first_wait <= 60
  let assert Ok(_) =
    auth.login_password_from(identity, "ada@example.com", password, "victim")
  // Victim success must not clear the attacker's back-off.
  let assert Error(service.TooManyRequests(_)) =
    auth.login_password_from(identity, "ada@example.com", "wrong", "attacker")
  exec(database, "UPDATE howdy_auth_password_clients SET next_at = 0")
  assert auth.login_password_from(
      identity,
      "ada@example.com",
      "wrong",
      "attacker",
    )
    == Error(service.Unauthorized)
  let assert Error(service.TooManyRequests(second_wait)) =
    auth.login_password_from(identity, "ada@example.com", "wrong", "attacker")
  assert second_wait > first_wait
  exec(database, "UPDATE howdy_auth_password_clients SET next_at = 0")
  let assert Ok(_) =
    auth.login_password_from(identity, "ada@example.com", password, "attacker")
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_password_clients")
    == 0
}

pub fn shared_address_ceiling_still_bounds_rotating_clients_test() {
  use _, identity, _, _ <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let assert Ok(identity) =
    auth.with_policy(
      identity,
      policy.Policy(
        ..policy.default(),
        password_attempts: 1,
        password_account_attempts: 2,
      ),
    )
  assert auth.login_password_from(
      identity,
      "nobody@example.com",
      "wrong",
      "one",
    )
    == Error(service.Unauthorized)
  assert auth.login_password_from(
      identity,
      "nobody@example.com",
      "wrong",
      "two",
    )
    == Error(service.Unauthorized)
  let assert Error(service.TooManyRequests(_)) =
    auth.login_password_from(identity, "nobody@example.com", "wrong", "three")
}

pub fn unicode_passwords_and_legacy_hashes_are_upgraded_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let composed = "a café beside the orchard 947!"
  let decomposed = "a cafe\u{0301} beside the orchard 947!"
  let assert Ok(Nil) = auth.set_password(identity, principal, decomposed)
  let assert Ok(_) = auth.login_password(identity, "ada@example.com", composed)
  let assert Ok(_) =
    auth.login_password(identity, "ada@example.com", decomposed)
  // Simulate a pre-normalization, lower-cost stored credential.
  let legacy =
    password_hasher.encode(
      decomposed,
      crypto.strong_random_bytes(16),
      100_000,
      32,
    )
  let _ = credential(database, session.user.id, legacy)
  let assert Ok(_) =
    auth.login_password(identity, "ada@example.com", decomposed)
  let upgraded = stored_hash(database)
  assert upgraded != legacy
  assert string.starts_with(upgraded, "$pbkdf2-sha256$i=600000,l=32$")
  assert password_hasher.pbkdf2_sha256().verify(upgraded, composed) == Ok(True)
  let assert Ok(_) = auth.login_password(identity, "ada@example.com", composed)
  // Once upgraded, ordinary successful logins do not pay for another rehash.
  assert stored_hash(database) == upgraded
}

pub fn common_and_application_breached_password_checks_fail_closed_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let assert Error(service.Coded(_, service.Invalid(_))) =
    auth.register_password(identity, "new@example.com", "passwordpassword")
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let rejected =
    auth.with_password_check(identity, fn(_) {
      Error(service.Invalid("breached password"))
    })
  let assert Error(service.Invalid(_)) =
    auth.set_password(rejected, principal, password)
  let unavailable =
    auth.with_password_check(identity, fn(_) {
      Error(service.Internal("breach check unavailable"))
    })
  let assert Error(service.Internal(_)) =
    auth.set_password(unavailable, principal, password)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_passwords") == 0
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'password.set'",
    )
    == 0
}

pub fn missing_admin_targets_return_not_found_without_events_test() {
  use database, identity, permissions, mailbox <- fixture
  assert auth.suspend(identity, "missing", by: user.System)
    == Error(service.NotFound("user"))
  assert auth.resume(identity, "missing", by: user.System)
    == Error(service.NotFound("user"))
  assert auth.revoke_sessions(identity, "missing", by: user.System)
    == Error(service.NotFound("user"))
  let session = signup(identity, mailbox, "ada@example.com")
  assert access.assign(
      permissions,
      session.user.id,
      "missing",
      access.Global,
      by: user.System,
    )
    == Error(service.NotFound("role"))
  assert access.revoke(
      permissions,
      session.user.id,
      "missing",
      access.Global,
      by: user.System,
    )
    == Error(service.NotFound("role"))
  assert access.assign(
      permissions,
      "missing",
      "missing",
      access.Global,
      by: user.System,
    )
    == Error(service.NotFound("user"))
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action IN ('user.suspended', 'user.resumed', 'sessions.revoked', 'role.assigned', 'role.revoked')",
    )
    == 0
}

pub fn optional_cache_is_invalidated_by_local_grant_changes_test() {
  use _, identity, permissions, mailbox <- fixture
  let assert Ok(cached) = access.with_cache(permissions, 5)
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let assert Ok(Nil) =
    access.define_role(
      permissions,
      access.Global,
      "reader",
      ["read"],
      by: user.System,
    )
  assert access.allowed(cached, principal, "read", access.Global) == Ok(False)
  let assert Ok(Nil) =
    access.assign(
      permissions,
      session.user.id,
      "reader",
      access.Global,
      by: user.System,
    )
  assert access.allowed(cached, principal, "read", access.Global) == Ok(True)
  let assert Ok(Nil) =
    access.revoke(
      permissions,
      session.user.id,
      "reader",
      access.Global,
      by: user.System,
    )
  assert access.allowed(cached, principal, "read", access.Global) == Ok(False)
  let assert Ok(Nil) =
    access.assign(
      permissions,
      session.user.id,
      "reader",
      access.Global,
      by: user.System,
    )
  assert access.allowed(cached, principal, "read", access.Global) == Ok(True)
  let assert Ok(Nil) = auth.suspend(identity, session.user.id, by: user.System)
  assert access.allowed(cached, principal, "read", access.Global) == Ok(False)
}

pub fn optional_cache_expires_external_changes_and_never_stores_errors_test() {
  use database, identity, permissions, mailbox <- fixture
  let assert Ok(cached) = access.with_cache(permissions, 1)
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let assert Ok(Nil) =
    access.define_role(
      permissions,
      access.Global,
      "reader",
      ["read"],
      by: user.System,
    )
  let assert Ok(Nil) =
    access.assign(
      permissions,
      session.user.id,
      "reader",
      access.Global,
      by: user.System,
    )
  assert access.allowed(cached, principal, "read", access.Global) == Ok(True)
  exec(database, "DELETE FROM howdy_authz_assignments")
  assert access.allowed(cached, principal, "read", access.Global) == Ok(True)
  assert access.allowed(permissions, principal, "read", access.Global)
    == Ok(False)
  use <- advance_clock(1100)
  assert access.allowed(cached, principal, "read", access.Global) == Ok(False)
  let memo = cache.new()
  let key = #("a", "b", "c", "d", "e")
  assert cache.run(memo, key, 1, fn() { Error(service.Internal("unavailable")) })
    == Error(service.Internal("unavailable"))
  assert cache.run(memo, key, 1, fn() { Ok(True) }) == Ok(True)
}

pub fn account_page_requires_session_and_exposes_management_controls_test() {
  use _, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let app =
    howdy.new()
    |> howdy.controller(pages.routes(identity, at: "/auth", api_at: "/api/auth"))
  assert testing.get("/auth/account") |> testing.send(app) |> fn(r) { r.status }
    == 401
  let session = signup(identity, mailbox, "ada@example.com")
  let page =
    testing.get("/auth/account")
    |> testing.header(
      "cookie",
      auth.cookie_name(identity) <> "=" <> secret.reveal(session.token),
    )
    |> testing.send(app)
  assert page.status == 200
  assert string.contains(testing.text(page), "password-change")
  assert string.contains(testing.text(page), "refresh-sessions")
  assert !string.contains(testing.text(page), secret.reveal(session.token))
}

pub fn password_routes_use_the_trusted_proxy_key_test() {
  use _, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let assert Ok(Nil) = auth.set_password(identity, principal, password)
  let app =
    howdy.new()
    |> howdy.controller(
      routes.api_limited_by(identity, at: "/auth", key: fn(ctx) {
        gleam_http_request.get_header(ctx.request, "x-trusted-client")
        |> gleam_option.from_result
      }),
    )
  let attempt = fn(client, password) {
    testing.post(
      "/auth/password/token",
      json.object([
        #("email", json.string("ada@example.com")),
        #("password", json.string(password)),
      ]),
    )
    |> testing.from_ip("10.0.0.1")
    |> testing.header("x-trusted-client", client)
    |> testing.send(app)
  }
  list.each(list.repeat(Nil, 5), fn(_) {
    assert attempt("attacker", "wrong").status == 401
  })
  assert attempt("attacker", password).status == 429
  assert attempt("victim", password).status == 200
}

pub fn concurrent_password_guesses_cannot_bypass_the_pair_budget_test() {
  use _, identity, _, _ <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let assert Ok(identity) =
    auth.with_policy(
      identity,
      policy.Policy(..policy.default(), password_attempts: 2),
    )
  let replies = process.new_subject()
  list.each(list.repeat(Nil, 8), fn(_) {
    let _ =
      process.spawn(fn() {
        process.send(
          replies,
          auth.login_password_from(
            identity,
            "unknown@example.com",
            "wrong",
            "client",
          ),
        )
      })
  })
  let answers =
    list.map(list.repeat(Nil, 8), fn(_) {
      let assert Ok(answer) = process.receive(replies, 5000)
      case answer {
        Error(service.Unauthorized) -> True
        Error(service.TooManyRequests(_)) -> False
        _ -> panic as "unexpected password result"
      }
    })
  assert list.length(list.filter(answers, fn(allowed) { allowed })) == 2
}

pub fn in_flight_cache_read_cannot_restore_a_revoked_generation_test() {
  let memo = cache.new()
  let key = #("user", "session", "scope", "query", "permission")
  let loaded = process.new_subject()
  let finished = process.new_subject()
  let _ =
    process.spawn(fn() {
      let result =
        cache.run(memo, key, 30, fn() {
          let resume = process.new_subject()
          process.send(loaded, resume)
          let assert Ok(Nil) = process.receive(resume, 1000)
          Ok(True)
        })
      process.send(finished, result)
    })
  let assert Ok(resume) = process.receive(loaded, 1000)
  cache.invalidate()
  process.send(resume, Nil)
  let assert Ok(Ok(True)) = process.receive(finished, 1000)
  assert cache.run(memo, key, 30, fn() { Ok(False) }) == Ok(False)
}

pub fn stronger_hash_costs_are_preserved_during_normalization_upgrade_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let assert Ok(Nil) = auth.set_password(identity, principal, password)
  let decomposed = "a cafe\u{0301} beside the orchard 947!"
  let legacy =
    password_hasher.encode(
      decomposed,
      crypto.strong_random_bytes(16),
      700_000,
      48,
    )
  let _ = credential(database, session.user.id, legacy)
  let assert Ok(_) =
    auth.login_password(identity, "ada@example.com", decomposed)
  let upgraded = stored_hash(database)
  assert string.starts_with(upgraded, "$pbkdf2-sha256$i=700000,l=48$")
  assert password_hasher.pbkdf2_sha256().verify(
      upgraded,
      "a café beside the orchard 947!",
    )
    == Ok(True)
  let assert Ok(_) =
    auth.login_password(
      identity,
      "ada@example.com",
      "a café beside the orchard 947!",
    )
  assert stored_hash(database) == upgraded
}
