//// Schema ownership: migrations, drift, and sharing a database.

import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/time/timestamp
import gloo/migration as gloo_migration
import gloo/repo
import gloo/sql
import howdy/auth
import howdy/auth/group
import howdy/auth/internal/token as auth_token
import howdy/auth/secret
import howdy/auth/user
import howdy/authorization as access
import howdy/migration
import howdy/service
import support.{count, exec, fixture, signup}

pub fn migrations_are_idempotent_and_reject_changed_or_newer_history_test() {
  use database, _, _, _ <- fixture
  assert migration.run(database, [auth.schema(), access.schema()]) == Ok(Nil)
  let changed =
    migration.Package("howdy_auth", [
      gloo_migration.new(1, "changed", "CREATE TABLE wrong (id INT)"),
    ])
  let assert Error(_) = migration.run(database, [changed])
  assert migration.check(database, auth.schema()) == Ok(Nil)
  let migration.Package(name, existing) = auth.schema()
  let newer =
    migration.Package(
      name,
      list.append(existing, [
        gloo_migration.new(
          list.length(existing) + 1,
          "future",
          "CREATE TABLE howdy_auth_future (id INT)",
        ),
      ]),
    )
  assert migration.run(database, [newer]) == Ok(Nil)
  let assert Error(_) =
    auth.new(database, "https://example.test", fn(_) { Ok(Nil) })
}

pub fn failed_migration_rolls_back_schema_and_ledger_test() {
  use database, _, _, _ <- fixture
  let broken =
    migration.Package("broken", [
      gloo_migration.new(1, "create", "CREATE TABLE broken_rollback (id INT)"),
      gloo_migration.new(2, "fail", "NOT VALID SQL"),
    ])
  let assert Error(_) = migration.run(database, [broken])
  let assert Error(_) =
    repo.execute(database, "SELECT * FROM broken_rollback", [])
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_migrations WHERE package = 'broken'",
    )
    == 0
  let assert Error(_) = migration.run(database, [auth.schema(), auth.schema()])
}

pub fn schema_drift_is_rejected_before_startup_and_upgrade_test() {
  use database, _, _, _ <- fixture
  exec(
    database,
    "ALTER TABLE howdy_auth_users ADD COLUMN application_field TEXT",
  )
  let assert Error(_) =
    auth.new(database, "https://example.test", fn(_) { Ok(Nil) })
  let assert Error(_) = migration.run(database, [auth.schema()])
}

pub fn application_tables_do_not_interfere_with_owned_schema_test() {
  use database, _, _, _ <- fixture
  exec(
    database,
    "CREATE TABLE app_profiles (user_id TEXT REFERENCES howdy_auth_users(id), display_name TEXT)",
  )
  assert migration.check(database, auth.schema()) == Ok(Nil)
  assert migration.run(database, [auth.schema(), access.schema()]) == Ok(Nil)
}

pub fn auth_tables_preserve_foreign_key_integrity_test() {
  use database, _, permissions, _ <- fixture
  let assert Ok(Nil) =
    access.define_role(
      permissions,
      access.Global,
      "reader",
      ["read"],
      by: user.System,
    )
  let assert Error(_) =
    access.assign(
      permissions,
      "nonexistent",
      "reader",
      access.Global,
      by: user.System,
    )
  assert count(database, "SELECT COUNT(*) FROM howdy_authz_assignments") == 0
}

pub fn another_package_cannot_alter_auth_schema_during_migration_test() {
  use database, _, _, _ <- fixture
  let foreign =
    migration.Package("app", [
      gloo_migration.new(
        1,
        "invalid_change",
        "ALTER TABLE howdy_auth_users ADD COLUMN accidental TEXT",
      ),
    ])
  let assert Error(_) = migration.run(database, [foreign])
  assert migration.check(database, auth.schema()) == Ok(Nil)
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_migrations WHERE package = 'app'",
    )
    == 0
}

pub fn concurrent_migrators_apply_new_version_once_test() {
  use database, _, _, _ <- fixture
  let migration.Package(name, existing) = auth.schema()
  let next =
    migration.Package(
      name,
      list.append(existing, [
        gloo_migration.new(
          list.length(existing) + 1,
          "future",
          "CREATE TABLE howdy_auth_future (id INT)",
        ),
      ]),
    )
  let replies = process.new_subject()
  let _ =
    process.spawn(fn() {
      process.send(replies, migration.run(database, [next]))
    })
  let _ =
    process.spawn(fn() {
      process.send(replies, migration.run(database, [next]))
    })
  assert process.receive(replies, 10_000) == Ok(Ok(Nil))
  assert process.receive(replies, 10_000) == Ok(Ok(Nil))
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_migrations WHERE package = 'howdy_auth' AND version = 8",
    )
    == 1
}

pub fn repo_remains_usable_after_a_rolled_back_operation_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(Nil) =
    auth.request_token(identity, "unknown@example.com", auth.Login)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert auth.exchange(identity, secret.reveal(delivery.token))
    == Error(service.Unauthorized)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 0
  let _ = signup(identity, mailbox, "valid@example.com")
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 1
}

pub fn independent_connections_serialize_migrations_and_token_exchange_test() {
  use first, second <- support.with_independent_repos
  let replies = process.new_subject()
  let _ =
    process.spawn(fn() {
      process.send(
        replies,
        migration.run(first, [auth.schema(), access.schema()]),
      )
    })
  let _ =
    process.spawn(fn() {
      process.send(
        replies,
        migration.run(second, [auth.schema(), access.schema()]),
      )
    })
  assert process.receive(replies, 10_000) == Ok(Ok(Nil))
  assert process.receive(replies, 10_000) == Ok(Ok(Nil))
  let mailbox = process.new_subject()
  let deliver = fn(value) {
    process.send(mailbox, value)
    Ok(Nil)
  }
  let assert Ok(a) = auth.new(first, "https://example.test", deliver)
  let assert Ok(b) = auth.new(second, "https://example.test", deliver)
  let a = auth.allow_registration(a)
  let b = auth.allow_registration(b)
  let assert Ok(Nil) = auth.request_token(a, "race@example.com", auth.Register)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let exchanges = process.new_subject()
  let _ =
    process.spawn(fn() {
      process.send(exchanges, auth.exchange(a, secret.reveal(delivery.token)))
    })
  let _ =
    process.spawn(fn() {
      process.send(exchanges, auth.exchange(b, secret.reveal(delivery.token)))
    })
  let assert Ok(x) = process.receive(exchanges, 10_000)
  let assert Ok(y) = process.receive(exchanges, 10_000)
  assert list.contains([x, y], Error(service.Unauthorized))
  assert list.length(
      list.filter([x, y], fn(r) {
        case r {
          Ok(_) -> True
          _ -> False
        }
      }),
    )
    == 1
  assert count(first, "SELECT COUNT(*) FROM howdy_auth_sessions") == 1
}

pub fn password_migration_preserves_existing_accounts_and_sessions_test() {
  use database <- support.with_repo
  let migration.Package(name, migrations) = auth.schema()
  let old = migration.Package(name, list.take(migrations, 1))
  let assert Ok(Nil) = migration.run(database, [old])
  let secret = auth_token.new()
  let assert Ok(_) =
    repo.execute(
      database,
      "INSERT INTO howdy_auth_users(id, email) VALUES ('existing', 'ada@example.com')",
      [],
    )
  let assert Ok(_) =
    repo.execute(
      database,
      "INSERT INTO howdy_auth_identities(issuer, subject, user_id) VALUES ('email', 'ada@example.com', 'existing')",
      [],
    )
  let assert Ok(_) =
    repo.execute(
      database,
      "INSERT INTO howdy_auth_sessions(digest, user_id, expires_at) VALUES ($1, 'existing', $2)",
      [sql.string(auth_token.digest(secret)), sql.int(auth_token.now() + 3600)],
    )
  let assert Ok(Nil) = migration.run(database, [auth.schema()])
  let assert Ok(identity) =
    auth.new(database, "https://example.test", fn(_) { Ok(Nil) })
  let assert Ok(principal) = auth.authenticate(identity, secret)
  // Nothing in the audit trail says when this user was created.
  let epoch = timestamp.from_unix_seconds(0)
  assert principal.user
    == user.User(
      "existing",
      "ada@example.com",
      group.default_id,
      epoch,
      epoch,
      option.None,
    )
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_passwords") == 0
  assert migration.run(database, [auth.schema()]) == Ok(Nil)
}
