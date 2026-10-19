# howdy_database

Package-owned migrations and portable transactions over
[Gloo](https://hexdocs.pm/gloo) for Howdy apps, on PostgreSQL and SQLite.
[`howdy_auth`](https://github.com/mikeyjones/howdy/blob/v2.1.1/auth/README.md) is built on it, and applications can use it
for their own tables, with or without auth.

```sh
gleam add howdy_database@1 gloo@1
```

The application opens, configures and closes the Gloo Repo; everything else in
this package only receives it. Operations return `howdy/service` results, so a
failure maps straight to an HTTP response.

## Opening the database

For SQLite, open the Repo with Gloo and call `database.sqlite_defaults(db)`
once. It turns on foreign keys, waits up to five seconds for another
connection's write lock, and switches the file to write-ahead logging.

For PostgreSQL, `howdy/database/postgres` opens a Repo with production
defaults:

```gleam
import howdy/database/postgres

let assert Ok(db) =
  postgres.from_env()
  |> result.try(postgres.start)
```

- `from_env` reads `DATABASE_URL`, and `from_url` takes
  `postgres://user:password@host:port/database?sslmode=...` directly. The URL
  is never repeated in an error.
- Without `sslmode`, TLS is off for loopback addresses and dotless host names
  such as a Compose service called `db`, and verified against the system's
  CAs for everything else. `sslmode=require` encrypts without verifying, and
  `disable` turns TLS off. `allow` and `prefer` are refused.
- Every connection starts with `timezone` UTC, a 30 second
  `statement_timeout`, a 5 second `lock_timeout` and a 60 second
  `idle_in_transaction_session_timeout`. Change them with the functions of
  the same name (zero turns one off), or set any parameter with `parameter`.
  Migrations lift the statement and lock timeouts for their own transaction.
- `start` waits up to `startup_timeout` (10 seconds) for the server to answer
  and refuses a server older than PostgreSQL 14, so a wrong host, password or
  database fails at startup instead of on the first request.

Behind a pooler such as PgBouncer that rejects unknown startup parameters,
set the timeouts on the role with `ALTER ROLE ... SET` and pass zero here.
The driver reports the Erlang node name as `application_name`.

## Migrations

A package is a name and a list of ordinary `gloo/migration.Migration` values.
It owns every table, index and trigger whose name begins with `<name>_`.

```gleam
import gloo/migration as gloo_migration
import howdy/migration

pub fn schema() -> migration.Package {
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
```

Run every package in one transaction from a deployment command, before starting
the new version, and check at startup:

```gleam
// src/migrate.gleam
let assert Ok(_) =
  migration.run(db, [auth.schema(), authorization.schema(), notes.schema()])

// at startup
let assert Ok(_) = migration.check(db, notes.schema())
```

- `run` applies what is pending, in list order, and rolls the whole batch back
  on failure. Concurrent migrators serialize. The ledger records a checksum per
  migration, so edited or missing history is refused: append new migrations and
  never edit a published one. There are no down migrations.
- `check` applies nothing. It refuses a schema that is older or newer than the
  installed package, and one whose owned objects were changed outside its
  migrations. A plain, non-unique index named outside the namespace is
  allowed, as is a trigger named `howdy_admin_…`, which the development admin
  adds to hear about changes.
- `rebaseline` accepts the current shape of the owned schema after you have
  confirmed by hand that it has not drifted, for example after a PostgreSQL
  major upgrade. Never call it at startup.
- `per_database` appends the statements that differ by database; only the
  matching variant runs, and the checksum covers both.
- `around_runs` brackets every later `run` on the node, for a module that keeps
  state derived from the database in memory. Auth uses it to invalidate its
  authorization cache.

Migration SQL is trusted code. It is split on semicolons, as in Gloo's runner,
so it cannot contain semicolons inside literals or procedural bodies, nor
transaction control. Do not apply the same migrations through `gloo/runner`.

## Transactions and queries

```gleam
import gloo/sql
import howdy/database
import howdy/service

pub fn rename(db, id: String, slug: String) -> service.Result(Nil) {
  use conn <- database.write_transaction(db, touching: "notes_notes")
  use _ <- result.try(database.one(
    conn,
    "SELECT id FROM notes_notes n WHERE id = $1"
      <> database.for_update(conn, "n"),
    [sql.string(id)],
    decode.field(0, decode.string, decode.success),
    or: service.NotFound("note"),
  ))
  database.execute_or(
    conn,
    "UPDATE notes_notes SET slug = $1 WHERE id = $2",
    [sql.string(slug), sql.string(id)],
    on_constraint: fn(_) { service.Conflict("slug already taken") },
  )
}
```

- `transaction` commits on `Ok` and rolls back on `Error`, returning your typed
  error unchanged. `write_transaction` is for work that reads before it writes:
  it takes SQLite's write lock up front so independent connections cannot race
  the upgrade. `connect` runs without a transaction.
- `query`, `one`, `execute` and `exec` run SQL. Driver errors may contain
  personal data, so they are reported as an opaque `service.Internal`.
  `execute_or` turns a violated constraint into an error of your choosing.
- `returning` runs an INSERT, UPDATE or DELETE built with `gloo/query` and
  returns the row it touched, so an update or delete and its result are one
  statement and a missing row is your `NotFound`. Gloo's own
  `returning_columns` only reaches INSERT. `howdy create` contexts use it.
- `for_update`, `read_time` and `write_time` produce the SQL fragments that
  differ between the two databases: row locks, and instants kept as
  `TIMESTAMPTZ` on PostgreSQL and unix seconds on SQLite.
- `backend` reports which database a Repo is; `locked` is the fair, reentrant
  mutex beneath all of this.
- `around_transactions` brackets the outermost `transaction` in each process,
  including `postgres.transaction`, for a module whose in-memory state must
  change after the commit rather than after a nested savepoint. Auth uses it
  so a grant changed inside your own transaction invalidates its cache when
  your transaction ends.

Gloo's SQLite adapter binds `$n` placeholders by position: never reuse one
placeholder in a query, pass the value again.

**Sharing a SQLite Repo.** Gloo 1.x gives a SQLite Repo one connection.
Everything that goes through this module serializes on that Repo, first come
first served, so auth and application code can share it. Calls made directly
through `gloo/repo` are not serialized; give those their own Repo on the same
file. PostgreSQL's pool reserves a connection per transaction, so none of this
applies there.

## Testing

```sh
gleam test
HOWDY_DATABASE_TEST_POSTGRES_URL=postgres://postgres@localhost/postgres gleam test
```

The PostgreSQL tests run only when the variable is set; its user must be able
to create databases.
