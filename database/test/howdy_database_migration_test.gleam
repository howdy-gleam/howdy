import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gloo/adapter/sqlite
import gloo/migration as gloo_migration
import gloo/query
import gloo/repo.{type Repo}
import gloo/schema
import gloo/sql
import howdy/database
import howdy/migration
import howdy/service

fn with_repo(run: fn(Repo) -> a) -> a {
  let assert Ok(db) = sqlite.start(sqlite.memory())
  let value = run(db)
  let assert Ok(_) = repo.close(db)
  value
}

fn notes() -> migration.Package {
  migration.Package("notes", [
    gloo_migration.new(
      1,
      "create_notes",
      "CREATE TABLE notes_notes (id TEXT PRIMARY KEY, slug TEXT NOT NULL UNIQUE)"
        <> migration.per_database(
        postgres: "; ALTER TABLE notes_notes ADD COLUMN created TIMESTAMPTZ",
        sqlite: "; ALTER TABLE notes_notes ADD COLUMN created BIGINT",
      ),
    ),
  ])
}

fn count(db: Repo, sql: String) -> Int {
  let assert Ok(n) =
    database.one(
      db,
      sql,
      [],
      decode.field(0, decode.int, decode.success),
      or: service.NotFound("count"),
    )
  n
}

fn insert(conn: Repo, id: String, slug: String) -> service.Result(Nil) {
  database.execute_or(
    conn,
    "INSERT INTO notes_notes(id, slug) VALUES ($1, $2)",
    [sql.string(id), sql.string(slug)],
    on_constraint: fn(_) { service.Conflict("slug already taken") },
  )
}

pub fn application_package_migrates_once_and_passes_check_test() {
  use db <- with_repo
  assert migration.check(db, notes()) != Ok(Nil)
  assert migration.run(db, [notes()]) == Ok(Nil)
  assert migration.run(db, [notes()]) == Ok(Nil)
  assert migration.check(db, notes()) == Ok(Nil)
  assert count(db, "SELECT COUNT(*) FROM howdy_migrations") == 1
  // The SQLite variant ran, not the PostgreSQL one.
  assert insert(db, "1", "first") == Ok(Nil)
  assert count(db, "SELECT COUNT(*) FROM notes_notes WHERE created IS NULL")
    == 1
}

pub fn edited_history_and_out_of_band_changes_are_rejected_test() {
  use db <- with_repo
  assert migration.run(db, [notes()]) == Ok(Nil)
  let edited =
    migration.Package("notes", [
      gloo_migration.new(
        1,
        "create_notes",
        "CREATE TABLE notes_notes (id TEXT)",
      ),
    ])
  assert migration.run(db, [edited])
    == Error(service.Internal(
      "migration history differs from the installed package",
    ))
  let assert Ok(Nil) =
    database.exec(db, "ALTER TABLE notes_notes ADD COLUMN extra TEXT")
  assert migration.check(db, notes())
    == Error(service.Internal(
      "module-owned database schema was changed outside its migrations",
    ))
  assert migration.rebaseline(db, notes()) == Ok(Nil)
  assert migration.check(db, notes()) == Ok(Nil)
}

pub fn the_development_admins_notify_triggers_are_not_drift_test() {
  use db <- with_repo
  assert migration.run(db, [notes()]) == Ok(Nil)
  // Not `database.exec`: it splits statements on semicolons.
  let assert Ok(_) =
    repo.execute(
      db,
      "CREATE TRIGGER howdy_admin_notify AFTER INSERT ON notes_notes BEGIN SELECT 1; END",
      [],
    )
  assert migration.check(db, notes()) == Ok(Nil)
  let assert Ok(_) =
    repo.execute(
      db,
      "CREATE TRIGGER audit_notes AFTER INSERT ON notes_notes BEGIN SELECT 1; END",
      [],
    )
  assert migration.check(db, notes())
    == Error(service.Internal(
      "module-owned database schema was changed outside its migrations",
    ))
}

pub fn failed_migration_rolls_back_schema_and_ledger_test() {
  use db <- with_repo
  let broken =
    migration.Package("broken", [
      gloo_migration.new(1, "one", "CREATE TABLE broken_one (id TEXT)"),
      gloo_migration.new(2, "two", "CREATE TABLE broken_one (id TEXT)"),
    ])
  assert migration.run(db, [notes(), broken]) != Ok(Nil)
  assert count(
      db,
      "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('notes_notes', 'broken_one', 'howdy_migrations')",
    )
    == 0
}

pub fn package_names_must_be_unique_lowercase_identifiers_test() {
  use db <- with_repo
  let assert Error(service.Invalid(_)) = migration.run(db, [notes(), notes()])
  let assert Error(service.Invalid(_)) =
    migration.run(db, [migration.Package("Notes", [])])
}

pub fn registered_hooks_bracket_every_run_in_name_order_test() {
  use db <- with_repo
  let events = process.new_subject()
  let hook = fn(label: String) {
    fn(run: fn() -> service.Result(Nil)) {
      process.send(events, label <> " before")
      let answer = run()
      process.send(
        events,
        label
          <> " after "
          <> case answer {
          Ok(Nil) -> "commit"
          Error(_) -> "rollback"
        },
      )
      answer
    }
  }
  migration.around_runs("test_b", hook("stale"))
  migration.around_runs("test_b", hook("b"))
  migration.around_runs("test_a", hook("a"))
  assert migration.run(db, [notes()]) == Ok(Nil)
  // Later tests share the node; leave hooks that report nowhere.
  migration.around_runs("test_a", fn(run) { run() })
  migration.around_runs("test_b", fn(run) { run() })
  assert process.receive(events, 0) == Ok("a before")
  assert process.receive(events, 0) == Ok("b before")
  assert process.receive(events, 0) == Ok("b after commit")
  assert process.receive(events, 0) == Ok("a after commit")
  assert process.receive(events, 0) == Error(Nil)
}

pub fn transaction_hooks_bracket_only_the_outermost_transaction_test() {
  use db <- with_repo
  assert migration.run(db, [notes()]) == Ok(Nil)
  let events = process.new_subject()
  let me = process.self()
  database.around_transactions("test_transactions", fn(run) {
    case process.self() == me {
      False -> run()
      True -> {
        process.send(events, "before")
        let answer = run()
        // Outside the transaction: its rollback is already visible.
        let rows = count(db, "SELECT COUNT(*) FROM notes_notes")
        process.send(events, "after " <> int.to_string(rows))
        answer
      }
    }
  })
  let answer = {
    use conn <- database.transaction(db)
    let assert Ok(Nil) = database.transaction(conn, insert(_, "1", "first"))
    Error(service.Forbidden)
  }
  // Later tests share the node; leave a hook that reports nowhere.
  database.around_transactions("test_transactions", fn(run) { run() })
  assert answer == Error(service.Forbidden)
  assert process.receive(events, 0) == Ok("before")
  assert process.receive(events, 0) == Ok("after 0")
  assert process.receive(events, 0) == Error(Nil)
}

pub fn transaction_keeps_the_typed_error_and_rolls_back_test() {
  use db <- with_repo
  assert migration.run(db, [notes()]) == Ok(Nil)
  let answer = {
    use conn <- database.write_transaction(db, touching: "notes_notes")
    let assert Ok(Nil) = insert(conn, "1", "first")
    Error(service.Forbidden)
  }
  assert answer == Error(service.Forbidden)
  assert count(db, "SELECT COUNT(*) FROM notes_notes") == 0
  // The Repo is still usable, and a commit is visible.
  assert database.transaction(db, insert(_, "1", "first")) == Ok(Nil)
  assert count(db, "SELECT COUNT(*) FROM notes_notes") == 1
}

pub fn constraint_violations_become_domain_errors_test() {
  use db <- with_repo
  assert migration.run(db, [notes()]) == Ok(Nil)
  assert insert(db, "1", "first") == Ok(Nil)
  assert insert(db, "2", "first")
    == Error(service.Conflict("slug already taken"))
  // Anything else stays opaque.
  assert database.execute_or(db, "INSERT INTO missing VALUES (1)", [], fn(_) {
      service.Conflict("no")
    })
    == Error(service.Internal("database operation failed"))
}

pub fn one_returns_the_first_row_or_the_given_error_test() {
  use db <- with_repo
  assert migration.run(db, [notes()]) == Ok(Nil)
  let find = fn(id) {
    database.one(
      db,
      "SELECT slug FROM notes_notes WHERE id = $1",
      [sql.string(id)],
      decode.field(0, decode.string, decode.success),
      or: service.NotFound("note"),
    )
  }
  assert find("1") == Error(service.NotFound("note"))
  assert insert(db, "1", "first") == Ok(Nil)
  assert find("1") == Ok("first")
}

pub fn sqlite_operations_on_one_repo_never_interleave_test() {
  use db <- with_repo
  assert migration.run(db, [notes()]) == Ok(Nil)
  let done = process.new_subject()
  let worker = fn(id: String) {
    process.spawn(fn() {
      let answer = {
        use conn <- database.write_transaction(db, touching: "notes_notes")
        let assert Ok(Nil) = insert(conn, id, id)
        process.sleep(20)
        // Another process joining this transaction would be counted here.
        Ok(count(conn, "SELECT COUNT(*) FROM notes_notes"))
      }
      process.send(done, answer)
    })
  }
  worker("a")
  worker("b")
  let assert Ok(Ok(first)) = process.receive(done, 2000)
  let assert Ok(Ok(second)) = process.receive(done, 2000)
  assert first + second == 3
}

pub fn sqlite_defaults_use_write_ahead_logging_test() {
  let path =
    "/tmp/howdy-database-wal-"
    <> int.to_string(int.random(1_000_000_000))
    <> ".sqlite"
  let assert Ok(db) = sqlite.start(sqlite.file(path))
  assert database.sqlite_defaults(db) == Ok(Nil)
  let assert Ok(["wal"]) =
    repo.all(
      db,
      "PRAGMA journal_mode",
      [],
      decode.field(0, decode.string, decode.success),
    )
  let assert Ok(_) = repo.close(db)
  let _ = delete(path)
  let _ = delete(path <> "-wal")
  let _ = delete(path <> "-shm")
  Nil
}

@external(erlang, "file", "delete")
fn delete(path: String) -> decode.Dynamic

pub fn sqlite_defaults_enforce_foreign_keys_and_wait_for_locks_test() {
  use db <- with_repo
  assert count(db, "PRAGMA foreign_keys") == 0
  assert database.sqlite_defaults(db) == Ok(Nil)
  assert count(db, "PRAGMA foreign_keys") == 1
  assert count(db, "PRAGMA busy_timeout") == 5000
}

fn notes_table() -> schema.Table(#(String, String)) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    use slug <- decode.field(1, decode.string)
    decode.success(#(id, slug))
  }
  schema.Table(name: "notes_notes", primary_key: "id", decoder:)
}

fn returning(db: Repo, mutation: query.Query(#(String, String))) {
  database.returning(db, mutation, ["id", "slug"], or: service.NotFound("note"))
}

pub fn returning_reports_the_row_a_builder_mutation_touched_test() {
  use db <- with_repo
  assert migration.run(db, [notes()]) == Ok(Nil)
  let table = notes_table()
  let insert = fn(id, slug) {
    query.insert(query.from(table), table, [
      #("id", sql.string(id)),
      #("slug", sql.string(slug)),
    ])
    |> returning(db, _)
  }
  let by_id = fn(q, id) { query.where(q, query.Eq("id", sql.string(id))) }
  let rename = fn(id, slug) {
    query.from(table)
    |> query.update([#("slug", sql.string(slug))])
    |> by_id(id)
    |> returning(db, _)
  }
  assert insert("1", "first") == Ok(#("1", "first"))
  assert insert("2", "second") == Ok(#("2", "second"))
  assert rename("1", "renamed") == Ok(#("1", "renamed"))
  assert rename("9", "nobody") == Error(service.NotFound("note"))
  assert rename("2", "renamed")
    == Error(service.Conflict("the record conflicts with existing data"))
  let delete = fn(id) {
    query.from(table) |> query.delete |> by_id(id) |> returning(db, _)
  }
  assert delete("1") == Ok(#("1", "renamed"))
  assert delete("1") == Error(service.NotFound("note"))
  assert count(db, "SELECT COUNT(*) FROM notes_notes") == 1
}
