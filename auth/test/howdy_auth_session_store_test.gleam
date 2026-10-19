//// Sessions kept outside the database, and provisioning users.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/static_supervisor
import gleam/result
import howdy/auth
import howdy/auth/group
import howdy/auth/groups
import howdy/auth/internal/token
import howdy/auth/policy
import howdy/auth/secret
import howdy/auth/session_store.{
  type Entry, type SessionStore, Entry, SessionStore,
}
import howdy/auth/user
import howdy/service
import support.{count, fixture, signup}

const strong_password = "an uncommon orchard phrase 947!"

fn sign_in(
  identity: auth.Auth,
  mailbox: process.Subject(auth.Delivery),
  email: String,
) {
  let assert Ok(Nil) = auth.request_token(identity, email, auth.Login)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let assert Ok(session) =
    auth.exchange(identity, secret.reveal(delivery.token))
  session
}

/// A store whose removals fail, as when the backend is unreachable.
fn unable_to_remove(store: SessionStore) -> SessionStore {
  let down = fn() { Error(service.Internal("store is down")) }
  SessionStore(..store, delete: fn(_, _) { down() }, delete_for_user: fn(_, _) {
    down()
  })
}

pub fn the_memory_store_meets_the_contract_and_check_catches_a_broken_one_test() {
  let store = session_store.memory()
  assert session_store.check(store) == Ok(Nil)
  let forgetful = SessionStore(..store, touch: fn(_, _, _) { Ok(Nil) })
  assert session_store.check(forgetful)
    == Error(
      "touch must change last_seen_at and leave an unchanged expires_at alone",
    )
  // A store written for the old contract, which ignores the new expiry.
  let unrenewing =
    SessionStore(..store, touch: fn(digest, now, _) {
      let assert Ok(Some(entry)) = store.get(digest)
      store.touch(digest, now, entry.expires_at)
    })
  assert session_store.check(unrenewing)
    == Error("touch must set last_seen_at and expires_at and nothing else")
  let careless =
    SessionStore(..store, delete: fn(digest, _) {
      store.delete(digest, "howdy-check-bob")
    })
  assert session_store.check(careless)
    == Error("delete must not remove another user's record")
  assert session_store.check(unable_to_remove(store))
    == Error("delete_for_user returned an error")
}

@external(erlang, "howdy_auth_test_ffi", "delete_session_tables")
fn delete_session_tables() -> Nil

@external(erlang, "howdy_auth_test_ffi", "kill_session_owners")
fn kill_session_owners() -> Nil

fn eventually(times: Int, holds: fn() -> Bool) -> Bool {
  case holds(), times {
    True, _ -> True
    False, 0 -> False
    False, _ -> {
      process.sleep(10)
      eventually(times - 1, holds)
    }
  }
}

pub fn the_memory_store_outlives_the_process_that_made_it_test() {
  let subject = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      process.send(subject, session_store.memory())
    })
  let assert Ok(store) = process.receive(subject, 1000)
  assert eventually(100, fn() { !process.is_alive(pid) })
  assert session_store.check(store) == Ok(Nil)
}

pub fn a_deleted_table_fails_closed_instead_of_crashing_test() {
  let store = session_store.memory()
  let assert Ok(Nil) = store.insert(entry_for("ada", 4_000_000_000))
  delete_session_tables()
  assert store.get("x") == down()
  assert store.insert(entry_for("ada", 4_000_000_000)) == down()
  assert store.touch("x", 1, 2) == down()
  assert store.list("ada") == down()
  assert store.delete("x", "ada") == down()
  assert store.delete_for_user("ada", None) == down()
  assert store.prune(0) == down()
  // A supervised store fails the same way before its owner has started.
  let #(_, unstarted) = session_store.memory_supervised()
  assert unstarted.get("x") == down()
}

pub fn the_supervised_store_runs_under_a_supervisor_and_survives_restarts_test() {
  let #(child, store) = session_store.memory_supervised()
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(child)
    |> static_supervisor.start
  assert session_store.check(store) == Ok(Nil)
  let assert Ok(Nil) = store.insert(entry_for("ada", 4_000_000_000))
  kill_session_owners()
  // The supervisor brings the owner back with a fresh, empty table.
  assert eventually(100, fn() { store.get("ada") == Ok(None) })
  assert session_store.check(store) == Ok(Nil)
}

fn down() -> service.Result(a) {
  Error(service.Internal("in-memory session store is unavailable"))
}

fn entry_for(user_id: String, expires_at: Int) -> Entry {
  Entry(
    digest: user_id,
    user_id:,
    method: "email",
    created_at: 1,
    last_seen_at: 2,
    expires_at:,
    client: "",
    version: 0,
  )
}

pub fn sessions_live_in_the_store_and_never_in_the_database_test() {
  use database, identity, _, mailbox <- fixture
  let store = session_store.memory()
  let identity = auth.with_session_store(identity, store)
  let first = signup(identity, mailbox, "ada@example.com")
  let second = sign_in(identity, mailbox, "ada@example.com")
  let bob = signup(identity, mailbox, "bob@example.com")
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_sessions") == 0
  // The store is keyed by digest and never holds the token.
  let assert Ok(None) = store.get(secret.reveal(first.token))
  let assert Ok(Some(entry)) =
    store.get(token.digest(secret.reveal(first.token)))
  assert entry.user_id == first.user.id
  assert entry.method == "email"
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(second.token))
  assert principal.user == first.user
  let assert Ok(listed) = auth.sessions(identity, principal)
  assert list.length(listed) == 2
  assert list.count(listed, fn(s) { s.current }) == 1
  // Another user's session id does nothing; one's own revokes.
  let assert Ok(bobs) = auth.authenticate(identity, secret.reveal(bob.token))
  assert auth.revoke_session(identity, principal, bobs.session_id) == Ok(Nil)
  let assert Ok(_) = auth.authenticate(identity, secret.reveal(bob.token))
  let assert [other] = list.filter(listed, fn(s) { !s.current })
  assert auth.revoke_session(identity, principal, other.id) == Ok(Nil)
  assert auth.authenticate(identity, secret.reveal(first.token))
    == Error(service.Unauthorized)
  assert auth.logout(identity, principal) == Ok(Nil)
  assert auth.authenticate(identity, secret.reveal(second.token))
    == Error(service.Unauthorized)
  // A database session means nothing once the store is elsewhere, and back.
  let assert Ok(database_only) =
    auth.new(database, "https://example.test", fn(_) { Ok(Nil) })
  assert auth.authenticate(database_only, secret.reveal(bob.token))
    == Error(service.Unauthorized)
}

pub fn expiry_idleness_and_pruning_are_enforced_by_the_package_test() {
  use _, identity, _, mailbox <- fixture
  let store = session_store.memory()
  let identity = auth.with_session_store(identity, store)
  let ada = signup(identity, mailbox, "ada@example.com")
  let now = token.now()
  let entry = fn(secret, last_seen_at, expires_at) {
    Entry(
      digest: token.digest(secret),
      user_id: ada.user.id,
      method: "email",
      created_at: now - 10_000,
      last_seen_at:,
      expires_at:,
      client: "",
      version: 0,
    )
  }
  let expired = token.new()
  let idle = token.new()
  let quiet = token.new()
  let assert Ok(Nil) = store.insert(entry(expired, now, now - 1))
  let assert Ok(Nil) = store.insert(entry(idle, now - 5000, now + 9000))
  let assert Ok(Nil) = store.insert(entry(quiet, now - 120, now + 9000))
  assert auth.authenticate(identity, expired) == Error(service.Unauthorized)
  let assert Ok(limited) =
    auth.with_policy(
      identity,
      policy.Policy(..auth.policy(identity), session_idle_seconds: 3600),
    )
  assert auth.authenticate(limited, idle) == Error(service.Unauthorized)
  // Use is recorded in the store.
  let assert Ok(_) = auth.authenticate(limited, quiet)
  let assert Ok(Some(touched)) = store.get(token.digest(quiet))
  assert touched.last_seen_at >= now
  assert auth.prune_expired(identity) == Ok(Nil)
  assert store.get(token.digest(expired)) == Ok(None)
  let assert Ok(principal) = auth.authenticate(identity, quiet)
  let assert Ok(listed) = auth.sessions(identity, principal)
  assert list.length(listed) == 3
}

pub fn passwords_need_a_fresh_email_session_and_revoke_the_rest_test() {
  use _, identity, _, mailbox <- fixture
  let store = session_store.memory()
  let assert Ok(identity) = auth.with_passwords(identity)
  let identity = auth.with_session_store(identity, store)
  let old = signup(identity, mailbox, "ada@example.com")
  let fresh = sign_in(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(fresh.token))
  assert auth.set_password(identity, principal, strong_password) == Ok(Nil)
  assert auth.authenticate(identity, secret.reveal(old.token))
    == Error(service.Unauthorized)
  let assert Ok(by_password) =
    auth.login_password(identity, "ada@example.com", strong_password)
  let assert Ok(weaker) =
    auth.authenticate(identity, secret.reveal(by_password.token))
  assert auth.set_password(identity, weaker, strong_password <> "!")
    == Error(service.Forbidden)
  // Freshness is read from the store's record.
  let assert Ok(Some(entry)) = store.get(principal.session_id)
  let assert Ok(Nil) = store.insert(Entry(..entry, created_at: 0))
  assert auth.set_password(identity, principal, strong_password <> "!")
    == Error(service.Forbidden)
}

pub fn suspension_holds_even_when_the_store_cannot_revoke_test() {
  use _, identity, _, mailbox <- fixture
  let store = session_store.memory()
  let working = auth.with_session_store(identity, store)
  let failing = auth.with_session_store(identity, unable_to_remove(store))
  let ada = signup(working, mailbox, "ada@example.com")
  let secret = secret.reveal(ada.token)
  // The database committed; the caller is told the store did not follow.
  let assert Error(service.Internal(_)) =
    auth.suspend(failing, ada.user.id, by: user.System)
  let assert Ok(Some(_)) = store.get(token.digest(secret))
  assert auth.authenticate(working, secret) == Error(service.Unauthorized)
  // Resuming must not revive it: it refuses until the store can be cleared.
  let assert Error(service.Internal(_)) =
    auth.resume(failing, ada.user.id, by: user.System)
  assert auth.resume(working, ada.user.id, by: user.System) == Ok(Nil)
  assert auth.authenticate(working, secret) == Error(service.Unauthorized)
  let again = sign_in(working, mailbox, "ada@example.com")
  assert auth.revoke_sessions(working, ada.user.id, by: user.System) == Ok(Nil)
  assert auth.authenticate(working, secret.reveal(again.token))
    == Error(service.Unauthorized)
  // A store that cannot take the session fails the sign-in.
  let full =
    SessionStore(..store, insert: fn(_) { Error(service.Internal("full")) })
  let assert Ok(Nil) =
    auth.request_token(working, "ada@example.com", auth.Login)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let assert Error(service.Internal(_)) =
    auth.exchange(
      auth.with_session_store(identity, full),
      secret.reveal(delivery.token),
    )
}

pub fn provisioning_creates_users_without_public_registration_test() {
  use database, _, _, mailbox <- fixture
  let assert Ok(closed) =
    auth.new(database, "https://example.test", fn(delivery) {
      process.send(mailbox, delivery)
      Ok(Nil)
    })
  assert auth.registration_enabled(closed) == False
  let assert Ok(ada) =
    auth.provision(closed, " ADA@Example.com ", by: user.System)
  assert ada
    == user.User(..ada, email: "ada@example.com", group_id: group.default_id)
  let assert Error(service.Coded(_, service.Conflict(_))) =
    auth.provision(closed, "ada@example.com", by: user.System)
  let assert Error(service.Coded(_, service.Invalid(_))) =
    auth.provision(closed, "not an address", by: user.System)
  // Nothing was sent; the user signs in when they are ready.
  assert process.receive(mailbox, 0) == Error(Nil)
  let session = sign_in(closed, mailbox, "ada@example.com")
  assert session.user == ada
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'user.provisioned'",
    )
    == 1
}

pub fn provisioning_follows_the_group_mode_test() {
  use _, identity, _, _ <- fixture
  let assert Ok(identity) = auth.with_groups(identity, group.AccountPerGroup)
  let by = user.System
  let assert Ok(_) = groups.create_with_id(identity, id: "acme", name: "A", by:)
  let assert Ok(_) =
    groups.create_with_id(identity, id: "globex", name: "G", by:)
  let assert Error(service.Coded(_, service.Invalid(_))) =
    auth.provision(identity, "ada@example.com", by:)
  assert auth.provision(
      auth.in_group(identity, "missing"),
      "ada@example.com",
      by:,
    )
    == Error(service.NotFound("group"))
  let assert Ok(first) =
    auth.provision(auth.in_group(identity, "acme"), "ada@example.com", by:)
  let assert Ok(second) =
    auth.provision(auth.in_group(identity, "globex"), "ada@example.com", by:)
  assert first.id != second.id
  assert second.group_id == "globex"
  let assert Error(service.Coded(_, service.Conflict(_))) =
    auth.provision(auth.in_group(identity, "acme"), "ada@example.com", by:)
  // One account per address everywhere once the mode says so.
  let assert Error(service.Conflict(_)) =
    auth.with_groups(identity, group.OneGroupPerUser)
}

const day = 86_400

fn renewing(identity, max: Int) {
  let assert Ok(identity) =
    auth.with_policy(
      identity,
      policy.Policy(
        ..auth.policy(identity),
        session_seconds: 7 * day,
        session_renew_seconds: day,
        session_max_seconds: max,
      ),
    )
  identity
}

pub fn renewal_policy_is_validated_and_sizes_the_cookie_test() {
  use _, identity, _, _ <- fixture
  let with = fn(renew, max) {
    auth.with_policy(
      identity,
      policy.Policy(
        ..policy.default(),
        session_renew_seconds: renew,
        session_max_seconds: max,
      ),
    )
  }
  assert with(59, 0) |> result.is_error
  assert with(day, 0) |> result.is_error
  assert with(3600, day - 1) |> result.is_error
  assert with(0, day - 1) |> result.is_error
  assert auth.session_cookie_seconds(identity) == day
  let assert Ok(capped) = with(3600, 30 * day)
  assert auth.session_cookie_seconds(capped) == 30 * day
  let assert Ok(open) = with(3600, 0)
  assert auth.session_cookie_seconds(open) == 400 * day
  // A ceiling without renewal changes nothing: the session is the cookie.
  let assert Ok(fixed) = with(0, 30 * day)
  assert auth.session_cookie_seconds(fixed) == day
}

// Move one session into the past, as seen by either kind of store.
fn age(database, store: option.Option(SessionStore), digest, by seconds: Int) {
  case store {
    None ->
      support.exec(
        database,
        "UPDATE howdy_auth_sessions SET created_at = created_at - "
          <> int.to_string(seconds)
          <> ", last_seen_at = last_seen_at - "
          <> int.to_string(seconds)
          <> ", expires_at = expires_at - "
          <> int.to_string(seconds),
      )
    Some(store) -> {
      let assert Ok(Some(entry)) = store.get(digest)
      let assert Ok(Nil) =
        store.insert(
          Entry(
            ..entry,
            created_at: entry.created_at - seconds,
            last_seen_at: entry.last_seen_at - seconds,
            expires_at: entry.expires_at - seconds,
          ),
        )
      Nil
    }
  }
}

fn remaining(identity, session: auth.Session) {
  let assert Ok(p) = auth.authenticate(identity, secret.reveal(session.token))
  let assert Ok([info]) = auth.sessions(identity, p)
  info.expires_at - token.now()
}

fn renewal_scenario(database, identity, mailbox, store) {
  let fixed = identity
  let identity = renewing(identity, 10 * day)
  let session = signup(identity, mailbox, "ada@example.com")
  let digest = token.digest(secret.reveal(session.token))
  let near = fn(actual, expected) {
    actual >= expected - 5 && actual <= expected + 5
  }
  assert near(remaining(identity, session), 7 * day)

  // Used within the renewal interval: the expiry is left alone.
  age(database, store, digest, by: day / 2)
  assert near(remaining(identity, session), 7 * day - day / 2)

  // Used after it: a full lifetime from now.
  age(database, store, digest, by: day)
  assert near(remaining(identity, session), 7 * day)

  // Without the policy the same use extends nothing.
  age(database, store, digest, by: 2 * day)
  let fixed = renewing(fixed, 0)
  let assert Ok(fixed) =
    auth.with_policy(
      fixed,
      policy.Policy(..auth.policy(fixed), session_renew_seconds: 0),
    )
  assert near(remaining(fixed, session), 5 * day)

  // A minute from expiry, 8.5 days after creation. A full week would pass the
  // ten-day ceiling, so renewal reaches only that: a day and a half.
  age(database, store, digest, by: 5 * day - 60)
  assert near(remaining(identity, session), day + day / 2 + 60)

  // An expired session is never revived, renewal or not.
  age(database, store, digest, by: 2 * day)
  assert auth.authenticate(identity, secret.reveal(session.token))
    == Error(service.Unauthorized)
}

pub fn database_sessions_renew_on_use_up_to_the_ceiling_test() {
  use database, identity, _, mailbox <- fixture
  renewal_scenario(database, identity, mailbox, None)
}

pub fn external_sessions_renew_on_use_up_to_the_ceiling_test() {
  use database, identity, _, mailbox <- fixture
  let store = session_store.memory()
  let identity = auth.with_session_store(identity, store)
  renewal_scenario(database, identity, mailbox, Some(store))
}
