import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import gloo/adapter/sqlite
import gloo/migration as gloo_migration
import gloo/repo.{type Repo}
import gloo/value
import howdy/database
import howdy/database/postgres
import howdy/env
import howdy/migration
import howdy/service
import pog

@external(erlang, "howdy_database_ffi", "monotonic_ms")
fn now() -> Int

@external(erlang, "howdy_database_test_ffi", "children")
fn children(supervisor: process.Pid) -> List(process.Pid)

@external(erlang, "howdy_database_test_ffi", "crashes")
fn crashes(run: fn() -> a) -> Result(a, Nil)

@external(erlang, "howdy_database_test_ffi", "putenv")
fn putenv(name: String, value: String) -> Nil

@external(erlang, "howdy_database_test_ffi", "unsetenv")
fn unsetenv(name: String) -> Nil

pub fn from_env_treats_an_empty_variable_as_unset_test() {
  unsetenv("DATABASE_URL")
  assert postgres.from_env() == Error(postgres.MissingUrl("DATABASE_URL"))
  putenv("DATABASE_URL", "")
  assert postgres.from_env() == Error(postgres.MissingUrl("DATABASE_URL"))
  putenv("DATABASE_URL", "postgres://app:pw@db/app")
  let assert Ok(config) = postgres.from_env()
  let assert #("db", 5432, "app", "app", Some("pw"), postgres.SslDisabled, _) =
    postgres.inspect(config)
  unsetenv("DATABASE_URL")
}

fn parsed(url: String) {
  postgres.from_url(url) |> result.map(postgres.inspect)
}

pub fn url_supplies_credentials_port_and_database_test() {
  let assert Ok(#(host, port, database, user, password, ssl, _)) =
    parsed("postgresql://app%40ops:p%3Ass%2Fw@db.example.com:6543/my%20app")
  assert host == "db.example.com"
  assert port == 6543
  assert database == "my app"
  assert user == "app@ops"
  assert password == Some("p:ss/w")
  assert ssl == postgres.SslVerified

  let assert Ok(#(host, port, _, user, password, _, _)) =
    parsed("postgres://[::1]/app")
  assert host == "::1"
  assert port == 5432
  assert user == "postgres"
  assert password == None
}

pub fn tls_defaults_to_verified_except_for_local_hosts_test() {
  let ssl = fn(url) {
    let assert Ok(#(_, _, _, _, _, ssl, _)) = parsed(url)
    ssl
  }
  assert ssl("postgres://u@localhost/app") == postgres.SslDisabled
  assert ssl("postgres://u@127.0.0.1/app") == postgres.SslDisabled
  assert ssl("postgres://u@[::1]/app") == postgres.SslDisabled
  assert ssl("postgres://u@db/app") == postgres.SslDisabled
  assert ssl("postgres://u@10.0.0.5/app") == postgres.SslVerified
  assert ssl("postgres://u@db.internal/app") == postgres.SslVerified
  assert ssl("postgres://u@db.internal/app?sslmode=disable")
    == postgres.SslDisabled
  assert ssl("postgres://u@db/app?sslmode=require") == postgres.SslUnverified
  assert ssl("postgres://u@db/app?sslmode=verify-full") == postgres.SslVerified
}

pub fn malformed_urls_are_refused_without_echoing_them_test() {
  assert postgres.from_url("mysql://u:secret@host/app")
    == Error(postgres.InvalidUrl)
  assert postgres.from_url("postgres://u:secret@host/")
    == Error(postgres.InvalidUrl)
  assert postgres.from_url("postgres://u:secret@host/a/b")
    == Error(postgres.InvalidUrl)
  assert postgres.from_url("postgres://:secret@host/app")
    == Error(postgres.InvalidUrl)
  assert postgres.from_url("postgres://u@host/app?sslmode=prefer")
    == Error(postgres.UnsupportedSslMode("prefer"))
}

pub fn every_connection_starts_with_the_defaults_test() {
  let assert Ok(#(_, _, _, _, _, _, parameters)) =
    postgres.from_url("postgres://u@db/app")
    |> result.map(postgres.parameter(_, "search_path", "app"))
    |> result.map(postgres.lock_timeout(_, 0))
    |> result.map(postgres.statement_timeout(_, 1500))
    |> result.map(postgres.inspect)
  assert parameters
    == [
      #("timezone", "UTC"),
      #("idle_in_transaction_session_timeout", "60000"),
      #("search_path", "app"),
      #("statement_timeout", "1500"),
    ]
}

/// Live tests run when HOWDY_DATABASE_TEST_POSTGRES_URL names a server whose
/// user may create databases.
fn with_postgres(run: fn(postgres.Config) -> Nil) -> Nil {
  case env.get("HOWDY_DATABASE_TEST_POSTGRES_URL") {
    Error(Nil) -> Nil
    Ok(url) -> {
      let assert Ok(config) = postgres.from_url(url)
      run(config)
    }
  }
}

fn setting(db: Repo, name: String) -> String {
  let assert Ok([value]) =
    repo.all(
      db,
      "SELECT current_setting('" <> name <> "')",
      [],
      decode.field(0, decode.string, decode.success),
    )
  value
}

pub fn start_waits_for_the_server_and_applies_session_settings_test() {
  use config <- with_postgres
  let assert Ok(db) =
    config |> postgres.parameter("search_path", "app") |> postgres.start
  assert setting(db, "TimeZone") == "UTC"
  assert setting(db, "search_path") == "app"
  assert setting(db, "statement_timeout") == "30s"
  assert setting(db, "lock_timeout") == "5s"
  assert setting(db, "idle_in_transaction_session_timeout") == "1min"
  let assert Ok(_) = repo.close(db)
  Nil
}

pub fn start_fails_clearly_when_the_server_cannot_be_reached_test() {
  use _ <- with_postgres
  let assert Ok(config) = postgres.from_url("postgres://u@127.0.0.1:1/app")
  let started = now()
  assert postgres.start(config |> postgres.startup_timeout(300))
    == Error(postgres.Unreachable)
  assert now() - started < 5000
}

pub fn supervised_pool_is_a_permanent_supervisor_child_test() {
  let assert Ok(config) = postgres.from_url("postgres://u@127.0.0.1:1/app")
  let #(pool, child) = postgres.supervised(config)
  assert child.child_type == supervision.Supervisor
  assert child.restart == supervision.Permanent
  // The handle is usable before the child starts: closing its Repo, which
  // the supervisor owns, does nothing.
  assert repo.close(postgres.repo(pool)) == Ok(Nil)
}

pub fn supervised_pool_fails_to_start_when_the_server_cannot_be_reached_test() {
  use _ <- with_postgres
  let assert Ok(config) = postgres.from_url("postgres://u@127.0.0.1:1/app")
  let #(_, child) = postgres.supervised(config |> postgres.startup_timeout(300))
  let started = now()
  // The supervisor links to whoever starts it and exits when its child
  // fails, so start it from a helper that traps that exit.
  let outcome = process.new_subject()
  process.spawn_unlinked(fn() {
    process.trap_exits(True)
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(child)
    |> static_supervisor.start
    |> result.is_error
    |> process.send(outcome, _)
  })
  assert process.receive(outcome, 5000) == Ok(True)
  assert now() - started < 5000
}

pub fn supervised_pool_answers_and_is_restarted_test() {
  use config <- with_postgres
  let #(pool, child) =
    postgres.supervised(config |> postgres.parameter("search_path", "app"))
  let assert Ok(supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(child)
    |> static_supervisor.start
  let db = postgres.repo(pool)
  assert setting(db, "search_path") == "app"
  let assert [first] = children(supervisor.pid)
  process.kill(first)
  assert eventually(fn() { setting_result(db, "search_path") == Ok("app") })
  let assert [second] = children(supervisor.pid)
  assert second != first
  process.unlink(supervisor.pid)
  process.send_exit(supervisor.pid)
  assert eventually(fn() { result.is_error(setting_result(db, "search_path")) })
}

// While the pool is restarting or stopped, a query crashes the caller rather
// than returning an error. Usually pgo exits it with noproc, as the pool's
// name is unregistered. Mid-restart pgo can instead return an error pog 4.1.0
// has no clause for, raising function_clause in `pog_ffi:convert_error/1`.
fn setting_result(db: Repo, name: String) -> Result(String, Nil) {
  let query = fn() {
    repo.all(
      db,
      "SELECT current_setting('" <> name <> "')",
      [],
      decode.field(0, decode.string, decode.success),
    )
  }
  case crashes(query) {
    Ok(Ok([value])) -> Ok(value)
    _ -> Error(Nil)
  }
}

fn eventually(check: fn() -> Bool) -> Bool {
  let deadline = now() + 10_000
  wait_for(check, deadline)
}

fn wait_for(check: fn() -> Bool, deadline: Int) -> Bool {
  case check() {
    True -> True
    False ->
      case now() >= deadline {
        True -> False
        False -> {
          process.sleep(100)
          wait_for(check, deadline)
        }
      }
  }
}

pub fn migrators_wait_for_each_other_despite_the_lock_timeout_test() {
  use config <- with_postgres
  let assert Ok(admin) = postgres.start(config)
  let name = "howdy_database_test_" <> int_id()
  let assert Ok(_) = repo.execute(admin, "CREATE DATABASE " <> name, [])
  let assert Ok(url) = env.get("HOWDY_DATABASE_TEST_POSTGRES_URL")
  let assert Ok(config) = postgres.from_url(replace_database(url, name))
  let assert Ok(db) =
    config
    |> postgres.lock_timeout(50)
    |> postgres.statement_timeout(50)
    |> postgres.start

  // Hold the migration lock well past both timeouts.
  let holding = process.new_subject()
  process.spawn(fn() {
    database.transaction(db, fn(conn) {
      let assert Ok(_) = database.lock_migrations(conn)
      process.send(holding, Nil)
      process.sleep(300)
      Ok(Nil)
    })
  })
  let assert Ok(Nil) = process.receive(holding, 5000)
  let package =
    migration.Package("notes", [
      gloo_migration.new(
        1,
        "create_notes",
        "CREATE TABLE notes_notes (id TEXT PRIMARY KEY)",
      ),
    ])
  assert migration.run(db, [package]) == Ok(Nil)

  let assert Ok(_) = repo.close(db)
  let assert Ok(_) =
    repo.execute(admin, "DROP DATABASE " <> name <> " WITH (FORCE)", [])
  let assert Ok(_) = repo.close(admin)
  Nil
}

/// A table private to one test, as if a Squirrel app and a Howdy module
/// both wrote to it.
fn notes_table(pool: postgres.Pool) -> #(String, fn() -> List(String)) {
  let table = "howdy_database_notes_" <> int_id()
  let assert Ok(_) =
    pog.query("CREATE TABLE " <> table <> " (body TEXT PRIMARY KEY)")
    |> pog.execute(postgres.connection(pool))
  let bodies = fn() {
    let assert Ok(rows) =
      repo.all(
        postgres.repo(pool),
        "SELECT body FROM " <> table <> " ORDER BY body",
        [],
        decode.field(0, decode.string, decode.success),
      )
    rows
  }
  #(table, bodies)
}

fn pog_insert(conn: pog.Connection, table: String, body: String) {
  pog.query("INSERT INTO " <> table <> " (body) VALUES ($1)")
  |> pog.parameter(pog.text(body))
  |> pog.execute(conn)
  |> result.map(fn(_) { Nil })
  |> result.map_error(postgres.error)
}

fn repo_insert(db: Repo, table: String, body: String) {
  database.execute(db, "INSERT INTO " <> table <> " (body) VALUES ($1)", [
    value.GString(body),
  ])
}

fn drop(pool: postgres.Pool, table: String) {
  let assert Ok(_) =
    pog.query("DROP TABLE " <> table) |> pog.execute(postgres.connection(pool))
  let assert Ok(_) = repo.close(postgres.repo(pool))
  Nil
}

pub fn pog_and_the_repo_share_one_pool_test() {
  use config <- with_postgres
  let assert Ok(pool) = postgres.start_pool(config)
  let #(table, bodies) = notes_table(pool)
  let assert Ok(Nil) = pog_insert(postgres.connection(pool), table, "a")
  let assert Ok(Nil) = repo_insert(postgres.repo(pool), table, "b")
  assert bodies() == ["a", "b"]
  drop(pool, table)
}

pub fn transactions_commit_and_roll_back_pog_and_repo_writes_together_test() {
  use config <- with_postgres
  let assert Ok(pool) = postgres.start_pool(config)
  let #(table, bodies) = notes_table(pool)

  let assert Ok(Nil) = {
    use conn, db <- postgres.transaction(pool)
    use _ <- result.try(pog_insert(conn, table, "a"))
    // A Howdy module's own transaction nests as a savepoint.
    database.transaction(db, fn(tx) { repo_insert(tx, table, "b") })
  }
  assert bodies() == ["a", "b"]

  let failed = {
    use conn, db <- postgres.transaction(pool)
    use _ <- result.try(pog_insert(conn, table, "c"))
    use _ <- result.try(repo_insert(db, table, "d"))
    Error(service.Invalid("changed my mind"))
  }
  assert failed == Error(service.Invalid("changed my mind"))
  assert bodies() == ["a", "b"]

  // A failed inner transaction only undoes its own savepoint.
  let assert Ok(Nil) = {
    use conn, db <- postgres.transaction(pool)
    let assert Error(_) =
      database.transaction(db, fn(tx) {
        use _ <- result.try(repo_insert(tx, table, "e"))
        repo_insert(tx, table, "a")
      })
    pog_insert(conn, table, "f")
  }
  assert bodies() == ["a", "b", "f"]
  drop(pool, table)
}

pub fn transaction_hooks_bracket_pog_transactions_test() {
  use config <- with_postgres
  let assert Ok(pool) = postgres.start_pool(config)
  let #(table, _) = notes_table(pool)
  let events = process.new_subject()
  let me = process.self()
  database.around_transactions("test_pog_transactions", fn(run) {
    case process.self() == me {
      False -> run()
      True -> {
        process.send(events, "before")
        let answer = run()
        process.send(events, "after")
        answer
      }
    }
  })
  let assert Ok(Nil) = {
    use conn, db <- postgres.transaction(pool)
    use _ <- result.try(pog_insert(conn, table, "a"))
    database.transaction(db, fn(tx) { repo_insert(tx, table, "b") })
  }
  database.around_transactions("test_pog_transactions", fn(run) { run() })
  assert process.receive(events, 0) == Ok("before")
  assert process.receive(events, 0) == Ok("after")
  assert process.receive(events, 0) == Error(Nil)
  drop(pool, table)
}

pub fn an_application_started_pog_pool_can_be_adopted_test() {
  use config <- with_postgres
  let #(host, port, name, user, password, _, _) = postgres.inspect(config)
  let assert Ok(started) =
    pog.default_config(process.new_name(prefix: "howdy_database_test"))
    |> pog.host(host)
    |> pog.port(port)
    |> pog.database(name)
    |> pog.user(user)
    |> pog.password(password)
    |> pog.pool_size(2)
    |> pog.start
  let pool = postgres.from_pog(started)
  let #(table, bodies) = notes_table(pool)
  let assert Ok(Nil) = {
    use conn, db <- postgres.transaction(pool)
    use _ <- result.try(pog_insert(conn, table, "a"))
    repo_insert(db, table, "b")
  }
  assert bodies() == ["a", "b"]
  drop(pool, table)
}

// The refusal happens before any connection is used, so a pool that has
// never connected is enough to test it without a server.
pub fn a_pool_transaction_is_refused_inside_a_repo_transaction_test() {
  let assert Ok(db) = sqlite.start(sqlite.memory())
  let connection =
    pog.named_connection(process.new_name(prefix: "howdy_database_test"))
  let pool =
    postgres.from_pog(actor.Started(pid: process.self(), data: connection))
  let answer =
    database.transaction(db, fn(_) {
      postgres.transaction(pool, fn(_, _) { Ok(Nil) })
    })
  assert answer
    == Error(service.Internal(
      "a pool transaction cannot be opened inside a repo transaction",
    ))
  let assert Ok(_) = repo.close(db)
  Nil
}

pub fn pog_errors_map_like_gloo_errors_without_driver_detail_test() {
  assert postgres.error(pog.ConstraintViolated("secret", "pk", "secret"))
    == service.Conflict("the record conflicts with existing data")
  assert postgres.error(pog.PostgresqlError("42P01", "undefined", "secret"))
    == service.Internal("database operation failed")
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

fn int_id() -> String {
  int.to_string(int.absolute_value(unique_integer()))
}

/// The test URL ends in its database name.
fn replace_database(url: String, name: String) -> String {
  let assert [_, ..rest] = string.split(url, "/") |> list.reverse
  string.join(list.reverse([name, ..rest]), "/")
}

// -- Listening -----------------------------------------------------------------

pub fn listening_refuses_what_it_cannot_do_test() {
  let assert Ok(db) = sqlite.start(sqlite.memory())
  assert postgres.listen(db, "changes", fn(_) { Nil })
    == Error(postgres.NotPostgres)
  assert postgres.listen(db, "Changes; DROP", fn(_) { Nil })
    == Error(postgres.InvalidChannel)
  assert postgres.listen(db, "9lives", fn(_) { Nil })
    == Error(postgres.InvalidChannel)
  assert postgres.notify(db, "bad channel", "x")
    == Error(
      service.Invalid(postgres.listen_error_to_string(postgres.InvalidChannel)),
    )
}

pub fn a_listener_hears_notify_from_any_connection_test() {
  use config <- with_postgres
  let assert Ok(db) = postgres.start(config)
  let heard = process.new_subject()
  // Settings remembered for a pool this module opened.
  let assert Ok(listener) =
    postgres.listen(db, "howdy_test", fn(payload) {
      process.send(heard, payload)
    })
  let assert Ok(Nil) = postgres.notify(db, "howdy_test", "it's here")
  assert process.receive(heard, 5000) == Ok("it's here")
  // Sent inside a transaction, it arrives on commit, and not on rollback.
  let assert Error(_) =
    database.transaction(db, fn(conn) {
      let assert Ok(Nil) = postgres.notify(conn, "howdy_test", "rolled back")
      Error(service.Invalid("no"))
    })
  let assert Ok(Nil) =
    database.transaction(db, fn(conn) {
      postgres.notify(conn, "howdy_test", "committed")
    })
  assert process.receive(heard, 5000) == Ok("committed")
  // A notify that crashes is logged, and listening carries on.
  postgres.stop_listening(listener)
  let assert Ok(crashing) =
    postgres.listen(db, "howdy_test", fn(payload) {
      case payload {
        "boom" -> panic as "the app's code crashed"
        _ -> process.send(heard, payload)
      }
    })
  let assert Ok(Nil) = postgres.notify(db, "howdy_test", "boom")
  let assert Ok(Nil) = postgres.notify(db, "howdy_test", "after")
  assert process.receive(heard, 5000) == Ok("after")
  postgres.stop_listening(crashing)
  let assert Ok(_) = repo.close(db)
  Nil
}

pub fn a_listener_finds_the_settings_of_a_pool_opened_elsewhere_test() {
  use config <- with_postgres
  let #(host, port, name, user, password, _, _) = postgres.inspect(config)
  let settings =
    pog.default_config(process.new_name(prefix: "howdy_database_test"))
    |> pog.host(host)
    |> pog.port(port)
    |> pog.database(name)
    |> pog.user(user)
    |> pog.password(password)
  let assert Ok(started) = pog.start(settings)
  let db = postgres.repo(postgres.from_pog(started))
  let heard = process.new_subject()
  let notify = fn(payload) { process.send(heard, payload) }
  // Found inside pgo, and given by the app.
  let assert Ok(found) = postgres.listen(db, "howdy_test_elsewhere", notify)
  let assert Ok(given) =
    postgres.listen_via(settings, "howdy_test_elsewhere", notify)
  let assert Ok(Nil) = postgres.notify(db, "howdy_test_elsewhere", "both")
  assert process.receive(heard, 5000) == Ok("both")
  assert process.receive(heard, 5000) == Ok("both")
  postgres.stop_listening(found)
  postgres.stop_listening(given)
}

pub fn a_listener_stops_with_its_owner_test() {
  use config <- with_postgres
  let assert Ok(db) = postgres.start(config)
  let started = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(listener) = postgres.listen(db, "howdy_test", fn(_) { Nil })
      process.send(started, postgres.listener_pid(listener))
      process.sleep_forever()
    })
  let assert Ok(listener) = process.receive(started, 5000)
  let gone = process.monitor(listener)
  process.kill(owner)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(gone, fn(down) { down })
    |> process.selector_receive(within: 5000)
  let assert Ok(_) = repo.close(db)
  Nil
}
