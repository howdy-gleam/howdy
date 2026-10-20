//// Portable transactions and queries over a Gloo Repo (PostgreSQL and
//// SQLite). Gloo is the storage seam. The application owns the Repo
//// lifecycle; every Howdy module and the application itself can share it.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string
import gloo/error
import gloo/query.{type Query}
import gloo/repo.{type Repo}
import gloo/telemetry
import gloo/value.{type GlooValue}
import howdy/service
import howdy/trace

/// Run with the fair, reentrant lock for `key` held. Waiters are served in
/// arrival order and the lock is released if its holder dies.
@external(erlang, "howdy_database_ffi", "with_lock")
pub fn locked(key: key, run: fn() -> a) -> a

pub type Backend {
  Postgres
  Sqlite
}

/// The one place an adapter name is interpreted. Anything else is refused
/// rather than treated as one of the supported databases.
pub fn backend(repo: Repo) -> service.Result(Backend) {
  case repo.adapter_name(repo) {
    "postgres" -> Ok(Postgres)
    "sqlite" -> Ok(Sqlite)
    _ -> Error(service.Internal("unsupported Gloo database adapter"))
  }
}

/// The Repo, reporting each query it runs as an OpenTelemetry span, named
/// after the operation and table, such as `SELECT app_notes`, with the SQL
/// text but never the parameter values. Queries only get a span inside a
/// span that is being recorded, such as a request's, so background polling
/// does not fill your traces. Without `howdy_telemetry` started this costs
/// next to nothing. `howdy/database/postgres` traces the Repos it opens;
/// call this on a SQLite Repo after opening it.
pub fn traced(repo: Repo) -> Repo {
  let system = case backend(repo) {
    Ok(Postgres) -> "postgresql"
    Ok(Sqlite) -> "sqlite"
    Error(_) -> repo.adapter_name(repo)
  }
  repo.with_telemetry(
    repo,
    telemetry.with_handler(fn(event) {
      case event {
        telemetry.QueryStart(..) -> query_started()
        telemetry.QueryEnd(sql:, rows:, ..) ->
          query_ended(system, sql, Ok(rows))
        telemetry.QueryError(sql:, ..) -> query_ended(system, sql, Error(Nil))
        telemetry.TransactionStart
        | telemetry.TransactionCommit
        | telemetry.TransactionRollback -> Nil
      }
    }),
  )
}

@external(erlang, "howdy_database_trace_ffi", "query_start")
fn query_started() -> Nil

@external(erlang, "howdy_database_trace_ffi", "query_end")
fn query_ended(system: String, sql: String, outcome: Result(Int, Nil)) -> Nil

/// The settings a SQLite Repo needs for the rest of this module to behave:
/// foreign keys enforced, which SQLite leaves off, and a five second wait for
/// another connection's write lock rather than an immediate failure. It also
/// switches the file to write-ahead logging, which persists in the file, so
/// readers such as a backup or another Repo never block the writer. Call it
/// once after opening the Repo. PostgreSQL needs none of this and is left
/// alone; open it with `howdy/database/postgres` for its defaults.
pub fn sqlite_defaults(repo: Repo) -> service.Result(Nil) {
  use conn <- connect(repo)
  use backend <- result.try(backend(conn))
  case backend {
    Postgres -> Ok(Nil)
    Sqlite ->
      exec(
        conn,
        "PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;
        PRAGMA journal_mode = WAL",
      )
  }
}

/// A check for `howdy/health` that the database answers a `SELECT 1`:
///
/// ```gleam
/// health.new()
/// |> health.check("database", database.health_check(db))
/// ```
///
/// On SQLite it waits its turn behind the queries in progress, like any
/// other, so a write that holds the database for longer than the health
/// check's timeout fails the check too.
pub fn health_check(repo: Repo) -> fn() -> Result(Nil, String) {
  fn() {
    case connect(repo, fn(conn) { Ok(repo.execute(conn, "SELECT 1", [])) }) {
      Ok(Ok(_)) -> Ok(Nil)
      Ok(Error(e)) -> Error(error.to_string(e))
      Error(_) -> Error("unsupported Gloo database adapter")
    }
  }
}

/// Gloo's SQLite Repo has one connection. Serialize operations so a
/// concurrent request cannot join another request's transaction. Everything
/// that goes through this module shares the lock, so modules and application
/// code can safely share one SQLite Repo. Code that calls `gloo/repo`
/// directly on a shared SQLite Repo is not serialized.
pub fn connect(
  repo: Repo,
  run: fn(Repo) -> service.Result(a),
) -> service.Result(a) {
  use backend <- result.try(backend(repo))
  case backend {
    Sqlite -> locked(repo, fn() { run(repo) })
    Postgres -> run(repo)
  }
}

/// Bracket the outermost `transaction` in each process on this node, for a
/// module that keeps state derived from the database in memory, such as a
/// cache that must be invalidated after the commit rather than after a
/// savepoint. `hook` must call the function it is given exactly once and
/// return its result; it runs outside the transaction. Registering `name`
/// again replaces its hook. Transactions opened directly through
/// `gloo/repo` or pog are not bracketed.
pub fn around_transactions(
  name: String,
  hook: fn(fn() -> Dynamic) -> Dynamic,
) -> Nil {
  register_transaction_hook(name, hook)
}

@external(erlang, "howdy_database_ffi", "around_transactions")
fn register_transaction_hook(
  name: String,
  hook: fn(fn() -> Dynamic) -> Dynamic,
) -> Nil

/// Run inside the `around_transactions` hooks unless this process is already
/// inside a Howdy transaction.
@external(erlang, "howdy_database_ffi", "outermost_transaction")
@internal
pub fn bracketed(run: fn() -> a) -> a

/// Whether this process is inside a Howdy transaction, on any Repo or pool.
@external(erlang, "howdy_database_ffi", "in_transaction")
@internal
pub fn in_transaction() -> Bool

/// Commit when `run` returns `Ok`; roll back and return its error otherwise.
/// The transaction is a `transaction` span, with its queries inside.
pub fn transaction(
  repo: Repo,
  run: fn(Repo) -> service.Result(a),
) -> service.Result(a) {
  use <- bracketed
  use <- trace.span("transaction", [])
  use repo <- connect(repo)
  // Gloo 1.x stringifies callback errors during rollback. Keep the original
  // typed domain error in this call's private mailbox rather than parsing it.
  let failures = process.new_subject()
  let answer =
    repo.transaction(repo, fn(tx) {
      case run(tx) {
        Ok(value) -> Ok(value)
        Error(failure) -> {
          process.send(failures, failure)
          Error(error.RollbackError)
        }
      }
    })
  case answer {
    Ok(value) -> Ok(value)
    Error(_) -> {
      trace.set_attributes([trace.bool("db.transaction.rolled_back", True)])
      case process.receive(failures, 0) {
        Ok(failure) -> Error(failure)
        Error(Nil) -> Error(service.Internal("database transaction failed"))
      }
    }
  }
}

/// A transaction that reads before it writes. SQLite's deferred BEGIN takes
/// the write lock only at the first write, and independent connections must
/// not race that read-to-write upgrade, so take it up front.
pub fn write_transaction(
  repo: Repo,
  touching table: String,
  run run: fn(Repo) -> service.Result(a),
) -> service.Result(a) {
  use conn <- transaction(repo)
  use _ <- result.try(promote(conn, table))
  run(conn)
}

/// Acquire SQLite's write lock inside an open transaction using a statement
/// that changes nothing. `table` is trusted, module-owned text.
pub fn promote(conn: Repo, table: String) -> service.Result(Nil) {
  use backend <- result.try(backend(conn))
  case backend {
    Postgres -> Ok(Nil)
    Sqlite -> execute(conn, "DELETE FROM " <> table <> " WHERE 1 = 0", [])
  }
}

/// DDL batches follow Gloo runner's statement convention: semicolon-separated
/// statements, with no embedded semicolons in literals or procedural bodies.
pub fn exec(repo: Repo, statements: String) -> service.Result(Nil) {
  statements
  |> string.split(";")
  |> list.map(string.trim)
  |> list.filter(fn(sql) { sql != "" })
  |> list.try_fold(Nil, fn(_, sql) { execute(repo, sql, []) })
}

pub fn query(
  repo: Repo,
  sql: String,
  args: List(GlooValue),
  decoder: decode.Decoder(a),
) -> service.Result(List(a)) {
  repo.all(repo, sql, args, decoder) |> result.map_error(error)
}

/// The first row, or `missing` when there is none.
pub fn one(
  repo: Repo,
  sql: String,
  args: List(GlooValue),
  decoder: decode.Decoder(a),
  or missing: service.Error,
) -> service.Result(a) {
  use rows <- result.try(query(repo, sql, args, decoder))
  case rows {
    [row, ..] -> Ok(row)
    [] -> Error(missing)
  }
}

pub fn execute(
  repo: Repo,
  sql: String,
  args: List(GlooValue),
) -> service.Result(Nil) {
  repo.execute(repo, sql, args)
  |> result.map(fn(_) { Nil })
  |> result.map_error(error)
}

/// `execute`, with a violated constraint turned into a domain error such as
/// `service.Conflict`. PostgreSQL passes the constraint's name. SQLite has
/// none to give and passes its description, such as
/// `UNIQUE constraint failed: app_notes.slug`; do not show either to users.
/// In a PostgreSQL transaction the violation has already aborted the
/// transaction, so return the error rather than carrying on.
pub fn execute_or(
  repo: Repo,
  sql: String,
  args: List(GlooValue),
  on_constraint violated: fn(String) -> service.Error,
) -> service.Result(Nil) {
  case repo.execute(repo, sql, args) {
    Ok(_) -> Ok(Nil)
    Error(error.ConstraintError(name)) -> Error(violated(name))
    Error(failure) -> Error(error(failure))
  }
}

/// Run an INSERT, UPDATE or DELETE built with `gloo/query` and return the row
/// it wrote or removed, decoded with the query's decoder. Gloo's own
/// `returning_columns` only reaches INSERT; do not combine the two. One
/// statement does the work and reports it, so there is no window between
/// them: a statement that matched no row returns `missing`. `columns` must
/// be in the order the decoder reads them, and are quoted here.
///
/// ```gleam
/// query.from(todo_item.table())
/// |> query.update(todo_item.values(input))
/// |> query.where(query.Eq("id", sql.int(id)))
/// |> database.returning(db, _, todo_item.columns, or: service.NotFound("todo not found"))
/// ```
///
/// A violated constraint is a `Conflict` that names nothing. If the conditions
/// match several rows they are all written and the first is returned.
///
/// Call `query.where` after `query.update` or `query.delete`, as above: both
/// start a fresh condition list in Gloo 1.x, so an earlier `where` is dropped
/// and the statement writes or removes every row.
pub fn returning(
  repo: Repo,
  mutation: Query(a),
  columns: List(String),
  or missing: service.Error,
) -> service.Result(a) {
  let #(statement, parameters) = query.to_sql(mutation)
  let columns =
    list.map(columns, fn(column) {
      "\"" <> string.replace(column, "\"", "\"\"") <> "\""
    })
  let statement = statement <> " RETURNING " <> string.join(columns, ", ")
  case repo.all(repo, statement, parameters, query.decoder(mutation)) {
    Ok([row, ..]) -> Ok(row)
    Ok([]) -> Error(missing)
    Error(error.ConstraintError(_)) ->
      Error(service.Conflict("the record conflicts with existing data"))
    Error(failure) -> Error(error(failure))
  }
}

pub fn error(_error: error.GlooError) -> service.Error {
  // Driver errors may contain personal data. Do not log or return them.
  service.Internal("database operation failed")
}

/// Row-lock suffix for a SELECT inside a transaction. SQLite transactions
/// already hold the database write lock. `alias` is trusted query text.
pub fn for_update(repo: Repo, alias: String) -> String {
  case backend(repo) {
    Ok(Postgres) -> " FOR UPDATE OF " <> alias
    _ -> ""
  }
}

/// SQL reading an instant column as unix seconds. PostgreSQL keeps instants
/// as TIMESTAMPTZ; SQLite has no such type and keeps the seconds themselves.
/// Fractional seconds, such as from `CURRENT_TIMESTAMP`, are truncated like
/// the system clock's seconds: a bare `::bigint` cast would round up, reading
/// an instant as up to half a second in the future. `column` is trusted query
/// text.
pub fn read_time(repo: Repo, column: String) -> String {
  case backend(repo) {
    Ok(Postgres) -> "FLOOR(EXTRACT(EPOCH FROM " <> column <> "))::bigint"
    _ -> column
  }
}

/// SQL writing the unix seconds bound to `placeholder`, such as `$2`, to an
/// instant column.
pub fn write_time(repo: Repo, placeholder: String) -> String {
  case backend(repo) {
    Ok(Postgres) -> "to_timestamp(" <> placeholder <> "::bigint)"
    _ -> placeholder
  }
}

/// Serialize migration processes before they inspect or change the ledger.
/// Session timeouts are for request traffic: a migrator waits its turn and
/// may rebuild a large table, so lift them for this transaction only.
@internal
pub fn lock_migrations(repo: Repo) -> service.Result(Nil) {
  use backend <- result.try(backend(repo))
  case backend {
    Postgres ->
      exec(
        repo,
        "SET LOCAL statement_timeout = 0; SET LOCAL lock_timeout = 0;
        SELECT pg_advisory_xact_lock(1752131449, 1835624306)::text",
      )
    Sqlite -> Ok(Nil)
  }
}
