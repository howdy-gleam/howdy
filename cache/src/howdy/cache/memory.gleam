//// A cache store in this node's memory, in ETS tables.
////
//// ```gleam
//// let app_cache = cache.new(memory.new(max_entries: 50_000))
//// ```
////
//// The fastest store, and the right one for a single node. Each node has
//// its own: an `invalidate` on one node does not reach the others, so an
//// app running on several nodes that invalidates by tag needs
//// `howdy/cache/database`, or short enough expiry times that a stale
//// value for that long is acceptable. A restart empties it.
////
//// The tables belong to the process that called `new` and are deleted
//// when it exits. Create the store in `main`, or in a process that lives
//// as long as the app, not inside a handler.

import gleam/int
import gleam/option.{type Option}
import howdy/cache.{type Store, type Stored}

type Tables

/// A store holding about `max_entries` entries. When it is full, a write
/// first removes expired entries, then the entries closest to expiring
/// until a tenth of the room is free. Writers racing each other can each
/// go one over the limit until the next write; a sweep every minute
/// removes expired entries and trims back to the limit.
pub fn new(max_entries max_entries: Int) -> Store {
  from_tables(new_tables(max_entries, 60_000))
}

/// Like `new`, sweeping expired entries every `sweep_every` milliseconds.
pub fn sweeping(max_entries max_entries: Int, every sweep_every: Int) -> Store {
  from_tables(new_tables(max_entries, sweep_every))
}

fn from_tables(tables: Tables) -> Store {
  cache.store(
    named: "memory",
    read: fn(key) { Ok(read(tables, key)) },
    versions: fn(tags) { Ok(versions(tables, tags)) },
    write: fn(key, value, expires_at, versions) {
      Ok(write(tables, key, value, expires_at, versions))
    },
    delete: fn(key) { Ok(delete(tables, key)) },
    invalidate: fn(tags) { Ok(invalidate(tables, tags)) },
    clear: fn() { Ok(clear(tables)) },
  )
}

fn new_tables(max_entries: Int, sweep_every: Int) -> Tables {
  ffi_new(int.max(max_entries, 1), int.max(sweep_every, 1000))
}

@external(erlang, "howdy_cache_ffi", "memory_new")
fn ffi_new(max_entries: Int, sweep_ms: Int) -> Tables

@external(erlang, "howdy_cache_ffi", "memory_read")
fn read(tables: Tables, key: String) -> Option(Stored)

@external(erlang, "howdy_cache_ffi", "memory_versions")
fn versions(tables: Tables, tags: List(String)) -> List(#(String, Int))

@external(erlang, "howdy_cache_ffi", "memory_write")
fn write(
  tables: Tables,
  key: String,
  value: String,
  expires_at: Int,
  versions: List(#(String, Int)),
) -> Nil

@external(erlang, "howdy_cache_ffi", "memory_delete")
fn delete(tables: Tables, key: String) -> Nil

@external(erlang, "howdy_cache_ffi", "memory_invalidate")
fn invalidate(tables: Tables, tags: List(String)) -> Nil

@external(erlang, "howdy_cache_ffi", "memory_clear")
fn clear(tables: Tables) -> Nil
