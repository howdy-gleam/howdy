//// An application cache: keep the result of expensive work for a while,
//// and throw it away when the data it came from changes.
////
//// ```gleam
//// import howdy/cache
//// import howdy/cache/memory
////
//// // In main, once:
//// let notes_cache = cache.new(memory.new(max_entries: 50_000))
////
//// // Anywhere:
//// pub fn find(id: Int) -> service.Result(Note) {
////   let entry =
////     cache.entry("note:" <> int.to_string(id), ttl: 300)
////     |> cache.tags(["notes", "note:" <> int.to_string(id)])
////   use <- cache.fetch(notes_cache, entry, note.codec())
////   notes.find(repo, id)
//// }
////
//// // When a note changes:
//// cache.invalidate(notes_cache, ["note:" <> int.to_string(id)])
//// ```
////
//// `fetch` returns the stored value when there is one, and otherwise runs
//// the function, stores an `Ok` result and returns it. Errors are never
//// stored, so a failed database read is tried again next time.
////
//// Values are kept as JSON through a `howdy/codec` codec, in every store,
//// so a codec that does not round-trip fails in development the same way
//// it would in production. A stored value that no longer decodes, say
//// because a deploy changed its type, counts as missing and is replaced.
////
//// ## Invalidation
////
//// Give each entry the tags of the data it was built from, then call
//// `invalidate` with a tag when that data changes: every entry carrying
//// the tag is treated as missing from then on. Tags have version numbers.
//// `fetch` reads its tags' versions before it computes, and stores them
//// with the value; a value is only served while every one of its tags
//// still has the version it was stored with. A slow computation that read
//// the data before a change therefore cannot store an old value as
//// current after the change was invalidated.
////
//// Inside a `howdy/database` transaction, `invalidate` and `delete` wait
//// until the outermost transaction has ended, so nobody can cache the old
//// data again between the invalidation and the commit. `put` deletes the
//// key then instead of storing, since its value might roll back. `fetch`
//// inside a transaction neither reads nor writes the cache: it would see
//// the old value after the transaction's own writes, or store data that
//// might roll back.
////
//// ## Failures
////
//// The cache never takes the application down with it. If the store
//// fails, `fetch` logs a warning and computes the value as if the cache
//// were empty. `invalidate`, `delete`, `put` and `clear` return the error,
//// since a failed invalidation can leave stale data behind.
////
//// ## Many requests at once
////
//// When several requests on one node miss the same key together, one
//// computes and the rest wait for its result, or its error, instead of all
//// running the same query. Each node computes separately. A computation
//// that is itself filling an entry never waits for another, so two
//// entries built from each other cannot wait on each other forever. One
//// that hands work to another process and waits for it still can, if that
//// process fetches the entry being filled.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import howdy/codec.{type Codec}
import howdy/database
import howdy/service
import howdy/trace
import logging

// -- Stores --------------------------------------------------------------------

/// Where entries and tag versions are kept. `howdy/cache/memory` and
/// `howdy/cache/database` provide stores; build your own with `store`.
pub opaque type Store {
  Store(
    name: String,
    read: fn(String) -> service.Result(Option(Stored)),
    versions: fn(List(String)) -> service.Result(List(#(String, Int))),
    write: fn(String, String, Int, List(#(String, Int))) -> service.Result(Nil),
    delete: fn(String) -> service.Result(Nil),
    invalidate: fn(List(String)) -> service.Result(Nil),
    clear: fn() -> service.Result(Nil),
  )
}

/// An entry as a store returns it. `expires_at` is Unix time in
/// milliseconds. `current` is whether every tag the entry was written with
/// still has the version it was written with.
pub type Stored {
  Stored(value: String, expires_at: Int, current: Bool)
}

/// A store from its operations. Keys and tags arrive already namespaced
/// and at most 250 bytes long; values are JSON text.
///
/// - `read(key)`: the entry under `key`, expired or not, or `None`.
/// - `versions(tags)`: the current version of each tag, `0` for a tag that
///   was never invalidated.
/// - `write(key, value, expires_at, versions)`: replace the entry under
///   `key`, remembering the tag versions it was computed with, unless the
///   stored entry was written with a newer version of a tag both share.
///   Such a value was computed before an invalidation the stored one
///   already reflects. A store that replaces it anyway is still correct,
///   since the value is never served, but loses the newer entry.
/// - `delete(key)`: remove the entry under `key`, if there is one.
/// - `invalidate(tags)`: add one to each tag's version, atomically per tag.
///   The store may also remove the entries carrying them.
/// - `clear()`: remove every entry. Tag versions must be kept, or an
///   invalidation could be undone.
///
/// Work deferred to the end of a transaction calls these while
/// `howdy/database` still counts the transaction as open. A store on the
/// app's database should use `howdy/database` functions, which work then,
/// rather than open a pool transaction of its own.
pub fn store(
  named name: String,
  read read: fn(String) -> service.Result(Option(Stored)),
  versions versions: fn(List(String)) -> service.Result(List(#(String, Int))),
  write write: fn(String, String, Int, List(#(String, Int))) ->
    service.Result(Nil),
  delete delete: fn(String) -> service.Result(Nil),
  invalidate invalidate: fn(List(String)) -> service.Result(Nil),
  clear clear: fn() -> service.Result(Nil),
) -> Store {
  Store(name:, read:, versions:, write:, delete:, invalidate:, clear:)
}

/// The name the store was built with, such as `"memory"`.
pub fn store_name(store: Store) -> String {
  store.name
}

// -- Caches --------------------------------------------------------------------

/// A cache over a store. Build one at startup with `new` and share it.
pub opaque type Cache {
  Cache(
    store: Store,
    flights: Flights,
    namespace: String,
    max_value_bytes: Int,
    clock: fn() -> Int,
  )
}

/// Values larger than this, in bytes of JSON, are returned but not stored,
/// unless `max_value_bytes` says otherwise: 1 MiB.
pub const default_max_value_bytes = 1_048_576

/// A cache over `store`. Its single-flight table belongs to the calling
/// process, like a memory store's tables, so create it in `main`.
pub fn new(store: Store) -> Cache {
  database.around_transactions("howdy_cache", in_transaction)
  Cache(
    store:,
    flights: new_flights(),
    namespace: "",
    max_value_bytes: default_max_value_bytes,
    clock: system_ms,
  )
}

/// Keep this cache's keys and tags apart from other caches sharing the
/// store. Changing the namespace, say from `"v1"` to `"v2"`, also starts
/// the cache afresh, without deleting anything.
pub fn namespace(cache: Cache, namespace: String) -> Cache {
  Cache(..cache, namespace: namespace <> ":")
}

/// Return but do not store values whose JSON is larger than `bytes`.
pub fn max_value_bytes(cache: Cache, bytes: Int) -> Cache {
  Cache(..cache, max_value_bytes: bytes)
}

/// Read the time, in Unix milliseconds, from `clock` instead of the system
/// clock, so tests can expire entries without sleeping. Stores that sweep
/// expired entries in the background still use the system clock for that.
pub fn with_clock(cache: Cache, clock: fn() -> Int) -> Cache {
  Cache(..cache, clock:)
}

// -- Entries -------------------------------------------------------------------

/// Where to keep a value and for how long.
pub opaque type Entry {
  Entry(key: String, ttl_ms: Int, tags: List(String))
}

/// Keep the value under `key` for `ttl` seconds. A `ttl` of zero or less
/// means the value is computed every time and never stored.
pub fn entry(key: String, ttl seconds: Int) -> Entry {
  Entry(key:, ttl_ms: seconds * 1000, tags: [])
}

/// Like `entry`, with the time to keep it in milliseconds.
pub fn entry_ms(key: String, ttl milliseconds: Int) -> Entry {
  Entry(key:, ttl_ms: milliseconds, tags: [])
}

/// Tag the entry, so that `invalidate` with any of these tags removes it.
/// Adds to the tags it already has.
pub fn tags(entry: Entry, tags: List(String)) -> Entry {
  Entry(..entry, tags: list.unique(list.append(entry.tags, tags)))
}

// -- Reading -------------------------------------------------------------------

/// The value under the entry's key if there is a current one, otherwise
/// the result of `compute`, stored when it is `Ok`.
///
/// ```gleam
/// use <- cache.fetch(app_cache, cache.entry("stats", ttl: 60), stats.codec())
/// stats.compute(db)
/// ```
pub fn fetch(
  cache: Cache,
  entry: Entry,
  codec: Codec(a),
  compute: fn() -> service.Result(a),
) -> service.Result(a) {
  use <- trace.span("cache.fetch", [
    trace.string("cache.store", cache.store.name),
  ])
  case entry.ttl_ms <= 0 || inside_transaction() {
    True -> {
      trace.set_attributes([trace.bool("cache.skipped", True)])
      compute()
    }
    False -> {
      let key = full_key(cache, entry.key)
      case lookup(cache, key, codec) {
        Found(value) -> hit(value)
        Failed -> compute_only(cache, key, codec, compute)
        Missing -> {
          // The versions are read before the value is computed. If the
          // data changes and is invalidated while it computes, the stored
          // versions are already out of date and the value is never
          // served. They are part of the flight's key too, so a request
          // that starts after an invalidation never waits for, and is
          // handed, a value computed before it.
          let tags = list.map(entry.tags, full_key(cache, _))
          let versions = case tags {
            [] -> Ok([])
            _ -> cache.store.versions(tags)
          }
          case versions {
            Error(error) -> {
              warn(cache, "read tag versions", error)
              compute_only(cache, key, codec, compute)
            }
            Ok(versions) ->
              together(cache, #(key, versions), codec, fn() {
                // A flight that just ended may have stored it.
                case lookup(cache, key, codec) {
                  Found(value) -> hit(value)
                  Missing | Failed ->
                    fill(cache, key, entry, codec, versions, compute)
                }
              })
          }
        }
      }
    }
  }
}

/// The store is down: compute without storing, still only once per node.
fn compute_only(
  cache: Cache,
  key: String,
  codec: Codec(a),
  compute: fn() -> service.Result(a),
) -> service.Result(a) {
  together(cache, #(key, []), codec, fn() {
    trace.set_attributes([trace.bool("cache.hit", False)])
    compute()
  })
}

/// Compute once for every request on this node asking for the same flight
/// at the same time. Requests that waited get the leader's value as JSON
/// and decode it with their own codec, since requests for one key need
/// not agree on its type; if theirs cannot read it, they compute it.
fn together(
  cache: Cache,
  flight_key: #(String, List(#(String, Int))),
  codec: Codec(a),
  compute: fn() -> service.Result(a),
) -> service.Result(a) {
  let share = fn(outcome) { result.map(outcome, codec.to_string(codec, _)) }
  case flight(cache.flights, flight_key, compute, share) {
    Led(outcome) -> outcome
    Joined(Error(error)) -> Error(error)
    Joined(Ok(text)) ->
      case codec.from_string(codec, text) {
        Ok(value) -> Ok(value)
        Error(_) -> compute()
      }
  }
}

fn hit(value: a) -> service.Result(a) {
  trace.set_attributes([trace.bool("cache.hit", True)])
  Ok(value)
}

fn fill(
  cache: Cache,
  key: String,
  entry: Entry,
  codec: Codec(a),
  versions: List(#(String, Int)),
  compute: fn() -> service.Result(a),
) -> service.Result(a) {
  trace.set_attributes([trace.bool("cache.hit", False)])
  use value <- result.map(compute())
  let text = codec.to_string(codec, value)
  case string.byte_size(text) > cache.max_value_bytes {
    True -> trace.set_attributes([trace.bool("cache.too_large", True)])
    False -> {
      let expires_at = cache.clock() + entry.ttl_ms
      case cache.store.write(key, text, expires_at, versions) {
        Ok(Nil) -> Nil
        Error(error) -> warn(cache, "store a value", error)
      }
    }
  }
  value
}

/// The current value under `key`, if there is one. A store that fails is
/// logged and reads as `None`. Like `fetch`, reads nothing inside a
/// transaction.
pub fn get(cache: Cache, key: String, codec: Codec(a)) -> Option(a) {
  case inside_transaction() {
    True -> None
    False ->
      case lookup(cache, full_key(cache, key), codec) {
        Found(value) -> Some(value)
        Missing | Failed -> None
      }
  }
}

type Lookup(a) {
  Found(a)
  Missing
  Failed
}

fn lookup(cache: Cache, key: String, codec: Codec(a)) -> Lookup(a) {
  case cache.store.read(key) {
    Ok(Some(Stored(value:, expires_at:, current: True))) ->
      case expires_at > cache.clock() {
        True ->
          case codec.from_string(codec, value) {
            Ok(value) -> Found(value)
            Error(_) -> {
              trace.set_attributes([trace.bool("cache.undecodable", True)])
              Missing
            }
          }
        False -> Missing
      }
    Ok(_) -> Missing
    Error(error) -> {
      warn(cache, "read a value", error)
      Failed
    }
  }
}

// -- Writing -------------------------------------------------------------------

/// Store `value` under the entry's key, replacing what is there. The tags
/// take their current versions when the value is stored, so only `put` a
/// value that is current then; `fetch` is safer.
///
/// Inside a transaction the value is not stored: once the transaction has
/// ended the key is deleted instead, and the next `fetch` computes it. The
/// value might come from changes the transaction, or a savepoint within
/// it, rolls back, and the cache cannot tell.
pub fn put(
  cache: Cache,
  entry: Entry,
  codec: Codec(a),
  value: a,
) -> service.Result(Nil) {
  let text = codec.to_string(codec, value)
  let key = full_key(cache, entry.key)
  let tags = list.map(entry.tags, full_key(cache, _))
  case
    defer(fn() { deferred(cache, "delete a value", cache.store.delete(key)) })
  {
    True -> Ok(Nil)
    False ->
      case entry.ttl_ms <= 0 || string.byte_size(text) > cache.max_value_bytes {
        True -> cache.store.delete(key)
        False -> {
          use versions <- result.try(case tags {
            [] -> Ok([])
            _ -> cache.store.versions(tags)
          })
          cache.store.write(key, text, cache.clock() + entry.ttl_ms, versions)
        }
      }
  }
}

/// Remove the entry under `key`. Inside a transaction this happens once the
/// transaction has ended.
///
/// Unlike `invalidate`, this cannot stop a `fetch` that read the old data
/// just before the change from storing it just after the delete. Tag
/// entries whose data changes, and invalidate the tag.
pub fn delete(cache: Cache, key: String) -> service.Result(Nil) {
  let key = full_key(cache, key)
  after_transaction(cache, "delete a value", fn() { cache.store.delete(key) })
}

/// Treat every entry carrying any of `tags` as missing from now on. Inside
/// a transaction this happens once the transaction has ended, whether it
/// committed or not.
pub fn invalidate(cache: Cache, tags: List(String)) -> service.Result(Nil) {
  // Sorted, so that two invalidations of the same tags take the stores'
  // row locks in the same order and cannot deadlock.
  case
    list.map(tags, full_key(cache, _))
    |> list.unique
    |> list.sort(string.compare)
  {
    [] -> Ok(Nil)
    tags -> {
      after_transaction(cache, "invalidate tags", fn() {
        trace.span(
          "cache.invalidate",
          [trace.int("cache.tags", list.length(tags))],
          fn() { cache.store.invalidate(tags) },
        )
      })
    }
  }
}

/// Remove every entry in the store, in every namespace. Tag versions are
/// kept.
pub fn clear(cache: Cache) -> service.Result(Nil) {
  cache.store.clear()
}

// -- Transactions --------------------------------------------------------------

fn after_transaction(
  cache: Cache,
  doing: String,
  run: fn() -> service.Result(Nil),
) -> service.Result(Nil) {
  case defer(fn() { deferred(cache, doing, run()) }) {
    True -> Ok(Nil)
    False -> run()
  }
}

fn deferred(cache: Cache, doing: String, outcome: service.Result(Nil)) -> Nil {
  case outcome {
    Ok(Nil) -> Nil
    Error(error) -> warn(cache, doing <> " after a transaction", error)
  }
}

/// The `around_transactions` hook: collect what `invalidate`, `delete` and
/// `put` defer, and run it once the outermost transaction has ended.
@external(erlang, "howdy_cache_ffi", "in_transaction")
fn in_transaction(run: fn() -> Dynamic) -> Dynamic

@external(erlang, "howdy_cache_ffi", "inside_transaction")
fn inside_transaction() -> Bool

/// Queue `run` for the end of the current transaction. `False` when there
/// is no transaction to wait for.
@external(erlang, "howdy_cache_ffi", "defer")
fn defer(run: fn() -> Nil) -> Bool

// -- Helpers -------------------------------------------------------------------

/// Long keys and tags are stored as their hash, so stores can index them.
const max_key_bytes = 250

fn full_key(cache: Cache, key: String) -> String {
  let key = cache.namespace <> key
  case string.byte_size(key) > max_key_bytes {
    True -> "#" <> bit_array.base64_url_encode(digest(<<key:utf8>>), False)
    False -> key
  }
}

type Flights

@external(erlang, "howdy_cache_ffi", "flights_new")
fn new_flights() -> Flights

type Flown(a) {
  Led(service.Result(a))
  Joined(service.Result(String))
}

@external(erlang, "howdy_cache_ffi", "flight")
fn flight(
  flights: Flights,
  key: #(String, List(#(String, Int))),
  compute: fn() -> service.Result(a),
  share: fn(service.Result(a)) -> service.Result(String),
) -> Flown(a)

@external(erlang, "howdy_cache_ffi", "digest")
fn digest(bits: BitArray) -> BitArray

@external(erlang, "howdy_cache_ffi", "system_ms")
fn system_ms() -> Int

fn warn(cache: Cache, doing: String, error: service.Error) -> Nil {
  let detail = case error {
    service.Internal(detail) -> detail
    other -> string.inspect(other)
  }
  trace.set_attributes([trace.bool("cache.store_failed", True)])
  logging.log(
    logging.Warning,
    "howdy_cache: the "
      <> cache.store.name
      <> " store could not "
      <> doing
      <> ": "
      <> detail,
  )
}
