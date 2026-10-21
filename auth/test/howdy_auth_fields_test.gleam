//// Timestamps on users and groups, and the fields applications keep on them.

import gleam/int
import gleam/order
import gleam/string
import gleam/time/timestamp
import gloo/migration as gloo_migration
import gloo/repo
import gloo/sql
import howdy/auth
import howdy/auth/field
import howdy/auth/group
import howdy/auth/groups
import howdy/auth/internal/database as db
import howdy/auth/internal/token
import howdy/auth/secret
import howdy/auth/user
import howdy/auth/users
import howdy/database.{Postgres}
import howdy/migration
import howdy/service
import support.{count, exec, fixture, signup, with_repo}

type Plan {
  Free
  Pro
}

fn username() {
  field.text("username")
  |> field.unique
  |> field.check(fn(name) {
    case string.length(name) >= 3 {
      True -> Ok(Nil)
      False -> Error("must be at least 3 characters")
    }
  })
}

fn handle() {
  field.text("handle") |> field.unique_in_group
}

fn plan() {
  field.custom(
    "plan",
    encode: fn(plan) {
      case plan {
        Free -> "free"
        Pro -> "pro"
      }
    },
    decode: fn(text) {
      case text {
        "free" -> Ok(Free)
        "pro" -> Ok(Pro)
        _ -> Error(Nil)
      }
    },
  )
}

fn seats() {
  field.int("seats")
}

fn billing_id() {
  field.text("billing_id") |> field.unique
}

/// Seconds since the epoch as the database holds them, whatever its type.
fn stored_seconds(database, table: String, column: String, id: String) -> Int {
  count(
    database,
    "SELECT "
      <> db.read_time(database, column)
      <> " FROM "
      <> table
      <> " WHERE id = '"
      <> id
      <> "'",
  )
}

fn age(database, table: String, id: String, seconds: Int) {
  let assert Ok(_) =
    repo.execute(
      database,
      "UPDATE "
        <> table
        <> " SET created_at = "
        <> db.write_time(database, "$1")
        <> ", updated_at = "
        <> db.write_time(database, "$2")
        <> " WHERE id = $3",
      [sql.int(seconds), sql.int(seconds), sql.string(id)],
    )
  Nil
}

pub fn users_and_groups_record_when_they_were_created_test() {
  use database, identity, _, mailbox <- fixture
  let before = token.now()
  let session = signup(identity, mailbox, "ada@example.com")
  let #(created, _) =
    timestamp.to_unix_seconds_and_nanoseconds(session.user.created_at)
  assert created >= before && created <= token.now()
  assert session.user.updated_at == session.user.created_at
  assert stored_seconds(
      database,
      "howdy_auth_users",
      "created_at",
      session.user.id,
    )
    == created
  // Every way of reading a user agrees.
  assert users.get(identity, session.user.id) == Ok(session.user)
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  assert principal.user == session.user
  // On a fresh install the default group dates from its migration.
  let assert Ok(everyone) = groups.get(identity, group.default_id)
  // The fixture migrates before `before` is read, so that is an upper bound.
  let #(since, _) =
    timestamp.to_unix_seconds_and_nanoseconds(everyone.created_at)
  assert since <= before && since > before - 60
}

pub fn postgres_keeps_instants_as_timestamps_test() {
  use database, _, _, _ <- fixture
  let timestamps =
    "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = current_schema() AND table_name IN ('howdy_auth_users', 'howdy_auth_groups') AND column_name IN ('created_at', 'updated_at') AND data_type = 'timestamp with time zone'"
  case db.backend(database) {
    Ok(Postgres) -> {
      assert count(database, timestamps) == 4
    }
    _ -> Nil
  }
}

pub fn fractional_instants_read_as_the_second_they_fall_in_test() {
  use database, identity, _, _ <- fixture
  // Only PostgreSQL keeps fractions, such as from `CURRENT_TIMESTAMP` in a
  // migration. Rounding them would read an instant from the future.
  case db.backend(database) {
    Ok(Postgres) -> {
      exec(
        database,
        "UPDATE howdy_auth_groups SET created_at = to_timestamp(1000.6) WHERE id = 'default'",
      )
      assert stored_seconds(
          database,
          "howdy_auth_groups",
          "created_at",
          group.default_id,
        )
        == 1000
      let assert Ok(everyone) = groups.get(identity, group.default_id)
      assert everyone.created_at == timestamp.from_unix_seconds(1000)
    }
    _ -> Nil
  }
}

pub fn changes_move_updated_at_and_leave_created_at_test() {
  use database, identity, _, mailbox <- fixture
  let session = signup(identity, mailbox, "ada@example.com")
  let id = session.user.id
  age(database, "howdy_auth_users", id, 1000)
  let long_ago = timestamp.from_unix_seconds(1000)
  let assert Ok(aged) = users.get(identity, id)
  assert aged.created_at == long_ago && aged.updated_at == long_ago

  let assert Ok(Nil) = auth.suspend(identity, id, by: user.System)
  let assert Ok(suspended) = users.get(identity, id)
  assert suspended.created_at == long_ago
  assert timestamp.compare(suspended.updated_at, long_ago) == order.Gt

  age(database, "howdy_auth_users", id, 1000)
  let assert Ok(changed) =
    users.update(identity, id, [field.set(username(), "ada")], by: user.System)
  assert changed.created_at == long_ago
  assert timestamp.compare(changed.updated_at, long_ago) == order.Gt

  age(database, "howdy_auth_groups", group.default_id, 1000)
  let assert Ok(renamed) =
    groups.rename(identity, group.default_id, to: "Everyone", by: user.System)
  assert renamed.created_at == long_ago
  assert timestamp.compare(renamed.updated_at, long_ago) == order.Gt
}

pub fn creation_is_recovered_from_the_audit_trail_test() {
  use database <- with_repo
  let migration.Package(name, migrations) = auth.schema()
  let before = migration.Package(name, take(migrations, 7))
  let assert Ok(Nil) = migration.run(database, [before])
  exec(
    database,
    "INSERT INTO howdy_auth_groups(id, name) VALUES ('acme', 'Acme');
     INSERT INTO howdy_auth_users(id, login_key, email, group_id) VALUES ('known', 'ada@example.com', 'ada@example.com', 'acme');
     INSERT INTO howdy_auth_users(id, login_key, email, group_id) VALUES ('pruned', 'bob@example.com', 'bob@example.com', 'acme');
     INSERT INTO howdy_auth_events(id, user_id, action, occurred_at, detail) VALUES ('1', 'known', 'user.registered', 5000, 'acme');
     INSERT INTO howdy_auth_events(id, user_id, action, occurred_at, detail) VALUES ('2', '', 'group.created', 4000, 'acme')",
  )
  let assert Ok(Nil) = migration.run(database, [auth.schema()])
  let assert Ok(identity) =
    auth.new(database, "https://example.test", fn(_) { Ok(Nil) })
  let assert Ok(known) = users.get(identity, "known")
  assert known.created_at == timestamp.from_unix_seconds(5000)
  assert known.updated_at == known.created_at
  let assert Ok(pruned) = users.get(identity, "pruned")
  assert pruned.created_at == timestamp.from_unix_seconds(0)
  let assert Ok(acme) = groups.get(identity, "acme")
  assert acme.created_at == timestamp.from_unix_seconds(4000)
}

fn take(items: List(a), n: Int) -> List(a) {
  case items, n {
    [first, ..rest], n if n > 0 -> [first, ..take(rest, n - 1)]
    _, _ -> []
  }
}

pub fn per_database_sql_runs_only_its_own_variant_test() {
  use database <- with_repo
  let #(mine, theirs) = case db.backend(database) {
    Ok(Postgres) -> #("app_postgres", "app_sqlite")
    _ -> #("app_sqlite", "app_postgres")
  }
  let package =
    migration.Package("app", [
      gloo_migration.new(
        1,
        "create",
        "CREATE TABLE app_shared (id INT);"
          <> migration.per_database(
          postgres: "CREATE TABLE app_postgres (id INT)",
          sqlite: "CREATE TABLE app_sqlite (id INT)",
        ),
      ),
    ])
  let assert Ok(Nil) = migration.run(database, [package])
  assert migration.run(database, [package]) == Ok(Nil)
  assert count(database, "SELECT COUNT(*) FROM app_shared") == 0
  assert count(database, "SELECT COUNT(*) FROM " <> mine) == 0
  let assert Error(_) =
    repo.execute(database, "SELECT COUNT(*) FROM " <> theirs, [])
}

pub fn fields_are_written_read_and_cleared_test() {
  use database, identity, _, mailbox <- fixture
  let ada = signup(identity, mailbox, "ada@example.com").user
  let since = timestamp.from_unix_seconds(1_700_000_000)
  let assert Ok(_) =
    users.update(
      identity,
      ada.id,
      [
        field.set(username(), "ada"),
        field.set(plan(), Pro),
        field.set(field.bool("newsletter"), True),
        field.set(field.time("trial_ends"), since),
      ],
      by: user.System,
    )
  let assert Ok(data) = users.fields(identity, ada.id)
  assert field.get(data, username()) == Ok("ada")
  assert field.get(data, plan()) == Ok(Pro)
  assert field.get(data, field.bool("newsletter")) == Ok(True)
  assert field.get(data, field.time("trial_ends")) == Ok(since)
  assert field.get(data, seats()) == Error(Nil)
  assert field.to_list(data)
    == [
      #("newsletter", "true"),
      #("plan", "pro"),
      #("trial_ends", "2023-11-14T22:13:20Z"),
      #("username", "ada"),
    ]
  // Setting again replaces; clearing removes; the rest are untouched.
  let assert Ok(_) =
    users.update(
      identity,
      ada.id,
      [field.set(plan(), Free), field.clear(field.bool("newsletter"))],
      by: user.System,
    )
  let assert Ok(data) = users.fields(identity, ada.id)
  assert field.get(data, plan()) == Ok(Free)
  assert field.get(data, field.bool("newsletter")) == Error(Nil)
  assert field.get(data, username()) == Ok("ada")
  // The audit trail names the fields and never holds their values.
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'user.fields_changed' AND detail = 'plan,newsletter'",
    )
    == 1
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE detail LIKE '%ada%' AND action = 'user.fields_changed'",
    )
    == 0
  assert users.fields(identity, "nobody") == Error(service.NotFound("user"))
}

pub fn invalid_changes_are_refused_and_change_nothing_test() {
  use _, identity, _, mailbox <- fixture
  let ada = signup(identity, mailbox, "ada@example.com").user
  assert users.update(
      identity,
      ada.id,
      [field.set(plan(), Pro), field.set(username(), "a")],
      by: user.System,
    )
    == Error(service.Invalid("username: must be at least 3 characters"))
  let assert Error(service.Invalid(_)) =
    users.update(
      identity,
      ada.id,
      [field.set(field.text("Not Plain"), "x")],
      by: user.System,
    )
  let assert Error(service.Invalid(_)) =
    users.update(
      identity,
      ada.id,
      [field.set(field.text("bio"), string.repeat("x", 1025))],
      by: user.System,
    )
  let assert Ok(data) = users.fields(identity, ada.id)
  assert field.to_list(data) == []
}

pub fn unique_fields_have_one_holder_test() {
  use _, identity, _, mailbox <- fixture
  let ada = signup(identity, mailbox, "ada@example.com").user
  let bob = signup(identity, mailbox, "bob@example.com").user
  let assert Ok(_) =
    users.update(
      identity,
      ada.id,
      [field.set(username(), "ada")],
      by: user.System,
    )
  // All or nothing: the plan set alongside the taken name is not kept.
  assert users.update(
      identity,
      bob.id,
      [field.set(plan(), Pro), field.set(username(), "ada")],
      by: user.System,
    )
    == Error(service.Conflict("username is already taken"))
  let assert Ok(data) = users.fields(identity, bob.id)
  assert field.get(data, plan()) == Error(Nil)
  // Holding a value is no obstacle to setting it again.
  let assert Ok(_) =
    users.update(
      identity,
      ada.id,
      [field.set(username(), "ada")],
      by: user.System,
    )
  // Fields that are not unique can be shared, and found.
  let assert Ok(_) =
    users.update(identity, ada.id, [field.set(plan(), Pro)], by: user.System)
  let assert Ok(_) =
    users.update(identity, bob.id, [field.set(plan(), Pro)], by: user.System)
  let assert Ok([first, second]) = users.find(identity, where: plan(), is: Pro)
  assert first.id == ada.id && second.id == bob.id
  let assert Ok([found]) = users.find(identity, where: username(), is: "ada")
  assert found.id == ada.id
  assert users.find(identity, where: username(), is: "nobody") == Ok([])
  // A cleared value is free again.
  let assert Ok(_) =
    users.update(identity, ada.id, [field.clear(username())], by: user.System)
  let assert Ok(_) =
    users.update(
      identity,
      bob.id,
      [field.set(username(), "ada")],
      by: user.System,
    )
}

pub fn fields_unique_in_a_group_follow_the_user_test() {
  use _, identity, _, _ <- fixture
  let assert Ok(identity) = auth.with_groups(identity, group.AccountPerGroup)
  let assert Ok(acme) = groups.create(identity, name: "Acme", by: user.System)
  let assert Ok(globex) =
    groups.create(identity, name: "Globex", by: user.System)
  let in_acme = auth.in_group(identity, acme.id)
  let in_globex = auth.in_group(identity, globex.id)
  let assert Ok(ada) =
    auth.provision_with(
      in_acme,
      "ada@example.com",
      fields: [field.set(handle(), "boss")],
      by: user.System,
    )
  // The same handle is free in another group and taken in this one.
  let assert Ok(bob) =
    auth.provision_with(
      in_globex,
      "bob@example.com",
      fields: [field.set(handle(), "boss")],
      by: user.System,
    )
  assert auth.provision_with(
      in_acme,
      "cy@example.com",
      fields: [field.set(handle(), "boss")],
      by: user.System,
    )
    == Error(service.Conflict("handle is already taken"))
  // A refused provision leaves no user behind.
  let assert Ok([only]) = groups.members(identity, acme.id)
  assert only.id == ada.id
  // Bound to a group, lookups see that group alone.
  let assert Ok([found]) = users.find(in_acme, where: handle(), is: "boss")
  assert found.id == ada.id
  let assert Ok([_, _]) = users.find(identity, where: handle(), is: "boss")
  assert users.get(in_globex, ada.id) == Error(service.NotFound("user"))
  assert users.fields(in_globex, ada.id) == Error(service.NotFound("user"))
  // Moving into a group where the handle is held collides.
  let assert Error(service.Conflict(_)) =
    groups.move(identity, bob.id, to: acme.id, by: user.System)
  let assert Ok(_) =
    users.update(
      identity,
      bob.id,
      [field.set(handle(), "deputy")],
      by: user.System,
    )
  let assert Ok(moved) =
    groups.move(identity, bob.id, to: acme.id, by: user.System)
  assert moved.group_id == acme.id
  // The handle came along, and is now unique where the user is.
  let assert Ok([found]) = users.find(in_acme, where: handle(), is: "deputy")
  assert found.id == bob.id
  let assert Ok(cy) =
    auth.provision(in_globex, "cy@example.com", by: user.System)
  let assert Ok(_) =
    users.update(
      identity,
      cy.id,
      [field.set(handle(), "deputy")],
      by: user.System,
    )
  assert users.update(
      identity,
      ada.id,
      [field.set(handle(), "deputy")],
      by: user.System,
    )
    == Error(service.Conflict("handle is already taken"))
}

pub fn groups_hold_fields_test() {
  use database, identity, _, _ <- fixture
  let assert Ok(identity) = auth.with_groups(identity, group.OneGroupPerUser)
  let assert Ok(acme) =
    groups.create_with(
      identity,
      id: "acme",
      name: "Acme",
      fields: [field.set(seats(), 25), field.set(billing_id(), "cus_1")],
      by: user.System,
    )
  let assert Ok(data) = groups.fields(identity, acme.id)
  assert field.get(data, seats()) == Ok(25)
  assert groups.create_with(
      identity,
      id: "globex",
      name: "Globex",
      fields: [field.set(billing_id(), "cus_1")],
      by: user.System,
    )
    == Error(service.Conflict("billing_id is already taken"))
  assert groups.get(identity, "globex") == Error(service.NotFound("group"))
  let assert Ok(globex) =
    groups.create_with_id(
      identity,
      id: "globex",
      name: "Globex",
      by: user.System,
    )
  let assert Ok(_) =
    groups.update(
      identity,
      globex.id,
      [field.set(seats(), 25), field.set(billing_id(), "cus_2")],
      by: user.System,
    )
  let assert Ok([first, second]) = groups.find(identity, where: seats(), is: 25)
  assert first.id == "acme" && second.id == "globex"
  let assert Ok([found]) =
    groups.find(identity, where: billing_id(), is: "cus_2")
  assert found.id == "globex"
  // Uniqueness within a group says nothing about a group itself.
  let assert Error(service.Invalid(_)) =
    groups.update(
      identity,
      acme.id,
      [field.set(handle(), "x")],
      by: user.System,
    )
  // A user field and a group field may share a name.
  let assert Ok(ada) =
    auth.provision_with(
      auth.in_group(identity, acme.id),
      "ada@example.com",
      fields: [field.set(seats(), 1)],
      by: user.System,
    )
  let assert Ok([_]) = users.find(identity, where: seats(), is: 1)
  assert ada.group_id == acme.id
  // Fields go with their group.
  let assert Ok(_) = groups.delete(identity, globex.id, by: user.System)
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_group_fields WHERE group_id = 'globex'",
    )
    == 0
  assert int.to_string(count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_group_fields",
    ))
    == "2"
}
