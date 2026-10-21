//// Password lifecycle, session management, policy, audit detail and operator
//// tooling added after the first review.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gloo/repo
import howdy
import howdy/auth
import howdy/auth/policy
import howdy/auth/routes
import howdy/auth/secret
import howdy/auth/user
import howdy/authorization as access
import howdy/migration
import howdy/service
import howdy/testing
import support.{count, exec, fixture, signup}

const strong_password = "an uncommon orchard phrase 947!"

const other_password = "a totally different password"

fn email_login(
  identity: auth.Auth,
  mailbox: process.Subject(auth.Delivery),
  database: repo.Repo,
  email: String,
) -> auth.Session {
  exec(database, "DELETE FROM howdy_auth_throttles")
  let assert Ok(Nil) = auth.request_token(identity, email, auth.Login)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let assert Ok(session) =
    auth.exchange(identity, secret.reveal(delivery.token))
  session
}

pub fn email_only_user_adds_then_replaces_a_password_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let assert Ok(Nil) = auth.set_password(identity, principal, strong_password)
  let assert Ok(_) =
    auth.login_password(identity, "ada@example.com", strong_password)
  // Reset: a new email-token session replaces the forgotten password.
  let fresh = email_login(identity, mailbox, database, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(fresh.token))
  let assert Ok(Nil) = auth.set_password(identity, principal, other_password)
  assert auth.login_password(identity, "ada@example.com", strong_password)
    == Error(service.Unauthorized)
  let assert Ok(_) =
    auth.login_password(identity, "ada@example.com", other_password)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_passwords") == 1
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'password.set' AND actor_id = user_id",
    )
    == 2
}

pub fn setting_a_password_revokes_every_other_session_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let old = signup(identity, mailbox, "ada@example.com")
  let fresh = email_login(identity, mailbox, database, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(fresh.token))
  let assert Ok(Nil) = auth.set_password(identity, principal, strong_password)
  assert auth.authenticate(identity, secret.reveal(old.token))
    == Error(service.Unauthorized)
  let assert Ok(_) = auth.authenticate(identity, secret.reveal(fresh.token))
}

pub fn password_change_needs_a_fresh_email_token_session_test() {
  use database, identity, _, mailbox <- fixture
  let plain = identity
  let assert Ok(identity) = auth.with_passwords(identity)
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  assert auth.set_password(plain, principal, strong_password)
    == Error(service.Forbidden)
  let assert Error(service.Coded(_, service.Invalid(_))) =
    auth.set_password(identity, principal, "short")
  let assert Ok(Nil) = auth.set_password(identity, principal, strong_password)
  // A password session proves knowledge of the old password only.
  let assert Ok(by_password) =
    auth.login_password(identity, "ada@example.com", strong_password)
  let assert Ok(password_principal) =
    auth.authenticate(identity, secret.reveal(by_password.token))
  assert auth.set_password(identity, password_principal, other_password)
    == Error(service.Forbidden)
  // An email-token session stops qualifying once it is no longer fresh.
  exec(database, "UPDATE howdy_auth_sessions SET created_at = created_at - 601")
  assert auth.set_password(identity, principal, other_password)
    == Error(service.Forbidden)
  let assert Ok(_) =
    auth.login_password(identity, "ada@example.com", strong_password)
}

pub fn failed_exchange_spends_the_token_test() {
  use database, identity, _, mailbox <- fixture
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(Nil) = auth.suspend(identity, session.user.id, by: user.System)
  exec(database, "DELETE FROM howdy_auth_throttles")
  let assert Ok(Nil) =
    auth.request_token(identity, "ada@example.com", auth.Login)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert auth.exchange(identity, secret.reveal(delivery.token))
    == Error(service.Unauthorized)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_challenges") == 0
  // Resuming the account must not revive a token that already failed.
  let assert Ok(Nil) = auth.resume(identity, session.user.id, by: user.System)
  assert auth.exchange(identity, secret.reveal(delivery.token))
    == Error(service.Unauthorized)
}

pub fn users_list_and_revoke_only_their_own_sessions_test() {
  use database, identity, _, mailbox <- fixture
  let first = signup(identity, mailbox, "ada@example.com")
  let second = email_login(identity, mailbox, database, "ada@example.com")
  let other = signup(identity, mailbox, "grace@example.com")
  let assert Ok(ada) = auth.authenticate(identity, secret.reveal(second.token))
  let assert Ok(grace) = auth.authenticate(identity, secret.reveal(other.token))
  let assert Ok(listed) = auth.sessions(identity, ada)
  assert list.length(listed) == 2
  let assert [current] = list.filter(listed, fn(s) { s.current })
  assert current.id == ada.session_id
  assert list.all(listed, fn(s) { s.method == auth.EmailToken })
  assert list.all(listed, fn(s) { s.created_at > 0 && s.expires_at > 0 })
  let assert [stale] = list.filter(listed, fn(s) { !s.current })
  // Grace cannot revoke Ada's session, even knowing its id.
  let assert Ok(Nil) = auth.revoke_session(identity, grace, stale.id)
  let assert Ok(_) = auth.authenticate(identity, secret.reveal(first.token))
  let assert Ok(Nil) = auth.revoke_session(identity, ada, stale.id)
  assert auth.authenticate(identity, secret.reveal(first.token))
    == Error(service.Unauthorized)
  let assert Ok(_) = auth.authenticate(identity, secret.reveal(second.token))
  let assert Ok([_]) = auth.sessions(identity, ada)
}

pub fn policy_controls_lifetimes_and_idle_timeout_test() {
  use database, identity, _, mailbox <- fixture
  let assert Error(service.Invalid(_)) =
    auth.with_policy(
      identity,
      policy.Policy(..policy.default(), session_seconds: 0),
    )
  let assert Error(service.Invalid(_)) =
    auth.with_policy(
      identity,
      policy.Policy(..policy.default(), session_idle_seconds: 30),
    )
  let assert Ok(identity) =
    auth.with_policy(
      identity,
      policy.Policy(
        ..policy.default(),
        session_seconds: 3600,
        session_idle_seconds: 600,
        live_challenges: 1,
        // Send on every request, so this exercises the one-token limit.
        email_coalesce_margin_seconds: policy.default().challenge_seconds,
      ),
    )
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let assert Ok([info]) = auth.sessions(identity, principal)
  assert info.expires_at - info.created_at == 3600
  // Recently used: still valid, and the use is recorded.
  exec(
    database,
    "UPDATE howdy_auth_sessions SET last_seen_at = last_seen_at - 300",
  )
  let assert Ok(_) = auth.authenticate(identity, secret.reveal(session.token))
  let assert Ok([touched]) = auth.sessions(identity, principal)
  assert touched.last_seen_at >= info.last_seen_at
  // Idle for longer than the policy allows.
  exec(
    database,
    "UPDATE howdy_auth_sessions SET last_seen_at = last_seen_at - 601",
  )
  assert auth.authenticate(identity, secret.reveal(session.token))
    == Error(service.Unauthorized)
  // live_challenges: 1 restores replace-on-request for apps that want it.
  exec(database, "DELETE FROM howdy_auth_throttles")
  let assert Ok(Nil) =
    auth.request_token(identity, "ada@example.com", auth.Login)
  let assert Ok(first) = process.receive(mailbox, 1000)
  exec(database, "DELETE FROM howdy_auth_throttles")
  let assert Ok(Nil) =
    auth.request_token(identity, "ada@example.com", auth.Login)
  let assert Ok(_) = process.receive(mailbox, 1000)
  assert auth.exchange(identity, secret.reveal(first.token))
    == Error(service.Unauthorized)
}

pub fn password_policy_limits_and_success_resets_attempts_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let assert Ok(identity) =
    auth.with_policy(
      identity,
      policy.Policy(
        ..policy.default(),
        password_attempts: 2,
        password_window_seconds: 120,
        password_min_length: 20,
      ),
    )
  let assert Error(service.Coded(_, service.Invalid(_))) =
    auth.register_password(identity, "ada@example.com", "only 16 characters")
  let assert Ok(Nil) =
    auth.register_password(identity, "ada@example.com", strong_password)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let assert Ok(_) = auth.exchange(identity, secret.reveal(delivery.token))
  assert auth.login_password(identity, "ada@example.com", "wrong")
    == Error(service.Unauthorized)
  // A correct login clears the counter, so honest typos do not accumulate.
  let assert Ok(_) =
    auth.login_password(identity, "ada@example.com", strong_password)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_password_attempts")
    == 0
  assert auth.login_password(identity, "ada@example.com", "wrong")
    == Error(service.Unauthorized)
  assert auth.login_password(identity, "ada@example.com", "wrong")
    == Error(service.Unauthorized)
  let assert Error(service.TooManyRequests(wait)) =
    auth.login_password(identity, "ada@example.com", strong_password)
  assert wait > 0 && wait <= 120
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'login.failed'",
    )
    == 3
}

pub fn audit_events_record_actor_and_detail_and_can_be_pruned_test() {
  use database, identity, permissions, mailbox <- fixture
  let admin = signup(identity, mailbox, "admin@example.com")
  let target = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(admin.token))
  let acting = user.Acting(principal)
  let assert Ok(Nil) =
    access.define_role(
      permissions,
      access.Organization("acme"),
      "editor",
      ["write"],
      by: acting,
    )
  let assert Ok(Nil) =
    access.assign(
      permissions,
      target.user.id,
      "editor",
      access.Organization("acme"),
      by: acting,
    )
  let assert Ok(Nil) = auth.suspend(identity, target.user.id, by: acting)
  let row = {
    use action <- decode.field(0, decode.string)
    use actor <- decode.field(1, decode.string)
    use detail <- decode.field(2, decode.string)
    decode.success(#(action, actor, detail))
  }
  let assert Ok(events) =
    repo.all(
      database,
      "SELECT action, actor_id, detail FROM howdy_auth_events WHERE actor_id <> '' ORDER BY action",
      [],
      row,
    )
  assert events
    == [
      #("role.assigned", admin.user.id, "org:acme:editor"),
      #("role.defined", admin.user.id, "org:acme:editor"),
      #("user.suspended", admin.user.id, ""),
    ]
  exec(
    database,
    "UPDATE howdy_auth_events SET occurred_at = 100 WHERE action = 'user.suspended'",
  )
  let assert Ok(Nil) = auth.prune_events(identity, before: 101)
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'user.suspended'",
    )
    == 0
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_events") > 0
}

pub fn prune_expired_clears_every_stale_row_test() {
  use database, identity, _, mailbox <- fixture
  let _ = signup(identity, mailbox, "ada@example.com")
  let assert Ok(Nil) =
    auth.request_token(identity, "other@example.com", auth.Login)
  exec(database, "UPDATE howdy_auth_sessions SET expires_at = 0")
  exec(database, "UPDATE howdy_auth_challenges SET expires_at = 0")
  exec(database, "UPDATE howdy_auth_throttles SET next_at = 0")
  let assert Ok(Nil) = auth.prune_expired(identity)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_sessions") == 0
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_challenges") == 0
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_throttles") == 0
}

pub fn operators_may_add_plain_indexes_but_not_constraints_test() {
  use database, _, _, _ <- fixture
  exec(database, "CREATE INDEX ops_events_action ON howdy_auth_events(action)")
  assert migration.check(database, auth.schema()) == Ok(Nil)
  assert migration.run(database, [auth.schema(), access.schema()]) == Ok(Nil)
  // A unique index changes what the table accepts: still drift.
  exec(
    database,
    "CREATE UNIQUE INDEX ops_events_unique ON howdy_auth_events(action, occurred_at)",
  )
  let assert Error(_) = migration.check(database, auth.schema())
}

pub fn rebaseline_accepts_reviewed_drift_but_not_wrong_history_test() {
  use database, _, _, _ <- fixture
  exec(
    database,
    "CREATE INDEX howdy_auth_operator_index ON howdy_auth_events(action)",
  )
  let assert Error(_) = migration.check(database, auth.schema())
  let migration.Package(name, migrations) = auth.schema()
  let older = migration.Package(name, list.take(migrations, 1))
  let assert Error(_) = migration.rebaseline(database, older)
  let assert Error(_) = migration.check(database, auth.schema())
  let assert Ok(Nil) = migration.rebaseline(database, auth.schema())
  assert migration.check(database, auth.schema()) == Ok(Nil)
  let assert Ok(_) =
    auth.new(database, "https://example.test", fn(_) { Ok(Nil) })
}

pub fn password_and_session_endpoints_test() {
  use _, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let app =
    howdy.new() |> howdy.controller(routes.api(identity, at: "/api/auth"))
  let session = signup(identity, mailbox, "ada@example.com")
  let bearer = fn(request, secret) {
    testing.header(request, "authorization", "Bearer " <> secret)
  }
  let password = json.object([#("password", json.string(strong_password))])
  assert testing.post("/api/auth/password", password)
    |> testing.send(app)
    |> fn(r) { r.status }
    == 401
  assert testing.post("/api/auth/password", password)
    |> bearer(secret.reveal(session.token))
    |> testing.send(app)
    |> fn(r) { r.status }
    == 204
  let assert Ok(by_password) =
    auth.login_password(identity, "ada@example.com", strong_password)
  assert testing.post("/api/auth/password", password)
    |> bearer(secret.reveal(by_password.token))
    |> testing.send(app)
    |> fn(r) { r.status }
    == 403
  let listing =
    testing.get("/api/auth/sessions")
    |> bearer(secret.reveal(session.token))
    |> testing.send(app)
  assert listing.status == 200
  let entry = {
    use id <- decode.field("id", decode.string)
    use current <- decode.field("current", decode.bool)
    use method <- decode.field("method", decode.string)
    decode.success(#(id, current, method))
  }
  let assert Ok(entries) = testing.json(listing, decode.list(entry))
  let assert [#(id, False, "password")] = list.filter(entries, fn(e) { !e.1 })
  assert !list.any(entries, fn(e) { e.0 == secret.reveal(session.token) })
  assert testing.post(
      "/api/auth/sessions/revoke",
      json.object([#("id", json.string(id))]),
    )
    |> bearer(secret.reveal(session.token))
    |> testing.send(app)
    |> fn(r) { r.status }
    == 204
  assert auth.authenticate(identity, secret.reveal(by_password.token))
    == Error(service.Unauthorized)
  let assert Ok(_) = auth.authenticate(identity, secret.reveal(session.token))
}
