import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option
import gloo/migration as gm
import gloo/repo
import gloo/sql
import howdy/auth
import howdy/auth/internal/cache
import howdy/auth/internal/database as db
import howdy/auth/internal/password as password_hash
import howdy/auth/internal/store
import howdy/auth/internal/token
import howdy/auth/password_check
import howdy/auth/password_hasher
import howdy/auth/secret
import howdy/auth/user
import howdy/authorization as access
import howdy/database as howdy_database
import howdy/migration
import howdy/service
import support.{fixture, signup}

@external(erlang, "howdy_auth_test_ffi", "count_verifications")
fn count_verifications(run: fn() -> a) -> #(a, Int)

const password = "an uncommon orchard phrase 947!"

pub fn ordinary_auth_traffic_does_not_flush_authorization_cache_test() {
  use _, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let memo = cache.new()
  let key = #("user", "session", "scope", "permission", "read")
  assert cache.run(memo, key, 60, fn() { Ok(True) }) == Ok(True)
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let assert Ok(Nil) = auth.set_password(identity, principal, password)
  assert auth.login_password(identity, "ada@example.com", "wrong")
    == Error(service.Unauthorized)
  let assert Ok(_) = auth.login_password(identity, "ada@example.com", password)
  let assert Ok(Nil) = auth.logout(identity, principal)
  let assert Ok(Nil) = auth.prune_expired(identity)
  assert cache.run(memo, key, 60, fn() { Ok(False) }) == Ok(True)
}

pub fn known_nfc_and_dummy_passwords_use_one_verification_test() {
  use _, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let assert Ok(Nil) = auth.set_password(identity, principal, password)
  let wrong = "wrong cafe\u{0301} password"
  let #(answer, count) =
    count_verifications(fn() {
      auth.login_password(identity, "ada@example.com", wrong)
    })
  assert answer == Error(service.Unauthorized)
  assert count == 1
  let #(answer, count) =
    count_verifications(fn() {
      auth.login_password(identity, "unknown@example.com", wrong)
    })
  assert answer == Error(service.Unauthorized)
  assert count == 1
}

pub fn local_blocklist_normalizes_and_rejects_without_changing_password_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let checker = password_check.blocklist(["another café password"])
  let identity = auth.with_password_check(identity, checker)
  let assert Error(service.Coded(_, service.Invalid(_))) =
    auth.set_password(identity, principal, "another cafe\u{0301} password")
  let assert Error(service.Coded(_, service.Invalid(_))) =
    auth.set_password(identity, principal, "Password123456789!")
  let assert Error(service.Coded(_, service.Invalid(_))) =
    auth.set_password(identity, principal, "aaaaaaaaaaaaaaaaaa")
  assert support.count(database, "SELECT COUNT(*) FROM howdy_auth_passwords")
    == 0
  let assert Ok(Nil) = auth.set_password(identity, principal, password)
  let assert Ok(_) = auth.login_password(identity, "ada@example.com", password)
}

pub fn unknown_normalized_credential_is_marked_without_rehash_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let assert Ok(Nil) =
    auth.set_password(identity, principal, "another café password")
  support.exec(database, "UPDATE howdy_auth_passwords SET normalized = 0")
  let assert Ok([before]) =
    repo.all(
      database,
      "SELECT encoded_hash FROM howdy_auth_passwords",
      [],
      decode.field(0, decode.string, decode.success),
    )
  let assert Ok(_) =
    auth.login_password(
      identity,
      "ada@example.com",
      "another cafe\u{0301} password",
    )
  let assert Ok([after]) =
    repo.all(
      database,
      "SELECT encoded_hash FROM howdy_auth_passwords WHERE normalized = 1",
      [],
      decode.field(0, decode.string, decode.success),
    )
  assert before == after
  let #(answer, count) =
    count_verifications(fn() {
      auth.login_password(
        identity,
        "ada@example.com",
        "wrong cafe\u{0301} password",
      )
    })
  assert answer == Error(service.Unauthorized)
  assert count == 1
}

pub fn migration_preserves_pending_legacy_password_challenges_test() {
  use database <- support.with_repo
  let current = auth.schema()
  let old =
    migration.Package(..current, migrations: list.take(current.migrations, 4))
  let assert Ok(Nil) = migration.run(database, [old])
  let raw = "another cafe\u{0301} password"
  let hasher = password_hasher.pbkdf2_sha256()
  let assert Ok(hash) = hasher.hash(raw)
  let challenge = token.new()
  let assert Ok(_) =
    repo.execute(
      database,
      "INSERT INTO howdy_auth_challenges(digest,email,intent,expires_at,password_hash,created_at) VALUES ($1, 'ada@example.com', 'register', $2, $3, $4)",
      [
        sql.string(token.digest(challenge)),
        sql.int(token.now() + 600),
        sql.string(hash),
        sql.int(token.now()),
      ],
    )
  let assert Ok(Nil) = migration.run(database, [current])
  let assert Ok(identity) =
    auth.new(database, "https://example.test", fn(_) { Ok(Nil) })
  let assert Ok(identity) =
    identity |> auth.allow_registration |> auth.with_passwords
  let assert Ok(_) = auth.exchange(identity, challenge)
  assert support.count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_passwords WHERE normalized = 0",
    )
    == 1
  let #(answer, count) =
    count_verifications(fn() {
      auth.login_password(identity, "ada@example.com", raw)
    })
  let assert Ok(_) = answer
  assert count == 2
  assert support.count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_passwords WHERE normalized = 1",
    )
    == 1
  let #(answer, count) =
    count_verifications(fn() {
      auth.login_password(identity, "ada@example.com", raw)
    })
  let assert Ok(_) = answer
  assert count == 1
  let assert Ok(_) =
    auth.login_password(identity, "ada@example.com", "another café password")
}

pub fn resume_and_permission_replacement_invalidate_cached_answers_test() {
  use _, identity, permissions, mailbox <- fixture
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let assert Ok(cached) = access.with_cache(permissions, 60)
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
  let assert Ok(Nil) =
    access.define_role(
      permissions,
      access.Global,
      "reader",
      [],
      by: user.System,
    )
  assert access.allowed(cached, principal, "read", access.Global) == Ok(False)
  let assert Ok(Nil) = auth.suspend(identity, session.user.id, by: user.System)
  assert access.has_role(cached, principal, "reader", access.Global)
    == Ok(False)
  let assert Ok(Nil) = auth.resume(identity, session.user.id, by: user.System)
  assert access.has_role(cached, principal, "reader", access.Global) == Ok(True)
}

pub fn nested_grant_changes_invalidate_after_outer_commit_and_rollback_test() {
  use database, identity, _, mailbox <- fixture
  let session = signup(identity, mailbox, "ada@example.com")
  list.each([True, False], fn(commit) {
    let memo = cache.new()
    let key = #("user", "session", "scope", "permission", "read")
    let read_finished = process.new_subject()
    let result =
      db.transaction(database, fn(conn) {
        let assert Ok(inner) =
          auth.new(conn, "https://example.test", fn(_) { Ok(Nil) })
        let assert Ok(Nil) =
          auth.suspend(inner, session.user.id, by: user.System)
        // Simulate an independent connection loading the old committed answer
        // after the savepoint finishes but before the outer transaction ends.
        let _ =
          process.spawn(fn() {
            process.send(
              read_finished,
              cache.run(memo, key, 60, fn() { Ok(True) }),
            )
          })
        let assert Ok(Ok(True)) = process.receive(read_finished, 1000)
        case commit {
          True -> Ok(Nil)
          False -> Error(service.Forbidden)
        }
      })
    assert result
      == case commit {
        True -> Ok(Nil)
        False -> Error(service.Forbidden)
      }
    assert cache.run(memo, key, 60, fn() { Ok(False) }) == Ok(False)
    let assert Ok(Nil) = auth.resume(identity, session.user.id, by: user.System)
  })
}

pub fn data_migrations_invalidate_authorization_cache_test() {
  use database, identity, permissions, mailbox <- fixture
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let assert Ok(cached) = access.with_cache(permissions, 60)
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
  let data_change =
    migration.Package("operator", [
      gm.new(1, "suspend_accounts", "UPDATE howdy_auth_users SET suspended = 1"),
    ])
  let assert Ok(Nil) = migration.run(database, [data_change])
  assert access.allowed(cached, principal, "read", access.Global) == Ok(False)
}

pub fn application_owned_changes_invalidate_after_callback_completion_test() {
  let memo = cache.new()
  let key = #("user", "session", "scope", "permission", "read")
  assert cache.run(memo, key, 60, fn() { Ok(True) }) == Ok(True)
  access.with_changes(fn() {
    // A transactional read cannot return the pre-transaction cached grant.
    assert cache.run(memo, key, 60, fn() { Ok(False) }) == Ok(False)
  })
  assert cache.run(memo, key, 60, fn() { Ok(False) }) == Ok(False)
}

pub fn changes_invalidate_after_an_application_transaction_commits_test() {
  use database, _, _, _ <- fixture
  let memo = cache.new()
  let key = #("user", "session", "scope", "permission", "read")
  assert cache.run(memo, key, 60, fn() { Ok(True) }) == Ok(True)
  let assert Ok(Nil) =
    howdy_database.transaction(database, fn(_) {
      // Auth's own transaction ends here, as a savepoint of the app's.
      cache.changing(fn() { Nil })
      // Another request still sees the old grant until the commit.
      let cached = process.new_subject()
      process.spawn(fn() {
        process.send(cached, cache.run(memo, key, 60, fn() { Ok(True) }))
      })
      let assert Ok(Ok(True)) = process.receive(cached, 1000)
      Ok(Nil)
    })
  assert cache.run(memo, key, 60, fn() { Ok(False) }) == Ok(False)
}

pub fn normalization_metadata_upgrade_is_not_a_credential_change_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let assert Ok(Nil) = auth.set_password(identity, principal, password)
  support.exec(database, "UPDATE howdy_auth_passwords SET normalized = 0")
  // The second login snapshots/verifies before the first marks the same hash.
  let assert Ok([#(candidate, encoded, False)]) =
    store.password_candidates(database, "ada@example.com", option.None)
  let assert Ok(passwords) = password_hash.new(password_hasher.pbkdf2_sha256())
  assert password_hash.verify(passwords, encoded, password, False)
    == Ok(#(True, False))
  let assert Ok(_) = auth.login_password(identity, "ada@example.com", password)
  let accepted =
    db.write_transaction(database, "howdy_auth_users", fn(conn) {
      store.active_user_with_password(conn, candidate.id, encoded, False)
    })
  assert accepted == Ok([candidate])
  // A real password replacement still rejects the earlier verification.
  let assert Ok(Nil) =
    auth.set_password(identity, principal, "a different orchard phrase 842!")
  let stale =
    db.write_transaction(database, "howdy_auth_users", fn(conn) {
      store.active_user_with_password(conn, candidate.id, encoded, False)
    })
  assert stale == Ok([])
}
