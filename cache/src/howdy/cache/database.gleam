//// A cache store in a Gloo Repo, on PostgreSQL or SQLite, through
//// `howdy/database`. Every node using the same database shares the
//// entries and their invalidations.
////
//// ```gleam
//// import howdy/cache
//// import howdy/cache/database as cache_database
////
//// let assert Ok(Nil) = migration.run(db, [cache_database.schema()])
//// let assert Ok(store) = cache_database.store(db)
//// let app_cache = cache.new(store)
//// ```
////
//// Reading an entry is one query, so this store pays off for work that
//// costs more than a query: several joined queries, a call to another
//// service, rendering a large page. On PostgreSQL the entry tables are
//// `UNLOGGED`: writes skip the write-ahead log, and a crash empties them,
//// which for a cache is only a cold start.
////
//// Expired entries are deleted every five minutes by a process that lives
//// as long as the process that called `store`, so call it in `main`.
//// `invalidate` also deletes the entries carrying the tags. The table of
//// tag versions keeps one row per tag ever invalidated; it has to, since
//// forgetting a version could make an old entry current again.

import gleam/bool
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gloo/migration as gloo_migration
import gloo/repo.{type Repo}
import gloo/sql
import howdy/cache.{type Store, Stored}
import howdy/database
import howdy/migration
import howdy/service

/// The `howdy_cache_` tables. Run with `howdy/migration` during deployment.
pub fn schema() -> migration.Package {
  migration.Package("howdy_cache", [
    gloo_migration.new(
      1,
      "create_cache",
      migration.per_database(
        postgres: entry_tables("CREATE UNLOGGED TABLE"),
        sqlite: entry_tables("CREATE TABLE"),
      ),
    ),
  ])
}

fn entry_tables(create: String) -> String {
  create <> " howdy_cache_entries (
       key TEXT PRIMARY KEY,
       value TEXT NOT NULL,
       expires_at BIGINT NOT NULL
     );
     CREATE INDEX howdy_cache_entries_expiry ON howdy_cache_entries (expires_at);
     " <> create <> " howdy_cache_entry_tags (
       key TEXT NOT NULL REFERENCES howdy_cache_entries(key) ON DELETE CASCADE,
       tag TEXT NOT NULL,
       version BIGINT NOT NULL,
       PRIMARY KEY (key, tag)
     );
     CREATE INDEX howdy_cache_entry_tags_tag ON howdy_cache_entry_tags (tag);
     CREATE TABLE howdy_cache_tags (
       tag TEXT PRIMARY KEY,
       version BIGINT NOT NULL
     )"
}

/// A store over this Repo, once its schema is checked, with a process
/// deleting expired entries every five minutes. The process stops when the
/// caller exits.
pub fn store(repo: Repo) -> service.Result(Store) {
  use _ <- result.try(migration.check(repo, schema()))
  start_sweeper(fn() { sweep(repo) }, 300_000)
  Ok(
    cache.store(
      named: "database",
      read: fn(key) { read(repo, key) },
      versions: fn(tags) { versions(repo, tags) },
      write: fn(key, value, expires_at, versions) {
        write(repo, key, value, expires_at, versions)
      },
      delete: fn(key) { delete(repo, key) },
      invalidate: fn(tags) { invalidate(repo, tags) },
      clear: fn() { clear(repo) },
    ),
  )
}

/// Delete expired entries, a thousand at a time, and return how many went.
pub fn sweep(repo: Repo) -> service.Result(Int) {
  sweep_from(repo, now(), 0)
}

fn sweep_from(repo: Repo, now: Int, removed: Int) -> service.Result(Int) {
  use deleted <- result.try({
    use conn <- database.connect(repo)
    database.query(
      conn,
      "DELETE FROM howdy_cache_entries WHERE key IN
         (SELECT key FROM howdy_cache_entries WHERE expires_at <= $1 LIMIT 1000)
       RETURNING key",
      [sql.int(now)],
      decode.field(0, decode.string, decode.success),
    )
  })
  let removed = removed + list.length(deleted)
  case list.length(deleted) < 1000 {
    True -> Ok(removed)
    False -> sweep_from(repo, now, removed)
  }
}

fn read(
  repo: Repo,
  key: String,
) -> service.Result(option.Option(cache.Stored)) {
  use conn <- database.connect(repo)
  use rows <- result.map(
    database.query(
      conn,
      "SELECT e.value, e.expires_at,
       CASE WHEN EXISTS (
         SELECT 1 FROM howdy_cache_entry_tags et
         LEFT JOIN howdy_cache_tags t ON t.tag = et.tag
         WHERE et.key = e.key AND COALESCE(t.version, 0) <> et.version
       ) THEN 0 ELSE 1 END
     FROM howdy_cache_entries e WHERE e.key = $1",
      [sql.string(key)],
      {
        use value <- decode.field(0, decode.string)
        use expires_at <- decode.field(1, decode.int)
        use current <- decode.field(2, decode.int)
        decode.success(Stored(value:, expires_at:, current: current == 1))
      },
    ),
  )
  case rows {
    [row, ..] -> Some(row)
    [] -> None
  }
}

fn versions(
  repo: Repo,
  tags: List(String),
) -> service.Result(List(#(String, Int))) {
  use conn <- database.connect(repo)
  // Gloo's SQLite adapter binds at most nine placeholders.
  use found <- result.map(
    list.sized_chunk(tags, 9)
    |> list.try_map(fn(chunk) {
      let placeholders =
        list.index_map(chunk, fn(_, index) { "$" <> int.to_string(index + 1) })
      database.query(
        conn,
        "SELECT tag, version FROM howdy_cache_tags WHERE tag IN ("
          <> string.join(placeholders, ", ")
          <> ")",
        list.map(chunk, sql.string),
        {
          use tag <- decode.field(0, decode.string)
          use version <- decode.field(1, decode.int)
          decode.success(#(tag, version))
        },
      )
    }),
  )
  let found = list.flatten(found)
  list.map(tags, fn(tag) { #(tag, result.unwrap(list.key_find(found, tag), 0)) })
}

fn write(
  repo: Repo,
  key: String,
  value: String,
  expires_at: Int,
  versions: List(#(String, Int)),
) -> service.Result(Nil) {
  use tx <- database.write_transaction(repo, touching: "howdy_cache_entries")
  use Nil <- result.try(lock_key(tx, key))
  use stored <- result.try(
    database.query(
      tx,
      "SELECT tag, version FROM howdy_cache_entry_tags WHERE key = $1",
      [sql.string(key)],
      {
        use tag <- decode.field(0, decode.string)
        use version <- decode.field(1, decode.int)
        decode.success(#(tag, version))
      },
    ),
  )
  // Computed before an invalidation the stored entry already reflects:
  // keep the newer one.
  let newer =
    list.any(stored, fn(pair) {
      case list.key_find(versions, pair.0) {
        Ok(mine) -> pair.1 > mine
        Error(Nil) -> False
      }
    })
  use <- bool.guard(newer, Ok(Nil))
  use Nil <- result.try(
    database.execute(
      tx,
      "INSERT INTO howdy_cache_entries (key, value, expires_at) VALUES ($1, $2, $3)
     ON CONFLICT (key) DO UPDATE
     SET value = excluded.value, expires_at = excluded.expires_at",
      [sql.string(key), sql.string(value), sql.int(expires_at)],
    ),
  )
  use Nil <- result.try(
    database.execute(tx, "DELETE FROM howdy_cache_entry_tags WHERE key = $1", [
      sql.string(key),
    ]),
  )
  list.try_each(versions, fn(pair) {
    database.execute(
      tx,
      "INSERT INTO howdy_cache_entry_tags (key, tag, version) VALUES ($1, $2, $3)",
      [sql.string(key), sql.string(pair.0), sql.int(pair.1)],
    )
  })
}

/// Serialize writers of one key until the transaction ends, even before
/// the key has a row to lock. SQLite's write transaction already holds the
/// whole database.
fn lock_key(tx: Repo, key: String) -> service.Result(Nil) {
  case database.backend(tx) {
    Ok(database.Postgres) ->
      database.query(
        tx,
        "SELECT 1 FROM (SELECT pg_advisory_xact_lock(hashtext('howdy_cache'), hashtext($1))) l",
        [sql.string(key)],
        decode.success(Nil),
      )
      |> result.replace(Nil)
    _ -> Ok(Nil)
  }
}

fn delete(repo: Repo, key: String) -> service.Result(Nil) {
  use conn <- database.connect(repo)
  database.execute(conn, "DELETE FROM howdy_cache_entries WHERE key = $1", [
    sql.string(key),
  ])
}

/// The versions go up in one transaction that touches nothing but the
/// tags' rows, in sorted order, so two invalidations sharing tags lock them
/// in the same order and cannot deadlock. The entries carrying the tags
/// are stale from that commit on; deleting them afterwards only reclaims
/// the space, so a failure there is ignored. Only entries written with an
/// older version are chosen. On PostgreSQL an entry stored again between
/// that choice and the delete can still go, which costs one recompute and
/// never serves stale data.
fn invalidate(repo: Repo, tags: List(String)) -> service.Result(Nil) {
  use bumped <- result.try({
    use tx <- database.transaction(repo)
    list.try_map(list.sort(tags, string.compare), fn(tag) {
      database.one(
        tx,
        "INSERT INTO howdy_cache_tags (tag, version) VALUES ($1, 1)
         ON CONFLICT (tag) DO UPDATE SET version = howdy_cache_tags.version + 1
         RETURNING version",
        [sql.string(tag)],
        decode.field(0, decode.int, decode.success),
        or: service.Internal("the tag upsert returned no row"),
      )
      |> result.map(fn(version) { #(tag, version) })
    })
  })
  list.each(bumped, fn(pair) {
    let _ = {
      use conn <- database.connect(repo)
      database.execute(
        conn,
        "DELETE FROM howdy_cache_entries WHERE key IN
           (SELECT key FROM howdy_cache_entry_tags WHERE tag = $1 AND version < $2)",
        [sql.string(pair.0), sql.int(pair.1)],
      )
    }
    Nil
  })
  Ok(Nil)
}

fn clear(repo: Repo) -> service.Result(Nil) {
  use conn <- database.connect(repo)
  database.execute(conn, "DELETE FROM howdy_cache_entries", [])
}

@external(erlang, "howdy_cache_ffi", "system_ms")
fn now() -> Int

@external(erlang, "howdy_cache_ffi", "start_sweeper")
fn start_sweeper(sweep: fn() -> service.Result(Int), every_ms: Int) -> Nil
