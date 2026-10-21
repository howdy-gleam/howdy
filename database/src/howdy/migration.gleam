//// Package-owned migrations over Gloo (PostgreSQL and SQLite). Run explicitly during deployment.
//// The list order is the dependency order. SQL must not contain transaction
//// control statements. Published migrations are immutable; append new ones.

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gloo/migration as gloo_migration
import gloo/repo.{type Repo}
import gloo/sql
import howdy/database as db
import howdy/service

/// A set of migrations owning the schema namespace `<name>_`.
pub type Package {
  Package(name: String, migrations: List(gloo_migration.Migration))
}

type Hook =
  fn(fn() -> service.Result(Nil)) -> service.Result(Nil)

@external(erlang, "howdy_database_ffi", "around_runs")
fn register(name: String, hook: Hook) -> Nil

@external(erlang, "howdy_database_ffi", "run_hooks")
fn hooks() -> List(Hook)

/// Bracket every later `run` on this node, whichever packages it applies, for
/// a module that keeps state derived from the database in memory, such as a
/// cache to invalidate. Any package's migration may rewrite another's rows.
/// `hook` must call the function it is given exactly once and return its
/// result; it runs outside the migration transaction. Registering `name`
/// again replaces its hook. A separate deployment command has no such state
/// and registers nothing.
pub fn around_runs(name: String, hook: Hook) -> Nil {
  register(name, hook)
}

const postgres_marker = "\n-- howdy:postgres\n"

const sqlite_marker = "\n-- howdy:sqlite\n"

/// SQL that differs by database, for a migration's `up`. Append it to any
/// statements both databases share. The checksum covers both variants, so a
/// migration is the same migration wherever it runs.
///
/// ```gleam
/// gloo_migration.new(2, "add_seen", "CREATE TABLE app_notes (id TEXT);"
///   <> migration.per_database(
///     postgres: "ALTER TABLE app_notes ADD COLUMN seen TIMESTAMPTZ",
///     sqlite: "ALTER TABLE app_notes ADD COLUMN seen BIGINT",
///   ))
/// ```
pub fn per_database(
  postgres postgres: String,
  sqlite sqlite: String,
) -> String {
  postgres_marker <> postgres <> sqlite_marker <> sqlite
}

/// The statements of `up` that apply to this database.
fn statements(up: String, backend: db.Backend) -> String {
  case string.split_once(up, postgres_marker) {
    Error(Nil) -> up
    Ok(#(shared, variants)) ->
      case string.split_once(variants, sqlite_marker), backend {
        Ok(#(postgres, _)), db.Postgres -> shared <> postgres
        Ok(#(_, sqlite)), db.Sqlite -> shared <> sqlite
        Error(Nil), _ -> up
      }
  }
}

const ledger = "CREATE TABLE IF NOT EXISTS howdy_migrations (package TEXT NOT NULL, version BIGINT NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(package, version)); CREATE TABLE IF NOT EXISTS howdy_migration_schemas (package TEXT PRIMARY KEY NOT NULL, fingerprint TEXT NOT NULL)"

pub fn run(database: Repo, packages: List(Package)) -> service.Result(Nil) {
  let names = list.map(packages, fn(p) { p.name })
  case
    list.length(list.unique(names)) == list.length(names)
    && list.all(names, fn(name) {
      name != ""
      && list.all(string.to_graphemes(name), fn(c) {
        string.contains("abcdefghijklmnopqrstuvwxyz0123456789_", c)
      })
    })
  {
    False ->
      Error(service.Invalid(
        "migration package names must be unique, nonempty lowercase identifiers",
      ))
    True -> {
      use <- bracket(hooks())
      use conn <- db.transaction(database)
      use _ <- result.try(db.lock_migrations(conn))
      use _ <- result.try(db.exec(conn, ledger))
      // Promote SQLite's deferred BEGIN to a write transaction before reads.
      use _ <- result.try(db.promote(conn, "howdy_migration_schemas"))
      use _ <- result.try(
        list.try_fold(packages, Nil, fn(_, package) { apply(conn, package) }),
      )
      // Reject changes to another package, even if it was not in this batch.
      use names <- result.try(db.query(
        conn,
        "SELECT package FROM howdy_migration_schemas",
        [],
        decode.field(0, decode.string, decode.success),
      ))
      list.try_fold(names, Nil, fn(_, name) { verify_fingerprint(conn, name) })
    }
  }
}

fn bracket(
  hooks: List(Hook),
  run: fn() -> service.Result(Nil),
) -> service.Result(Nil) {
  case hooks {
    [] -> run()
    [hook, ..rest] -> hook(fn() { bracket(rest, run) })
  }
}

/// Check compatibility without applying migrations. An older runtime refuses
/// a newer schema, and edited migration SQL is rejected.
pub fn check(database: Repo, package: Package) -> service.Result(Nil) {
  use conn <- db.connect(database)
  use applied <- result.try(history(conn, package.name))
  case applied == expected(package.migrations) {
    True -> verify_fingerprint(conn, package.name)
    False ->
      Error(service.Internal(
        "database schema is incompatible; run the matching package migrations",
      ))
  }
}

/// Operator escape hatch: accept the owned schema as it is now as the package's
/// baseline. Catalog output that feeds the fingerprint can change without any
/// real drift, for example after a PostgreSQL major upgrade or a dump and
/// restore. Run this deliberately, from a deployment command and never at
/// startup, after confirming the schema by hand. It refuses unless the
/// recorded migration history exactly matches this package version, so it
/// cannot paper over missing or edited migrations.
pub fn rebaseline(database: Repo, package: Package) -> service.Result(Nil) {
  use conn <- db.transaction(database)
  use _ <- result.try(db.lock_migrations(conn))
  use _ <- result.try(db.promote(conn, "howdy_migration_schemas"))
  use applied <- result.try(history(conn, package.name))
  case applied != [] && applied == expected(package.migrations) {
    False ->
      Error(service.Internal(
        "migration history differs from the installed package",
      ))
    True -> record_fingerprint(conn, package.name)
  }
}

fn history(conn: Repo, name: String) {
  let row = {
    use version <- decode.field(0, decode.int)
    use checksum <- decode.field(1, decode.string)
    decode.success(#(version, checksum))
  }
  db.query(
    conn,
    "SELECT version, checksum FROM howdy_migrations WHERE package = $1 ORDER BY version",
    [sql.string(name)],
    row,
  )
}

// Ledgers written before this module left howdy_auth hold these digests.
fn digest(value: String) -> String {
  crypto.hash(crypto.Sha256, <<value:utf8>>)
  |> bit_array.base64_url_encode(False)
}

fn checksum(m: gloo_migration.Migration) -> String {
  digest(m.name <> ":" <> m.up)
}

fn expected(migrations: List(gloo_migration.Migration)) {
  list.map(migrations, fn(m) { #(m.version, checksum(m)) })
}

fn apply(conn: Repo, package: Package) -> service.Result(Nil) {
  let versions = list.map(package.migrations, fn(m) { m.version })
  use _ <- result.try(
    case
      list.all(versions, fn(v) { v > 0 })
      && list.unique(versions) == versions
      && list.sort(versions, int.compare) == versions
    {
      True -> Ok(Nil)
      False ->
        Error(service.Invalid(
          "package migration versions must be positive and strictly increasing",
        ))
    },
  )
  use applied <- result.try(history(conn, package.name))
  use _ <- result.try(case applied {
    [] -> Ok(Nil)
    _ -> verify_fingerprint(conn, package.name)
  })
  let wanted = expected(package.migrations)
  case
    list.take(wanted, list.length(applied)) == applied
    && list.length(applied) <= list.length(wanted)
  {
    False ->
      Error(service.Internal(
        "migration history differs from the installed package",
      ))
    True -> {
      let pending = list.drop(package.migrations, list.length(applied))
      use backend <- result.try(db.backend(conn))
      use _ <- result.try(
        list.try_fold(pending, Nil, fn(_, m) {
          use _ <- result.try(db.exec(conn, statements(m.up, backend)))
          db.execute(
            conn,
            "INSERT INTO howdy_migrations(package, version, checksum) VALUES ($1, $2, $3)",
            [
              sql.string(package.name),
              sql.int(m.version),
              sql.string(checksum(m)),
            ],
          )
        }),
      )
      record_fingerprint(conn, package.name)
    }
  }
}

fn record_fingerprint(conn: Repo, name: String) -> service.Result(Nil) {
  use fingerprint <- result.try(fingerprint(conn, name))
  db.execute(
    conn,
    "INSERT INTO howdy_migration_schemas(package, fingerprint) VALUES ($1, $2) ON CONFLICT(package) DO UPDATE SET fingerprint = excluded.fingerprint",
    [sql.string(name), sql.string(fingerprint)],
  )
}

// Packages own all schema objects whose name or target table begins with
// `<package>_`. Application extensions must live in their own namespace.
// Include indexes and triggers so out-of-band changes cannot silently alter
// constraints or execution. SQL NULL auto-index entries are represented too.
// Two exceptions: a non-unique index named outside the package namespace is
// ignored. It cannot change what the tables accept or return, and operators
// need to be able to add one to a hot table without a package release. And a
// trigger whose name begins with `howdy_admin_` is ignored: the development
// admin (`howdy_admin`) adds one per table on PostgreSQL to hear about
// changes, and it only notifies, never alters a row.
fn fingerprint(conn: Repo, name: String) -> service.Result(String) {
  let prefix = name <> "_"
  let row = {
    use kind <- decode.field(0, decode.string)
    use name <- decode.field(1, decode.string)
    use table <- decode.field(2, decode.string)
    use sql <- decode.field(3, decode.string)
    decode.success(json.array([kind, name, table, sql], json.string))
  }
  use backend <- result.try(db.backend(conn))
  let statement = case backend {
    db.Postgres -> postgres_fingerprint
    db.Sqlite -> sqlite_fingerprint
  }
  use objects <- result.try(db.query(
    conn,
    statement,
    [
      sql.string(prefix),
      sql.string(prefix),
      sql.string(prefix),
      sql.string(prefix),
    ],
    row,
  ))

  Ok(digest(json.to_string(json.array(objects, fn(value) { value }))))
}

fn verify_fingerprint(conn: Repo, name: String) -> service.Result(Nil) {
  use stored <- result.try(db.query(
    conn,
    "SELECT fingerprint FROM howdy_migration_schemas WHERE package = $1",
    [sql.string(name)],
    decode.field(0, decode.string, decode.success),
  ))
  use current <- result.try(fingerprint(conn, name))
  case stored {
    [expected] if expected == current -> Ok(Nil)
    _ ->
      Error(service.Internal(
        "module-owned database schema was changed outside its migrations",
      ))
  }
}

const sqlite_fingerprint = "WITH owned AS (SELECT name FROM sqlite_master WHERE substr(name, 1, length($1)) = $2)
SELECT type, name, tbl_name, COALESCE(sql, '') FROM sqlite_master
WHERE (name IN (SELECT name FROM owned) OR tbl_name IN (SELECT name FROM owned))
AND NOT (type = 'index' AND sql IS NOT NULL AND upper(sql) NOT LIKE 'CREATE UNIQUE%'
 AND substr(name, 1, length($3)) <> $4)
AND NOT (type = 'trigger' AND substr(name, 1, 12) = 'howdy_admin_')
ORDER BY type, name"

const postgres_fingerprint = "WITH owned AS (
 SELECT c.* FROM pg_catalog.pg_class c
 JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = current_schema() AND left(c.relname, length($1)) = $2
 AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
), objects AS (
 SELECT 'relation'::text AS kind, o.relname::text AS name, o.relname::text AS tbl,
 concat(o.relkind, ':', o.relpersistence, ':', o.relrowsecurity, ':', o.relforcerowsecurity) AS definition FROM owned o
 UNION ALL
 SELECT 'column', o.relname || '.' || a.attname, o.relname,
 concat(a.attnum, ':', format_type(a.atttypid, a.atttypmod), ':', a.attnotnull, ':', a.attidentity, ':', a.attgenerated, ':', COALESCE(pg_get_expr(d.adbin, d.adrelid), ''))
 FROM owned o JOIN pg_catalog.pg_attribute a ON a.attrelid = o.oid
 LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = o.oid AND d.adnum = a.attnum
 WHERE a.attnum > 0 AND NOT a.attisdropped
 UNION ALL
 SELECT 'constraint', o.relname || '.' || c.conname, o.relname, pg_get_constraintdef(c.oid, true)
 FROM owned o JOIN pg_catalog.pg_constraint c ON c.conrelid = o.oid
 UNION ALL
 SELECT 'index', c.relname, o.relname, pg_get_indexdef(i.indexrelid)
 FROM owned o JOIN pg_catalog.pg_index i ON i.indrelid = o.oid JOIN pg_catalog.pg_class c ON c.oid = i.indexrelid
 WHERE i.indisunique OR left(c.relname, length($3)) = $4
 UNION ALL
 SELECT 'trigger', o.relname || '.' || t.tgname, o.relname, pg_get_triggerdef(t.oid, true) || ':' || t.tgenabled::text
 FROM owned o JOIN pg_catalog.pg_trigger t ON t.tgrelid = o.oid
 WHERE NOT t.tgisinternal AND left(t.tgname, 12) <> 'howdy_admin_'
 UNION ALL
 SELECT 'policy', o.relname || '.' || p.polname, o.relname,
 concat(p.polcmd, ':', p.polpermissive, ':',
 (SELECT COALESCE(string_agg(r.rolname::text, ',' ORDER BY r.rolname), 'public') FROM pg_catalog.pg_roles r WHERE r.oid = ANY(p.polroles)), ':', pg_get_expr(p.polqual, p.polrelid), ':', pg_get_expr(p.polwithcheck, p.polrelid))
 FROM owned o JOIN pg_catalog.pg_policy p ON p.polrelid = o.oid
 UNION ALL
 SELECT 'view', o.relname, o.relname, pg_get_viewdef(o.oid, true) FROM owned o WHERE o.relkind IN ('v', 'm')
) SELECT kind, name, tbl, definition FROM objects ORDER BY kind, name"
