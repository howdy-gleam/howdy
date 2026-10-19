# howdy_cache

An application cache for [howdy](https://github.com/mikeyjones/howdy/blob/v1.0.0/README.md) apps: keep the result of
expensive work for a while, and throw it away when the data it came from
changes. Entries live in this node's memory or in the app's database,
PostgreSQL or SQLite, or anywhere a store can reach.

Add it to `[dependencies]` in `gleam.toml`, from the same release as your
app's other Howdy packages:

```toml
howdy_cache = { git = "https://github.com/mikeyjones/howdy.git", ref = "v1.0.0", path = "cache" }
```

## Fetch or compute

```gleam
import howdy/cache
import howdy/cache/memory
import howdy/codec

// In main, once:
let app_cache = cache.new(memory.new(max_entries: 50_000))

// Anywhere:
pub fn find(id: Int) -> service.Result(Note) {
  let entry =
    cache.entry("note:" <> int.to_string(id), ttl: 300)
    |> cache.tags(["note:" <> int.to_string(id)])
  use <- cache.fetch(app_cache, entry, note_codec())
  notes.find(db, id)
}

// When the note changes, inside its transaction or not:
cache.invalidate(app_cache, ["note:" <> int.to_string(id)])
```

- `fetch` stores `Ok` results only, so a failed query is retried.
- Values are JSON, through a `howdy/codec` codec, in every store. One that
  no longer decodes after a deploy counts as missing.
- Tags have versions, read before the value is computed, so a value built
  from data that changed meanwhile is never served.
- Inside a `howdy/database` transaction, `invalidate` and `delete` wait for
  it to end, `put` deletes the key then instead of storing, and `fetch`
  skips the cache.
- A store that fails makes `fetch` compute instead, with a warning.
- Concurrent misses on one node compute once and share the result or
  error.

## Stores

- `howdy/cache/memory`: ETS on this node, bounded by `max_entries`. Each
  node has its own entries and invalidations.
- `howdy/cache/database`: shared by every node using the database, one
  query per read, `UNLOGGED` tables on PostgreSQL. Run
  `cache_database.schema()` with `howdy/migration` first.
- Your own: `cache.store` from seven functions.

See the [caching docs](https://github.com/mikeyjones/howdy/blob/v1.0.0/docs/cache/overview.djot) for the details, and
`howdy/conditional` in the core package for answering `304 Not Modified`.

## Development

The tests run against the memory store and a SQLite database. Set
`HOWDY_CACHE_TEST_POSTGRES_URL` to run the database store against
PostgreSQL too; the tests drop and recreate the package's tables there.

```sh
HOWDY_CACHE_TEST_POSTGRES_URL=postgres://howdy_cache_test@localhost/postgres gleam test
```
