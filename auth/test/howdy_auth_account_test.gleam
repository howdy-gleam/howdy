//// Account lifecycle through the same headless and HTTP interfaces apps use.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gloo/repo
import gloo/sql
import howdy/auth
import howdy/auth/field
import howdy/auth/group
import howdy/auth/groups
import howdy/auth/internal/database as db
import howdy/auth/internal/token
import howdy/auth/provider
import howdy/auth/secret
import howdy/auth/session_store
import howdy/auth/user
import howdy/auth/users
import howdy/authorization as access
import howdy/migration
import howdy/service
import howdy/testing
import support.{app, count, exec, fixture, signup}

const password = "a distant orchard with seven moons 839!"

const issuer = "https://identity.example.test"

const callback = "/auth/providers/test/callback"

fn principal(identity, session: auth.Session) {
  let assert Ok(p) = auth.authenticate(identity, secret.reveal(session.token))
  p
}

fn login(identity, mailbox: process.Subject(auth.Delivery), email) {
  let assert Ok(_) = auth.request_token(identity, email, auth.Login)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let assert Ok(session) =
    auth.exchange(identity, secret.reveal(delivery.token))
  session
}

fn change_token(identity, p, mailbox: process.Subject(auth.Delivery), email) {
  let assert Ok(_) = auth.request_email_change(identity, p, email)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert delivery.email == email
  assert delivery.purpose == auth.EmailChange
  secret.reveal(delivery.token)
}

// A completed change tells the old address, exactly once.
fn changed_notice(mailbox: process.Subject(auth.Delivery), old: String) {
  let assert Ok(notice) = process.receive(mailbox, 1000)
  assert notice.email == old
  assert notice.purpose == auth.EmailChanged
  assert secret.reveal(notice.token) == ""
}

fn configured(identity) {
  // Protocol verification has its own signed-provider suite. This adapter
  // supplies a verified identity so these tests exercise local account policy.
  let p =
    provider.new("test", "Test provider", Ok(Nil), fn(a) { a.state }, fn(_) {
      Ok(provider.Identity(issuer, "subject-ada", "ada@example.com", True, None))
    })
  let assert Ok(identity) = auth.with_provider(identity, p)
  identity
}

fn linked(identity, p) {
  let assert Ok(start) = auth.begin_provider_link(identity, p, "test", callback)
  assert auth.finish_provider(
      identity,
      "test",
      callback,
      start.url,
      secret.reveal(start.browser_token),
      Some("verified"),
      Some(p),
    )
    == Ok(auth.ProviderLinked)
}

fn provider_login(identity) {
  let assert Ok(start) =
    auth.begin_provider(identity, "test", callback, "client")
  let assert Ok(auth.ProviderSession(session)) =
    auth.finish_provider(
      identity,
      "test",
      callback,
      start.url,
      secret.reveal(start.browser_token),
      Some("verified"),
      None,
    )
  session
}

pub fn email_change_verifies_new_mailbox_and_revokes_all_sessions_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let first = signup(identity, mailbox, "ada@example.com")
  let p = principal(identity, first)
  assert auth.set_password(identity, p, password) == Ok(Nil)
  let second = login(identity, mailbox, "ada@example.com")
  let proof = change_token(identity, p, mailbox, "new@example.com")
  assert auth.exchange(identity, proof) == Error(service.Unauthorized)
  let assert Ok(old) = users.get(identity, first.user.id)
  assert old.email == "ada@example.com"
  let assert Ok([stored]) =
    repo.all(
      database,
      "SELECT digest FROM howdy_auth_email_changes",
      [],
      decode.field(0, decode.string, decode.success),
    )
  assert stored != proof
  // A pending login token for the old address must not survive the change.
  assert auth.request_token(identity, "ada@example.com", auth.Login) == Ok(Nil)
  let assert Ok(pending) = process.receive(mailbox, 1000)
  assert auth.confirm_email_change(identity, p, proof) == Ok(Nil)
  assert auth.confirm_email_change(identity, p, proof)
    == Error(service.Unauthorized)
  assert auth.authenticate(identity, secret.reveal(first.token))
    == Error(service.Unauthorized)
  assert auth.authenticate(identity, secret.reveal(second.token))
    == Error(service.Unauthorized)
  assert auth.exchange(identity, secret.reveal(pending.token))
    == Error(service.Unauthorized)
  assert auth.login_password(identity, "ada@example.com", password)
    == Error(service.Unauthorized)
  let assert Ok(session) =
    auth.login_password(identity, "new@example.com", password)
  assert session.user.id == first.user.id
  assert session.user.email == "new@example.com"
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_identities WHERE subject = 'new@example.com'",
    )
    == 1
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'email.changed' AND detail = ''",
    )
    == 1
}

pub fn email_confirmation_is_bound_to_requesting_session_and_current_state_test() {
  use database, identity, _, mailbox <- fixture
  let first = signup(identity, mailbox, "ada@example.com")
  let p = principal(identity, first)
  let other = principal(identity, login(identity, mailbox, "ada@example.com"))
  let proof = change_token(identity, p, mailbox, "new@example.com")
  assert auth.confirm_email_change(identity, other, proof)
    == Error(service.Unauthorized)
  // A different session cannot spend the owner's proof.
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_email_changes") == 1
  exec(database, "UPDATE howdy_auth_sessions SET created_at = 0")
  assert auth.confirm_email_change(identity, p, proof)
    == Error(service.Forbidden)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_email_changes") == 0
  let assert Ok(old) = users.get(identity, first.user.id)
  assert old.email == "ada@example.com"
  assert auth.request_email_change(identity, p, "new@example.com")
    == Error(service.Forbidden)
}

pub fn email_changes_respect_expiry_revocation_delivery_and_throttling_test() {
  use database, identity, _, mailbox <- fixture
  let session = signup(identity, mailbox, "ada@example.com")
  let p = principal(identity, session)
  let proof = change_token(identity, p, mailbox, "new@example.com")
  let assert Error(service.TooManyRequests(_)) =
    auth.request_email_change(identity, p, "another@example.com")
  exec(database, "UPDATE howdy_auth_email_changes SET expires_at = 0")
  assert auth.confirm_email_change(identity, p, proof)
    == Error(service.Unauthorized)
  assert auth.prune_expired(identity) == Ok(Nil)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_email_changes") == 0
  exec(database, "DELETE FROM howdy_auth_throttles")
  let assert Ok(failing) =
    auth.new(database, "https://example.test", fn(_) { Error(Nil) })
  assert auth.request_email_change(failing, p, "new@example.com")
    == Error(service.Internal("auth email delivery failed"))
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_email_changes") == 0
  exec(database, "DELETE FROM howdy_auth_throttles")
  let proof = change_token(identity, p, mailbox, "new@example.com")
  assert auth.logout(identity, p) == Ok(Nil)
  assert auth.confirm_email_change(identity, p, proof)
    == Error(service.Unauthorized)
}

pub fn email_uniqueness_is_rechecked_and_group_scoped_test() {
  use database, identity, _, mailbox <- fixture
  let session = signup(identity, mailbox, "ada@example.com")
  let p = principal(identity, session)
  let proof = change_token(identity, p, mailbox, "taken@example.com")
  let _ = signup(identity, mailbox, "taken@example.com")
  let assert Error(service.Coded(_, service.Conflict(_))) =
    auth.confirm_email_change(identity, p, proof)
  let assert Ok(old) = users.get(identity, session.user.id)
  assert old.email == "ada@example.com"
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_email_changes") == 0
  let assert Ok(identity) = auth.with_groups(identity, group.AccountPerGroup)
  let assert Ok(_) =
    groups.create_with_id(identity, "other", "Other", by: user.System)
  let other = auth.in_group(identity, "other")
  let other_session = signup(other, mailbox, "other@example.com")
  let other_p = principal(other, other_session)
  let proof = change_token(other, other_p, mailbox, "ada@example.com")
  assert auth.confirm_email_change(other, other_p, proof) == Ok(Nil)
  let assert Ok(changed) = users.get(other, other_session.user.id)
  assert changed.email == "ada@example.com"
  assert auth.request_email_change(
      auth.in_group(identity, "other"),
      p,
      "bad@example.com",
    )
    == Error(service.Unauthorized)
}

pub fn account_changes_fail_closed_when_external_revocation_fails_test() {
  use _, identity, _, mailbox <- fixture
  let store = session_store.memory()
  let working = auth.with_session_store(identity, store)
  let failing =
    auth.with_session_store(
      identity,
      session_store.SessionStore(..store, delete_for_user: fn(_, _) {
        Error(service.Internal("offline"))
      }),
    )
  let session = signup(working, mailbox, "ada@example.com")
  let p = principal(working, session)
  let assert Ok(Some(old)) = store.get(p.session_id)
  let proof = change_token(working, p, mailbox, "new@example.com")
  assert auth.confirm_email_change(failing, p, proof)
    == Error(service.Internal("offline"))
  // The change committed, so the old address still hears about it.
  changed_notice(mailbox, "ada@example.com")
  assert auth.authenticate(working, secret.reveal(session.token))
    == Error(service.Unauthorized)
  // Simulate a delayed write from a sign-in that committed before the change.
  assert store.insert(old) == Ok(Nil)
  assert auth.authenticate(working, secret.reveal(session.token))
    == Error(service.Unauthorized)
  let fresh = login(working, mailbox, "new@example.com")
  let p = principal(working, fresh)
  let assert Ok([_]) = auth.sessions(working, p)
  let deletable = auth.with_account_deletion(failing, fn(_, _) { Ok(Nil) })
  assert auth.delete_account(deletable, p, "new@example.com")
    == Error(service.Internal("offline"))
  assert auth.authenticate(working, secret.reveal(fresh.token))
    == Error(service.Unauthorized)
}

pub fn deletion_requires_opt_in_fresh_proof_and_rolls_back_cleanup_failure_test() {
  use database, identity, _, mailbox <- fixture
  let session = signup(identity, mailbox, "ada@example.com")
  let p = principal(identity, session)
  assert auth.delete_account(identity, p, "ada@example.com")
    == Error(service.Forbidden)
  exec(
    database,
    "CREATE TABLE app_profiles (user_id TEXT REFERENCES howdy_auth_users(id), name TEXT)",
  )
  let assert Ok(_) =
    repo.execute(
      database,
      "INSERT INTO app_profiles(user_id, name) VALUES ($1, 'Ada')",
      [sql.string(session.user.id)],
    )
  let failing =
    auth.with_account_deletion(identity, fn(conn, _) {
      let assert Ok(_) = repo.execute(conn, "DELETE FROM app_profiles", [])
      Error(service.Forbidden)
    })
  assert auth.delete_account(failing, p, "wrong@example.com")
    == Error(service.Coded(
      "email_mismatch",
      service.Invalid("confirm your current email address"),
    ))
  assert auth.delete_account(failing, p, "ada@example.com")
    == Error(service.Forbidden)
  assert count(database, "SELECT COUNT(*) FROM app_profiles") == 1
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'user.deleted'",
    )
    == 0
  let no_cleanup = auth.with_account_deletion(identity, fn(_, _) { Ok(Nil) })
  let assert Error(_) = auth.delete_account(no_cleanup, p, "ada@example.com")
  let assert Ok(_) = auth.authenticate(identity, secret.reveal(session.token))
  let deletable =
    auth.with_account_deletion(identity, fn(conn, u) {
      db.execute(conn, "DELETE FROM app_profiles WHERE user_id = $1", [
        sql.string(u.id),
      ])
    })
  exec(database, "UPDATE howdy_auth_sessions SET created_at = 0")
  assert auth.delete_account(deletable, p, "ada@example.com")
    == Error(service.Forbidden)
  let p = principal(identity, login(identity, mailbox, "ada@example.com"))
  assert auth.delete_account(deletable, p, "ada@example.com") == Ok(Nil)
  assert count(database, "SELECT COUNT(*) FROM app_profiles") == 0
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 0
}

pub fn deletion_removes_credentials_fields_links_roles_and_pending_work_test() {
  use database, identity, permissions, mailbox <- fixture
  let identity = configured(identity)
  let assert Ok(identity) = auth.with_passwords(identity)
  let identity = auth.with_account_deletion(identity, fn(_, _) { Ok(Nil) })
  let session = signup(identity, mailbox, "ada@example.com")
  let p = principal(identity, session)
  assert auth.set_password(identity, p, password) == Ok(Nil)
  linked(identity, p)
  let assert Ok(_) =
    users.update(
      identity,
      p.user.id,
      [field.set(field.text("name"), "Ada")],
      by: user.System,
    )
  let assert Ok(_) =
    access.define_role(
      permissions,
      access.Global,
      "reader",
      ["read"],
      by: user.System,
    )
  let assert Ok(_) =
    access.assign(
      permissions,
      p.user.id,
      "reader",
      access.Global,
      by: user.System,
    )
  let proof = change_token(identity, p, mailbox, "new@example.com")
  let assert Ok(_) = auth.begin_provider_link(identity, p, "test", callback)
  assert auth.request_token(identity, "ada@example.com", auth.Login) == Ok(Nil)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert auth.delete_account(identity, p, "ada@example.com") == Ok(Nil)
  list.each(
    [
      "users",
      "identities",
      "provider_identities",
      "provider_attempts",
      "passwords",
      "sessions",
      "user_fields",
      "email_changes",
      "challenges",
    ],
    fn(table) {
      assert count(database, "SELECT COUNT(*) FROM howdy_auth_" <> table) == 0
    },
  )
  assert count(database, "SELECT COUNT(*) FROM howdy_authz_assignments") == 0
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'user.deleted'",
    )
    == 1
  assert auth.authenticate(identity, secret.reveal(session.token))
    == Error(service.Unauthorized)
  assert auth.exchange(identity, secret.reveal(delivery.token))
    == Error(service.Unauthorized)
  assert auth.confirm_email_change(identity, p, proof)
    == Error(service.Unauthorized)
}

pub fn unlink_requires_a_different_enabled_login_and_revokes_sessions_test() {
  use database, identity, _, mailbox <- fixture
  let identity = configured(identity)
  let session = signup(identity, mailbox, "ada@example.com")
  let p = principal(identity, session)
  linked(identity, p)
  assert auth.linked_providers(identity, p) == Ok([#("test", issuer)])
  let external = provider_login(identity)
  let external_p = principal(identity, external)
  assert auth.unlink_provider(identity, external_p, issuer)
    == Error(service.Forbidden)
  let assert Ok(closed) =
    auth.new_without_email(database, "https://example.test")
  let closed = configured(closed)
  assert auth.unlink_provider(closed, p, issuer) == Error(service.Forbidden)
  assert auth.unlink_provider(closed, external_p, issuer)
    == Error(service.Forbidden)
  let stranger =
    principal(identity, signup(identity, mailbox, "stranger@example.com"))
  assert auth.unlink_provider(identity, stranger, issuer)
    == Error(service.NotFound("provider link"))
  let assert Ok(pending) =
    auth.begin_provider_link(identity, p, "test", callback)
  assert auth.unlink_provider(identity, p, issuer) == Ok(Nil)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_provider_identities")
    == 0
  assert auth.authenticate(identity, secret.reveal(session.token))
    == Error(service.Unauthorized)
  assert auth.authenticate(identity, secret.reveal(external.token))
    == Error(service.Unauthorized)
  assert auth.finish_provider(
      identity,
      "test",
      callback,
      pending.url,
      secret.reveal(pending.browser_token),
      Some("verified"),
      Some(p),
    )
    == Error(service.Unauthorized)
  let fresh = login(identity, mailbox, "ada@example.com")
  assert auth.linked_providers(identity, principal(identity, fresh)) == Ok([])
}

pub fn concurrent_email_confirmation_and_deletion_each_commit_once_test() {
  use database, identity, _, mailbox <- fixture
  let identity = auth.with_account_deletion(identity, fn(_, _) { Ok(Nil) })
  let p = principal(identity, signup(identity, mailbox, "ada@example.com"))
  let proof = change_token(identity, p, mailbox, "new@example.com")
  race(fn() { auth.confirm_email_change(identity, p, proof) })
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'email.changed'",
    )
    == 1
  changed_notice(mailbox, "ada@example.com")
  assert process.receive(mailbox, 0) == Error(Nil)
  let p = principal(identity, login(identity, mailbox, "new@example.com"))
  race(fn() { auth.delete_account(identity, p, "new@example.com") })
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'user.deleted'",
    )
    == 1
}

fn race(run) {
  let replies = process.new_subject()
  let _ = process.spawn(fn() { process.send(replies, run()) })
  let _ = process.spawn(fn() { process.send(replies, run()) })
  let assert Ok(a) = process.receive(replies, 10_000)
  let assert Ok(b) = process.receive(replies, 10_000)
  assert list.length(list.filter([a, b], result.is_ok)) == 1
}

fn post(application, path, cookie, key, value, origin) {
  testing.post("/api/auth" <> path, json.object([#(key, json.string(value))]))
  |> testing.header("cookie", cookie)
  |> testing.header("origin", origin)
  |> testing.send(application)
}

pub fn account_http_routes_enforce_origin_and_clear_cookie_after_success_test() {
  use _, identity, permissions, mailbox <- fixture
  let identity =
    configured(identity) |> auth.with_account_deletion(fn(_, _) { Ok(Nil) })
  let session = signup(identity, mailbox, "ada@example.com")
  let p = principal(identity, session)
  linked(identity, p)
  let cookie = auth.cookie_name(identity) <> "=" <> secret.reveal(session.token)
  let application = app(identity, permissions)
  let origin = "https://example.test"
  assert post(
      application,
      "/email/change",
      cookie,
      "email",
      "new@example.com",
      "https://evil.test",
    ).status
    == 403
  assert post(
      application,
      "/account/delete",
      cookie,
      "email",
      "ada@example.com",
      "",
    ).status
    == 403
  assert post(
      application,
      "/providers/unlink",
      cookie,
      "issuer",
      issuer,
      "https://evil.test",
    ).status
    == 403
  let listing =
    testing.get("/api/auth/providers")
    |> testing.header("cookie", cookie)
    |> testing.send(application)
  assert listing.status == 200
  assert string.contains(testing.text(listing), issuer)
  assert response.get_header(listing, "cache-control") == Ok("no-store")
  let sent =
    post(
      application,
      "/email/change",
      cookie,
      "email",
      "new@example.com",
      origin,
    )
  assert sent.status == 202
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let changed =
    post(
      application,
      "/email/confirm",
      cookie,
      "token",
      secret.reveal(delivery.token),
      origin,
    )
  assert changed.status == 204
  let assert Ok(header) = response.get_header(changed, "set-cookie")
  assert string.contains(header, "Max-Age=0")
  changed_notice(mailbox, "ada@example.com")
  assert post(
      application,
      "/account/delete",
      cookie,
      "email",
      "new@example.com",
      origin,
    ).status
    == 401
  let fresh = login(identity, mailbox, "new@example.com")
  let cookie = auth.cookie_name(identity) <> "=" <> secret.reveal(fresh.token)
  let unlinked =
    post(application, "/providers/unlink", cookie, "issuer", issuer, origin)
  assert unlinked.status == 204
  let fresh = login(identity, mailbox, "new@example.com")
  let cookie = auth.cookie_name(identity) <> "=" <> secret.reveal(fresh.token)
  assert post(
      application,
      "/account/delete",
      cookie,
      "email",
      "new@example.com",
      origin,
    ).status
    == 204
}

pub fn unlink_with_password_survives_external_store_cleanup_failure_test() {
  use _, identity, _, mailbox <- fixture
  let identity = configured(identity)
  let assert Ok(identity) = auth.with_passwords(identity)
  let store = session_store.memory()
  let identity = auth.with_session_store(identity, store)
  let session = signup(identity, mailbox, "ada@example.com")
  let p = principal(identity, session)
  assert auth.set_password(identity, p, password) == Ok(Nil)
  linked(identity, p)
  let assert Ok(session) =
    auth.login_password(identity, "ada@example.com", password)
  let p = principal(identity, session)
  let assert Ok(Some(entry)) = store.get(p.session_id)
  let failing =
    auth.with_session_store(
      identity,
      session_store.SessionStore(..store, delete_for_user: fn(_, _) {
        Error(service.Internal("offline"))
      }),
    )
  assert auth.unlink_provider(failing, p, issuer)
    == Error(service.Internal("offline"))
  assert store.insert(entry) == Ok(Nil)
  assert auth.authenticate(identity, secret.reveal(session.token))
    == Error(service.Unauthorized)
  let assert Ok(fresh) =
    auth.login_password(identity, "ada@example.com", password)
  assert auth.linked_providers(identity, principal(identity, fresh)) == Ok([])
}

pub fn moving_or_suspending_account_cancels_pending_email_changes_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_groups(identity, group.OneGroupPerUser)
  let assert Ok(_) =
    groups.create_with_id(identity, "other", "Other", by: user.System)
  let home = auth.in_group(identity, "default")
  let p = principal(home, signup(home, mailbox, "ada@example.com"))
  let proof = change_token(home, p, mailbox, "new@example.com")
  let assert Ok(_) = groups.move(identity, p.user.id, "other", by: user.System)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_email_changes") == 0
  assert auth.confirm_email_change(identity, p, proof)
    == Error(service.Unauthorized)
  exec(database, "DELETE FROM howdy_auth_throttles")
  let other = auth.in_group(identity, "other")
  let p = principal(other, login(other, mailbox, "ada@example.com"))
  let proof = change_token(other, p, mailbox, "new@example.com")
  assert auth.suspend(identity, p.user.id, by: user.System) == Ok(Nil)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_email_changes") == 0
  assert auth.confirm_email_change(other, p, proof)
    == Error(service.Unauthorized)
  let deletable = auth.with_account_deletion(identity, fn(_, _) { Ok(Nil) })
  assert auth.delete_account(deletable, p, "ada@example.com")
    == Error(service.Unauthorized)
}

pub fn account_migration_preserves_existing_sessions_and_google_links_test() {
  use database <- support.with_repo
  let migration.Package(name, migrations) = auth.schema()
  let previous = migration.Package(name, list.take(migrations, 9))
  assert migration.run(database, [previous]) == Ok(Nil)
  exec(
    database,
    "INSERT INTO howdy_auth_users(id, login_key, email, group_id) VALUES ('legacy-user', 'legacy@example.com', 'legacy@example.com', 'default')",
  )
  exec(
    database,
    "INSERT INTO howdy_auth_provider_identities(issuer, subject, scope, user_id) VALUES ('https://accounts.google.com', 'legacy-subject', '', 'legacy-user')",
  )
  let session = token.new()
  let now = token.now()
  let assert Ok(_) =
    repo.execute(
      database,
      "INSERT INTO howdy_auth_sessions(digest, user_id, expires_at, created_at, last_seen_at, method) VALUES ($1, 'legacy-user', $2, $3, $4, 'email')",
      [
        sql.string(token.digest(session)),
        sql.int(now + 86_400),
        sql.int(now),
        sql.int(now),
      ],
    )
  assert migration.run(database, [auth.schema()]) == Ok(Nil)
  let assert Ok(identity) =
    auth.new(database, "https://example.test", fn(_) { Ok(Nil) })
  let assert Ok(p) = auth.authenticate(identity, session)
  assert p.user.id == "legacy-user"
  assert auth.linked_providers(identity, p)
    == Ok([#("google", "https://accounts.google.com")])
  assert auth.unlink_provider(identity, p, "https://accounts.google.com")
    == Ok(Nil)
  assert auth.authenticate(identity, session) == Error(service.Unauthorized)
}

pub fn completed_email_change_notifies_the_old_address_test() {
  use _, identity, _, mailbox <- fixture
  let p = principal(identity, signup(identity, mailbox, "ada@example.com"))
  let proof = change_token(identity, p, mailbox, "new@example.com")
  assert auth.confirm_email_change(identity, p, "not-the-token-but-long-enough")
    |> result.is_error
  assert process.receive(mailbox, 0) == Error(Nil)
  assert auth.confirm_email_change(identity, p, proof) == Ok(Nil)
  let assert Ok(notice) = process.receive(mailbox, 1000)
  assert notice.email == "ada@example.com"
  assert notice.purpose == auth.EmailChanged
  assert secret.reveal(notice.token) == ""
  // Without approval configured there is no approval step to call.
  assert auth.approve_email_change(identity, p, proof)
    == Error(service.Forbidden)
}

pub fn email_change_approval_asks_the_current_mailbox_first_test() {
  use database, identity, _, mailbox <- fixture
  let identity = auth.with_email_change_approval(identity)
  assert auth.email_change_approval_enabled(identity)
  let first = signup(identity, mailbox, "ada@example.com")
  let p = principal(identity, first)
  let other = principal(identity, login(identity, mailbox, "ada@example.com"))

  let assert Ok(_) = auth.request_email_change(identity, p, "new@example.com")
  let assert Ok(approval) = process.receive(mailbox, 1000)
  assert approval.email == "ada@example.com"
  assert approval.purpose == auth.EmailChangeApproval
  let approval = secret.reveal(approval.token)
  // Nothing reaches the new mailbox until the current one agrees.
  assert process.receive(mailbox, 0) == Error(Nil)

  // The approval token is not a confirmation, a login, or another session's.
  assert auth.confirm_email_change(identity, p, approval)
    == Error(service.Unauthorized)
  assert auth.exchange(identity, approval) == Error(service.Unauthorized)
  assert auth.approve_email_change(identity, other, approval)
    == Error(service.Unauthorized)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_email_changes") == 1

  assert auth.approve_email_change(identity, p, approval) == Ok(Nil)
  assert auth.approve_email_change(identity, p, approval)
    == Error(service.Unauthorized)
  let assert Ok(confirmation) = process.receive(mailbox, 1000)
  assert confirmation.email == "new@example.com"
  assert confirmation.purpose == auth.EmailChange
  let confirmation = secret.reveal(confirmation.token)
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'email.change_approved'",
    )
    == 1
  // Nor does the confirmation token approve anything.
  assert auth.approve_email_change(identity, p, confirmation)
    == Error(service.Unauthorized)
  let assert Ok(unchanged) = users.get(identity, first.user.id)
  assert unchanged.email == "ada@example.com"

  assert auth.confirm_email_change(identity, p, confirmation) == Ok(Nil)
  let assert Ok(notice) = process.receive(mailbox, 1000)
  assert notice.email == "ada@example.com"
  assert notice.purpose == auth.EmailChanged
  let assert Ok(changed) = users.get(identity, first.user.id)
  assert changed.email == "new@example.com"
}

pub fn email_change_approval_rechecks_state_and_fails_closed_test() {
  use database, identity, _, mailbox <- fixture
  let identity = auth.with_email_change_approval(identity)
  let p = principal(identity, signup(identity, mailbox, "ada@example.com"))
  let request = fn(identity) {
    exec(database, "DELETE FROM howdy_auth_throttles")
    let assert Ok(_) = auth.request_email_change(identity, p, "new@example.com")
    let assert Ok(approval) = process.receive(mailbox, 1000)
    secret.reveal(approval.token)
  }

  // The address was taken while the approval was in the inbox.
  let approval = request(identity)
  let _ = signup(identity, mailbox, "new@example.com")
  assert auth.approve_email_change(identity, p, approval)
    == Error(service.Coded(
      "email_taken",
      service.Conflict("email address is unavailable"),
    ))
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_email_changes") == 0
  exec(database, "DELETE FROM howdy_auth_users WHERE email = 'new@example.com'")

  // An expired approval is refused.
  let approval = request(identity)
  exec(database, "UPDATE howdy_auth_email_changes SET expires_at = 1")
  assert auth.approve_email_change(identity, p, approval)
    == Error(service.Unauthorized)

  // A confirmation that cannot be delivered leaves nothing pending.
  let approval = request(identity)
  let assert Ok(failing) =
    auth.new(database, "https://example.test", fn(_) { Error(Nil) })
  let failing = auth.with_email_change_approval(failing)
  assert auth.approve_email_change(failing, p, approval)
    == Error(service.Internal("auth email delivery failed"))
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_email_changes") == 0

  // A session that is no longer fresh cannot approve.
  let approval = request(identity)
  exec(database, "UPDATE howdy_auth_sessions SET created_at = 0")
  assert auth.approve_email_change(identity, p, approval)
    == Error(service.Forbidden)
  assert process.receive(mailbox, 0) == Error(Nil)
}

pub fn email_change_approval_over_http_test() {
  use _, identity, permissions, mailbox <- fixture
  let identity = auth.with_email_change_approval(identity)
  let session = signup(identity, mailbox, "ada@example.com")
  let app = app(identity, permissions)
  let post = fn(path, body) {
    testing.post("/api/auth" <> path, json.object(body))
    |> testing.header("origin", "https://example.test")
    |> testing.cookie("__Host-howdy_session", secret.reveal(session.token))
    |> testing.send(app)
  }
  assert string.contains(
    testing.get("/auth/account")
      |> testing.cookie("__Host-howdy_session", secret.reveal(session.token))
      |> testing.send(app)
      |> testing.text,
    "email-approve",
  )
  let requested = post("/email/change", [#("email", json.string("new@x.test"))])
  assert requested.status == 202
  assert string.contains(testing.text(requested), "current email address")
  let assert Ok(approval) = process.receive(mailbox, 1000)
  assert approval.purpose == auth.EmailChangeApproval
  assert testing.post(
      "/api/auth/email/approve",
      json.object([#("token", json.string(secret.reveal(approval.token)))]),
    )
    |> testing.header("origin", "https://example.test")
    |> testing.send(app)
    |> fn(r) { r.status }
    == 401
  let approved =
    post("/email/approve", [
      #("token", json.string(secret.reveal(approval.token))),
    ])
  assert approved.status == 202
  assert string.contains(testing.text(approved), "new email address")
  let assert Ok(confirmation) = process.receive(mailbox, 1000)
  assert confirmation.email == "new@x.test"
  assert post("/email/confirm", [
      #("token", json.string(secret.reveal(confirmation.token))),
    ]).status
    == 204
}
