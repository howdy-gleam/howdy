import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit
import gloo/adapter/sqlite
import gloo/repo.{type Repo}
import howdy/cache
import howdy/cache/database as cache_database
import howdy/cache/memory
import howdy/codec
import howdy/database
import howdy/database/postgres
import howdy/migration
import howdy/service

pub fn main() {
  gleeunit.main()
}

type Counter

@external(erlang, "howdy_cache_test_ffi", "counter")
fn counter() -> Counter

@external(erlang, "howdy_cache_test_ffi", "bump")
fn bump(counter: Counter) -> Nil

@external(erlang, "howdy_cache_test_ffi", "count")
fn count(counter: Counter) -> Int

@external(erlang, "howdy_cache_test_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

/// SQLite in memory, or a PostgreSQL database emptied of the package's
/// tables when `HOWDY_CACHE_TEST_POSTGRES_URL` is set.
fn open() -> Repo {
  case getenv("HOWDY_CACHE_TEST_POSTGRES_URL") {
    Error(Nil) -> {
      let assert Ok(db) = sqlite.start(sqlite.memory())
      let assert Ok(Nil) = database.sqlite_defaults(db)
      db
    }
    Ok(url) -> {
      let assert Ok(db) = postgres.from_url(url) |> result.try(postgres.start)
      let assert Ok(Nil) =
        database.exec(
          db,
          "DROP TABLE IF EXISTS howdy_cache_entry_tags, howdy_cache_entries,
            howdy_cache_tags;
          CREATE TABLE IF NOT EXISTS howdy_migrations (package TEXT NOT NULL, version BIGINT NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(package, version));
          CREATE TABLE IF NOT EXISTS howdy_migration_schemas (package TEXT PRIMARY KEY NOT NULL, fingerprint TEXT NOT NULL);
          DELETE FROM howdy_migrations WHERE package = 'howdy_cache';
          DELETE FROM howdy_migration_schemas WHERE package = 'howdy_cache'",
        )
      db
    }
  }
}

fn migrated() -> Repo {
  let db = open()
  let assert Ok(Nil) = migration.run(db, [cache_database.schema()])
  db
}

/// Run against the memory store, then the database store. `run` also gets
/// a Repo of its own for transactions: the cache defers work by process,
/// whatever the Repo, and a SQLite store's single connection would block
/// other processes for as long as a test transaction held it.
fn each_store(run: fn(cache.Store, Repo) -> a) -> Nil {
  let assert Ok(transactions) = sqlite.start(sqlite.memory())
  let db = migrated()
  let _ = run(memory.new(max_entries: 1000), transactions)
  let assert Ok(store) = cache_database.store(db)
  let _ = run(store, transactions)
  let assert Ok(_) = repo.close(db)
  let assert Ok(_) = repo.close(transactions)
  Nil
}

@external(erlang, "howdy_cache_test_ffi", "add")
fn add(counter: Counter, amount: Int) -> Nil

/// A cache with a clock the test moves by hand.
fn with_cache(run: fn(cache.Cache, Counter, Repo) -> a) -> Nil {
  use store, db <- each_store
  let clock = counter()
  add(clock, 1_800_000_000_000)
  run(cache.new(store) |> cache.with_clock(fn() { count(clock) }), clock, db)
}

fn advance(clock: Counter, ms: Int) -> Nil {
  add(clock, ms)
}

fn range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..range(from + 1, to)]
  }
}

fn counted(calls: Counter, value: a) -> fn() -> service.Result(a) {
  fn() {
    bump(calls)
    Ok(value)
  }
}

pub fn fetch_computes_once_test() {
  use cache, _clock, _db <- with_cache
  let calls = counter()
  let entry = cache.entry("answer", ttl: 60)
  assert cache.fetch(cache, entry, codec.int(), counted(calls, 42)) == Ok(42)
  assert cache.fetch(cache, entry, codec.int(), counted(calls, 43)) == Ok(42)
  assert count(calls) == 1
  assert cache.get(cache, "answer", codec.int()) == Some(42)
  assert cache.get(cache, "missing", codec.int()) == None
}

pub fn errors_are_not_stored_test() {
  use cache, _clock, _db <- with_cache
  let entry = cache.entry("flaky", ttl: 60)
  assert cache.fetch(cache, entry, codec.int(), fn() {
      Error(service.Internal("db down"))
    })
    == Error(service.Internal("db down"))
  assert cache.get(cache, "flaky", codec.int()) == None
  assert cache.fetch(cache, entry, codec.int(), fn() { Ok(1) }) == Ok(1)
}

pub fn entries_expire_test() {
  use cache, clock, _db <- with_cache
  let calls = counter()
  let entry = cache.entry("short", ttl: 10)
  let _ = cache.fetch(cache, entry, codec.int(), counted(calls, 1))
  advance(clock, 9999)
  assert cache.get(cache, "short", codec.int()) == Some(1)
  advance(clock, 1)
  assert cache.get(cache, "short", codec.int()) == None
  assert cache.fetch(cache, entry, codec.int(), counted(calls, 2)) == Ok(2)
  assert count(calls) == 2

  // Nothing is stored without a positive time to live.
  let never = cache.entry("never", ttl: 0)
  let _ = cache.fetch(cache, never, codec.int(), counted(calls, 3))
  let _ = cache.fetch(cache, never, codec.int(), counted(calls, 3))
  assert count(calls) == 4
}

pub fn invalidating_a_tag_drops_its_entries_test() {
  use cache, _clock, _db <- with_cache
  let note = cache.entry("note:1", ttl: 60) |> cache.tags(["notes", "note:1"])
  let other = cache.entry("note:2", ttl: 60) |> cache.tags(["notes", "note:2"])
  let untagged = cache.entry("count", ttl: 60)
  let _ = cache.fetch(cache, note, codec.string(), fn() { Ok("one") })
  let _ = cache.fetch(cache, other, codec.string(), fn() { Ok("two") })
  let _ = cache.fetch(cache, untagged, codec.int(), fn() { Ok(2) })

  assert cache.invalidate(cache, ["note:1"]) == Ok(Nil)
  assert cache.get(cache, "note:1", codec.string()) == None
  assert cache.get(cache, "note:2", codec.string()) == Some("two")

  assert cache.invalidate(cache, ["notes"]) == Ok(Nil)
  assert cache.get(cache, "note:2", codec.string()) == None
  assert cache.get(cache, "count", codec.int()) == Some(2)

  // Stored again after an invalidation, the entry is current again.
  assert cache.fetch(cache, note, codec.string(), fn() { Ok("one again") })
    == Ok("one again")
  assert cache.get(cache, "note:1", codec.string()) == Some("one again")
  assert cache.invalidate(cache, []) == Ok(Nil)
}

pub fn a_change_during_compute_is_not_stored_as_current_test() {
  use cache, _clock, _db <- with_cache
  let entry = cache.entry("report", ttl: 60) |> cache.tags(["orders"])
  // The data changes, and is invalidated, after the old data was read.
  let result =
    cache.fetch(cache, entry, codec.string(), fn() {
      let old = "old report"
      let assert Ok(Nil) = cache.invalidate(cache, ["orders"])
      Ok(old)
    })
  assert result == Ok("old report")
  assert cache.get(cache, "report", codec.string()) == None
  assert cache.fetch(cache, entry, codec.string(), fn() { Ok("new report") })
    == Ok("new report")
}

pub fn a_value_that_no_longer_decodes_is_replaced_test() {
  use cache, _clock, _db <- with_cache
  let entry = cache.entry("shape", ttl: 60)
  let assert Ok(Nil) = cache.put(cache, entry, codec.string(), "text")
  assert cache.get(cache, "shape", codec.int()) == None
  assert cache.fetch(cache, entry, codec.int(), fn() { Ok(7) }) == Ok(7)
  assert cache.get(cache, "shape", codec.int()) == Some(7)
}

pub fn put_delete_and_clear_test() {
  use cache, _clock, _db <- with_cache
  let assert Ok(Nil) =
    cache.put(cache, cache.entry("a", ttl: 60), codec.int(), 1)
  let assert Ok(Nil) =
    cache.put(cache, cache.entry("b", ttl: 60), codec.int(), 2)
  let assert Ok(Nil) =
    cache.put(cache, cache.entry("a", ttl: 60), codec.int(), 3)
  assert cache.get(cache, "a", codec.int()) == Some(3)
  assert cache.delete(cache, "a") == Ok(Nil)
  assert cache.delete(cache, "a") == Ok(Nil)
  assert cache.get(cache, "a", codec.int()) == None
  assert cache.clear(cache) == Ok(Nil)
  assert cache.get(cache, "b", codec.int()) == None

  // `put` with no time to live removes what was there.
  let assert Ok(Nil) =
    cache.put(cache, cache.entry("c", ttl: 60), codec.int(), 1)
  let assert Ok(Nil) =
    cache.put(cache, cache.entry("c", ttl: 0), codec.int(), 2)
  assert cache.get(cache, "c", codec.int()) == None
}

pub fn put_tags_take_current_versions_test() {
  use cache, _clock, _db <- with_cache
  let assert Ok(Nil) = cache.invalidate(cache, ["t"])
  let entry = cache.entry("p", ttl: 60) |> cache.tags(["t"])
  let assert Ok(Nil) = cache.put(cache, entry, codec.int(), 1)
  assert cache.get(cache, "p", codec.int()) == Some(1)
  let assert Ok(Nil) = cache.invalidate(cache, ["t"])
  assert cache.get(cache, "p", codec.int()) == None
}

pub fn namespaces_keep_caches_apart_test() {
  use store, _db <- each_store
  let one = cache.new(store) |> cache.namespace("one")
  let two = cache.new(store) |> cache.namespace("two")
  let entry = cache.entry("k", ttl: 60) |> cache.tags(["t"])
  let assert Ok(Nil) = cache.put(one, entry, codec.int(), 1)
  let assert Ok(Nil) = cache.put(two, entry, codec.int(), 2)
  assert cache.get(one, "k", codec.int()) == Some(1)
  assert cache.get(two, "k", codec.int()) == Some(2)
  let assert Ok(Nil) = cache.invalidate(one, ["t"])
  assert cache.get(one, "k", codec.int()) == None
  assert cache.get(two, "k", codec.int()) == Some(2)
}

pub fn long_keys_and_tags_are_hashed_test() {
  use cache, _clock, _db <- with_cache
  let long = string.repeat("k", 1000)
  let longer = long <> "!"
  let tag = string.repeat("t", 1000)
  let assert Ok(Nil) =
    cache.put(
      cache,
      cache.entry(long, ttl: 60) |> cache.tags([tag]),
      codec.int(),
      1,
    )
  let assert Ok(Nil) =
    cache.put(cache, cache.entry(longer, ttl: 60), codec.int(), 2)
  assert cache.get(cache, long, codec.int()) == Some(1)
  assert cache.get(cache, longer, codec.int()) == Some(2)
  let assert Ok(Nil) = cache.invalidate(cache, [tag])
  assert cache.get(cache, long, codec.int()) == None
}

pub fn large_values_are_returned_but_not_stored_test() {
  use cache, _clock, _db <- with_cache
  let cache = cache.max_value_bytes(cache, 10)
  let entry = cache.entry("big", ttl: 60)
  let big = string.repeat("x", 20)
  assert cache.fetch(cache, entry, codec.string(), fn() { Ok(big) }) == Ok(big)
  assert cache.get(cache, "big", codec.string()) == None
  assert cache.fetch(cache, entry, codec.string(), fn() { Ok("small") })
    == Ok("small")
  assert cache.get(cache, "big", codec.string()) == Some("small")
}

pub fn concurrent_misses_compute_once_test() {
  use cache, _clock, _db <- with_cache
  let calls = counter()
  let entry = cache.entry("slow", ttl: 60)
  let done = process.new_subject()
  list.each(range(1, 10), fn(_) {
    process.spawn(fn() {
      let result =
        cache.fetch(cache, entry, codec.int(), fn() {
          bump(calls)
          process.sleep(50)
          Ok(5)
        })
      process.send(done, result)
    })
  })
  list.each(range(1, 10), fn(_) {
    assert process.receive(done, 5000) == Ok(Ok(5))
  })
  assert count(calls) == 1
}

/// Start `count` fetches of one key at once and collect their results.
fn concurrently(
  count: Int,
  fetch: fn() -> service.Result(Int),
) -> List(Result(service.Result(Int), Nil)) {
  let done = process.new_subject()
  list.each(range(1, count), fn(_) {
    process.spawn_unlinked(fn() { process.send(done, fetch()) })
  })
  list.map(range(1, count), fn(_) { process.receive(done, 5000) })
}

pub fn concurrent_misses_share_an_error_test() {
  use cache, _clock, _db <- with_cache
  let calls = counter()
  let entry = cache.entry("failing", ttl: 60)
  let results =
    concurrently(10, fn() {
      cache.fetch(cache, entry, codec.int(), fn() {
        bump(calls)
        process.sleep(50)
        Error(service.Internal("db down"))
      })
    })
  assert list.all(results, fn(r) { r == Ok(Error(service.Internal("db down"))) })
  assert count(calls) == 1
}

pub fn waiters_start_over_when_the_computation_crashes_test() {
  use cache, _clock, _db <- with_cache
  let calls = counter()
  let entry = cache.entry("crashing", ttl: 60)
  let results =
    concurrently(5, fn() {
      cache.fetch(cache, entry, codec.int(), fn() {
        bump(calls)
        process.sleep(50)
        case count(calls) {
          1 -> panic as "the first computation crashes"
          _ -> Ok(9)
        }
      })
    })
  // The crashed caller never answers; everyone else gets the value.
  assert list.count(results, fn(r) { r == Ok(Ok(9)) }) == 4
  assert count(calls) == 2
}

pub fn a_failing_store_still_computes_once_per_key_test() {
  let cache = cache.new(failing_store())
  let calls = counter()
  let entry = cache.entry("k", ttl: 60)
  let results =
    concurrently(10, fn() {
      cache.fetch(cache, entry, codec.int(), fn() {
        bump(calls)
        process.sleep(50)
        Ok(3)
      })
    })
  assert list.all(results, fn(r) { r == Ok(Ok(3)) })
  assert count(calls) == 1
}

pub fn fetch_inside_a_transaction_bypasses_the_cache_test() {
  use cache, _clock, db <- with_cache
  let calls = counter()
  let entry = cache.entry("tx", ttl: 60)
  let _ = cache.fetch(cache, entry, codec.int(), counted(calls, 1))
  let assert Ok(2) =
    database.transaction(db, fn(_tx) {
      assert cache.get(cache, "tx", codec.int()) == None
      cache.fetch(cache, entry, codec.int(), counted(calls, 2))
    })
  assert count(calls) == 2
  // The transaction's value was not stored.
  assert cache.get(cache, "tx", codec.int()) == Some(1)
}

/// What another process sees, while this one may be inside a transaction.
fn seen_elsewhere(cache: cache.Cache, key: String) -> option.Option(Int) {
  let reply = process.new_subject()
  process.spawn(fn() { process.send(reply, cache.get(cache, key, codec.int())) })
  let assert Ok(seen) = process.receive(reply, 5000)
  seen
}

pub fn invalidation_waits_for_the_transaction_test() {
  use cache, _clock, db <- with_cache
  let entry = cache.entry("order", ttl: 60) |> cache.tags(["orders"])
  let assert Ok(Nil) = cache.put(cache, entry, codec.int(), 1)
  let assert Ok(Nil) =
    database.transaction(db, fn(_tx) {
      let assert Ok(Nil) = cache.invalidate(cache, ["orders"])
      let assert Ok(Nil) = cache.delete(cache, "order")
      // Not yet: another request could otherwise cache the old data again
      // before this transaction commits.
      assert seen_elsewhere(cache, "order") == Some(1)
      Ok(Nil)
    })
  assert seen_elsewhere(cache, "order") == None

  // A rolled back transaction still invalidates: it costs a recompute, and
  // the transaction may have changed data outside the database.
  let assert Ok(Nil) = cache.put(cache, entry, codec.int(), 2)
  let assert Error(service.Conflict(_)) =
    database.transaction(db, fn(_tx) {
      let assert Ok(Nil) = cache.invalidate(cache, ["orders"])
      Error(service.Conflict("no"))
    })
  assert seen_elsewhere(cache, "order") == None
}

pub fn put_inside_a_transaction_deletes_instead_test() {
  use cache, _clock, db <- with_cache
  let entry = cache.entry("p", ttl: 60)
  let assert Ok(Nil) = cache.put(cache, entry, codec.int(), 1)
  let assert Ok(Nil) =
    database.transaction(db, fn(_tx) {
      // The value could come from a savepoint that rolls back, so it is
      // never stored; the old one goes once the transaction ends.
      let assert Ok(Nil) = cache.put(cache, entry, codec.int(), 2)
      assert seen_elsewhere(cache, "p") == Some(1)
      Ok(Nil)
    })
  assert cache.get(cache, "p", codec.int()) == None
}

pub fn a_leader_killed_mid_computation_is_replaced_test() {
  use cache, _clock, _db <- with_cache
  let entry = cache.entry("killed", ttl: 60)
  let started = process.new_subject()
  let leader =
    process.spawn_unlinked(fn() {
      cache.fetch(cache, entry, codec.int(), fn() {
        process.send(started, Nil)
        process.sleep(60_000)
        Ok(0)
      })
    })
  let assert Ok(Nil) = process.receive(started, 5000)
  // One request is already waiting for the leader when it is killed.
  let waiting = process.new_subject()
  process.spawn_unlinked(fn() {
    process.send(
      waiting,
      cache.fetch(cache, entry, codec.int(), fn() { Ok(1) }),
    )
  })
  process.sleep(50)
  process.kill(leader)
  assert process.receive(waiting, 5000) == Ok(Ok(1))
  // And later requests are not sent to the dead leader either.
  let assert Ok(Nil) = cache.delete(cache, "killed")
  assert concurrently(1, fn() {
      cache.fetch(cache, entry, codec.int(), fn() { Ok(2) })
    })
    == [Ok(Ok(2))]
}

pub fn requests_after_an_invalidation_do_not_wait_for_older_values_test() {
  use cache, _clock, _db <- with_cache
  let entry = cache.entry("note", ttl: 60) |> cache.tags(["note"])
  let reading = process.new_subject()
  let done = process.new_subject()
  process.spawn_unlinked(fn() {
    let result =
      cache.fetch(cache, entry, codec.string(), fn() {
        let release = process.new_subject()
        process.send(reading, release)
        let _ = process.receive(release, 5000)
        Ok("old")
      })
    process.send(done, result)
  })
  let assert Ok(release) = process.receive(reading, 5000)
  // The note changes while the old version is being computed. A request
  // after that computes the new version rather than wait for the old one.
  let assert Ok(Nil) = cache.invalidate(cache, ["note"])
  let fresh = cache.fetch(cache, entry, codec.string(), fn() { Ok("new") })
  assert fresh == Ok("new")
  process.send(release, Nil)
  assert process.receive(done, 5000) == Ok(Ok("old"))
  assert cache.get(cache, "note", codec.string()) == Some("new")
}

pub fn entries_built_from_each_other_do_not_deadlock_test() {
  use cache, _clock, _db <- with_cache
  let a = cache.entry("a", ttl: 60)
  let b = cache.entry("b", ttl: 60)
  let leading = process.new_subject()
  let build = fn(this, other) {
    fn() {
      cache.fetch(cache, this, codec.int(), fn() {
        // Each leader waits until the other leads too, then needs its key.
        let go = process.new_subject()
        process.send(leading, go)
        let _ = process.receive(go, 5000)
        cache.fetch(cache, other, codec.int(), fn() { Ok(1) })
      })
    }
  }
  let done = process.new_subject()
  process.spawn_unlinked(fn() { process.send(done, build(a, b)()) })
  process.spawn_unlinked(fn() { process.send(done, build(b, a)()) })
  let assert Ok(go_a) = process.receive(leading, 5000)
  let assert Ok(go_b) = process.receive(leading, 5000)
  process.send(go_a, Nil)
  process.send(go_b, Nil)
  assert process.receive(done, 5000) == Ok(Ok(1))
  assert process.receive(done, 5000) == Ok(Ok(1))
}

fn failing_store() -> cache.Store {
  let fail = Error(service.Internal("store down"))
  cache.store(
    named: "failing",
    read: fn(_) { fail |> result.map(fn(_) { None }) },
    versions: fn(_) { fail |> result.map(fn(_) { [] }) },
    write: fn(_, _, _, _) { fail |> result.map(fn(_) { Nil }) },
    delete: fn(_) { fail |> result.map(fn(_) { Nil }) },
    invalidate: fn(_) { fail |> result.map(fn(_) { Nil }) },
    clear: fn() { fail |> result.map(fn(_) { Nil }) },
  )
}

pub fn a_failing_store_falls_back_to_computing_test() {
  let cache = cache.new(failing_store())
  let entry = cache.entry("k", ttl: 60) |> cache.tags(["t"])
  assert cache.fetch(cache, entry, codec.int(), fn() { Ok(1) }) == Ok(1)
  assert cache.get(cache, "k", codec.int()) == None
  assert cache.invalidate(cache, ["t"]) == Error(service.Internal("store down"))
  assert cache.delete(cache, "k") == Error(service.Internal("store down"))
  assert cache.store_name(failing_store()) == "failing"
}

pub fn a_full_memory_store_makes_room_test() {
  let cache = cache.new(memory.new(max_entries: 10))
  list.each(range(1, 30), fn(i) {
    let assert Ok(Nil) =
      cache.put(cache, cache.entry(int.to_string(i), ttl: i), codec.int(), i)
  })
  let kept =
    list.filter(range(1, 30), fn(i) {
      cache.get(cache, int.to_string(i), codec.int()) == Some(i)
    })
  assert list.length(kept) <= 10
  // The newest write is always kept, and the oldest entries go first.
  assert list.contains(kept, 30)
  assert !list.contains(kept, 1)
}

pub fn the_database_sweep_removes_expired_entries_test() {
  let db = migrated()
  let assert Ok(store) = cache_database.store(db)
  let past = cache.new(store) |> cache.with_clock(fn() { 1000 })
  let present = cache.new(store)
  let assert Ok(Nil) =
    cache.put(
      past,
      cache.entry("old", ttl: 1) |> cache.tags(["t"]),
      codec.int(),
      1,
    )
  let assert Ok(Nil) =
    cache.put(present, cache.entry("new", ttl: 60), codec.int(), 2)
  assert cache_database.sweep(db) == Ok(1)
  assert cache_database.sweep(db) == Ok(0)
  assert cache.get(present, "new", codec.int()) == Some(2)
  let assert Ok(_) = repo.close(db)
  Nil
}

pub fn deferred_work_runs_on_the_stores_own_repo_test() {
  // The usual setup: the app's transactions and the cache share one Repo.
  let db = migrated()
  let assert Ok(store) = cache_database.store(db)
  let cache = cache.new(store)
  let entry = cache.entry("shared", ttl: 60) |> cache.tags(["t"])
  let assert Ok(Nil) = cache.put(cache, entry, codec.int(), 1)
  let assert Ok(Nil) =
    database.transaction(db, fn(tx) {
      let assert Ok(Nil) = database.execute(tx, "SELECT 1", [])
      let assert Ok(Nil) = cache.invalidate(cache, ["t"])
      cache.put(cache, cache.entry("other", ttl: 60), codec.int(), 2)
    })
  assert cache.get(cache, "shared", codec.int()) == None
  assert cache.get(cache, "other", codec.int()) == None
  let assert Ok(_) = repo.close(db)
  Nil
}

pub fn waiters_decode_with_their_own_codec_test() {
  use cache, _clock, _db <- with_cache
  let entry = cache.entry("shape", ttl: 60)
  let started = process.new_subject()
  let done = process.new_subject()
  process.spawn_unlinked(fn() {
    let result =
      cache.fetch(cache, entry, codec.int(), fn() {
        let release = process.new_subject()
        process.send(started, release)
        let _ = process.receive(release, 5000)
        Ok(7)
      })
    process.send(done, result)
  })
  let assert Ok(release) = process.receive(started, 5000)
  // A request reading the same key as a string joins the int's flight, and
  // must not be handed an int.
  let reading = process.new_subject()
  process.spawn_unlinked(fn() {
    process.send(
      reading,
      cache.fetch(cache, entry, codec.string(), fn() { Ok("seven") }),
    )
  })
  process.sleep(50)
  process.send(release, Nil)
  assert process.receive(done, 5000) == Ok(Ok(7))
  assert process.receive(reading, 5000) == Ok(Ok("seven"))
}

pub fn overlapping_invalidations_never_fail_test() {
  use cache, _clock, _db <- with_cache
  let tag_sets = [["a", "b"], ["b"], ["b", "c"], ["c", "a"], ["a", "b", "c"]]
  let fill = fn() {
    list.each(range(1, 10), fn(i) {
      let entry =
        cache.entry("entry:" <> int.to_string(i), ttl: 60)
        |> cache.tags(["a", "b", "c"])
      let _ = cache.fetch(cache, entry, codec.int(), fn() { Ok(i) })
      Nil
    })
  }
  fill()
  let done = process.new_subject()
  list.each(range(1, 20), fn(n) {
    process.spawn_unlinked(fn() {
      let outcomes =
        list.map(range(1, 10), fn(round) {
          let assert Ok(tags) =
            list.drop(tag_sets, { n + round } % 5) |> list.first
          case round % 3 {
            0 -> {
              fill()
              Ok(Nil)
            }
            _ -> cache.invalidate(cache, tags)
          }
        })
      process.send(done, outcomes)
    })
  })
  list.each(range(1, 20), fn(_) {
    let assert Ok(outcomes) = process.receive(done, 30_000)
    assert list.all(outcomes, fn(outcome) { outcome == Ok(Nil) })
  })
}

pub fn concurrent_writers_stay_near_the_limit_test() {
  let cache = cache.new(memory.new(max_entries: 10))
  let done = process.new_subject()
  list.each(range(1, 20), fn(writer) {
    process.spawn_unlinked(fn() {
      list.each(range(1, 200), fn(i) {
        let key = int.to_string(writer) <> ":" <> int.to_string(i)
        let assert Ok(Nil) =
          cache.put(cache, cache.entry(key, ttl: 60), codec.int(), i)
      })
      process.send(done, Nil)
    })
  })
  list.each(range(1, 20), fn(_) {
    let assert Ok(Nil) = process.receive(done, 30_000)
  })
  let kept =
    list.flat_map(range(1, 20), fn(writer) {
      list.filter(range(1, 200), fn(i) {
        let key = int.to_string(writer) <> ":" <> int.to_string(i)
        cache.get(cache, key, codec.int()) == Some(i)
      })
    })
    |> list.length
  // At most one over the limit per writer, never thousands.
  assert kept <= 10 + 20
}
