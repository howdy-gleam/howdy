//// Where sessions live. By default that is the auth database, and nothing
//// here is needed. Supply a `SessionStore` to `auth.with_session_store` to
//// keep them somewhere else instead: Redis, Valkey, DynamoDB, anything that
//// can hold a small record under a key and find a user's records.
////
//// A store never sees a session token. `digest` is a one-way digest of it,
//// so what a store holds cannot be used to sign in. Users, credentials and
//// suspension stay in the database: every request still confirms there that
//// the session's user is active.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import howdy/service

/// One session. Store every field and return it unchanged.
pub type Entry {
  Entry(
    /// The key. Unique, 43 URL-safe characters.
    digest: String,
    user_id: String,
    /// How the session was authenticated. Opaque text to a store.
    method: String,
    /// Unix seconds, as are the two below.
    created_at: Int,
    last_seen_at: Int,
    /// A store may drop the record at any time from this moment on, so it
    /// suits a native expiry such as a Redis TTL. `touch` may move it later.
    expires_at: Int,
    client: String,
    /// Account session generation. Preserve it unchanged; older generations
    /// are refused against the database even when store cleanup fails.
    version: Int,
  )
}

/// The operations a store provides. Each may be called from any process, and
/// concurrently. Return `Error(service.Internal(_))` when the backend fails:
/// the operation then fails closed rather than guessing. The package checks
/// expiry and idleness itself, so `get` and `list` may return records that
/// have expired, or not, as suits the backend.
pub type SessionStore {
  SessionStore(
    /// Add a record. Digests do not collide; overwriting is acceptable.
    insert: fn(Entry) -> service.Result(Nil),
    /// The record stored under a digest.
    get: fn(String) -> service.Result(Option(Entry)),
    /// Set `last_seen_at`, then `expires_at`, for a digest. `expires_at`
    /// repeats the stored value unless `policy.session_renew_seconds` is
    /// renewing the session, when it is later; a backend with native expiry
    /// resets its TTL from it. Called at most about once a minute per
    /// session. An unknown digest is not an error and creates nothing.
    touch: fn(String, Int, Int) -> service.Result(Nil),
    /// Every record of a user id, in any order.
    list: fn(String) -> service.Result(List(Entry)),
    /// Remove the record under a digest if it belongs to the user id. A
    /// record of another user must survive. Nothing to remove is not an error.
    delete: fn(String, String) -> service.Result(Nil),
    /// Remove every record of a user id, except the digest to keep, if any.
    delete_for_user: fn(String, Option(String)) -> service.Result(Nil),
    /// Housekeeping: remove records with `expires_at` at or before the given
    /// time. A backend with native expiry can do nothing.
    prune: fn(Int) -> service.Result(Nil),
  )
}

/// A reference under which the owner process publishes its table.
type Handle

@external(erlang, "howdy_auth_sessions", "new_ref")
fn handle_new() -> Handle

@external(erlang, "howdy_auth_sessions", "start")
fn owner_start() -> Handle

@external(erlang, "howdy_auth_sessions", "start_link")
fn owner_start_link(handle: Handle) -> Result(process.Pid, Dynamic)

@external(erlang, "howdy_auth_ffi", "sessions_put")
fn table_put(
  handle: Handle,
  digest: String,
  user_id: String,
  expires_at: Int,
  record: Entry,
) -> Result(Nil, Nil)

@external(erlang, "howdy_auth_ffi", "sessions_get")
fn table_get(handle: Handle, digest: String) -> Result(Option(Entry), Nil)

@external(erlang, "howdy_auth_ffi", "sessions_list")
fn table_list(handle: Handle, user_id: String) -> Result(List(Entry), Nil)

@external(erlang, "howdy_auth_ffi", "sessions_delete")
fn table_delete(
  handle: Handle,
  digest: String,
  user_id: String,
) -> Result(Nil, Nil)

@external(erlang, "howdy_auth_ffi", "sessions_delete_user")
fn table_delete_user(
  handle: Handle,
  user_id: String,
  keep: String,
) -> Result(Nil, Nil)

@external(erlang, "howdy_auth_ffi", "sessions_prune")
fn table_prune(handle: Handle, now: Int) -> Result(Nil, Nil)

/// Sessions in this node's memory: a reference implementation, and useful in
/// tests and single-node development. Sessions are lost on restart and are
/// not shared between nodes. The table belongs to a small process of its own,
/// started here unlinked, so it outlives the caller and neither takes the
/// other down; it runs until the VM stops. Use `memory_supervised` instead
/// when the application has a supervision tree to own it.
pub fn memory() -> SessionStore {
  store(owner_start())
}

/// `memory`, with the table's owner as a child for the application's
/// supervisor. The store may be used as soon as the child has started, and
/// again after the supervisor restarts it, when it starts empty: sessions
/// die with the owner. Until then, and while the owner is down, every
/// operation returns `Error(service.Internal(_))`.
pub fn memory_supervised() -> #(
  supervision.ChildSpecification(Nil),
  SessionStore,
) {
  let handle = handle_new()
  let child =
    supervision.worker(fn() {
      case owner_start_link(handle) {
        Ok(pid) -> Ok(actor.Started(pid:, data: Nil))
        Error(reason) -> Error(actor.InitFailed(string.inspect(reason)))
      }
    })
  #(child, store(handle))
}

fn store(handle: Handle) -> SessionStore {
  let put = fn(record: Entry) {
    table_put(handle, record.digest, record.user_id, record.expires_at, record)
    |> unavailable
  }
  SessionStore(
    insert: put,
    get: fn(digest) { table_get(handle, digest) |> unavailable },
    touch: fn(digest, now, expires_at) {
      case table_get(handle, digest) |> unavailable {
        Ok(Some(record)) -> put(Entry(..record, last_seen_at: now, expires_at:))
        Ok(None) -> Ok(Nil)
        Error(failure) -> Error(failure)
      }
    },
    list: fn(user_id) { table_list(handle, user_id) |> unavailable },
    delete: fn(digest, user_id) {
      table_delete(handle, digest, user_id) |> unavailable
    },
    delete_for_user: fn(user_id, keep) {
      table_delete_user(handle, user_id, option.unwrap(keep, "")) |> unavailable
    },
    prune: fn(now) { table_prune(handle, now) |> unavailable },
  )
}

/// The table is gone: its owner is down, or it was deleted. Fail closed.
fn unavailable(answer: Result(a, Nil)) -> service.Result(a) {
  result.replace_error(
    answer,
    service.Internal("in-memory session store is unavailable"),
  )
}

/// Exercise a store against the contract above, for an adapter's own test
/// suite. Returns the first rule it breaks. It writes and removes records
/// under user ids beginning `howdy-check-`, so point it at a test backend.
pub fn check(store: SessionStore) -> Result(Nil, String) {
  let ada = "howdy-check-ada"
  let bob = "howdy-check-bob"
  let far = 4_000_000_000
  let entry = fn(n: Int, user_id: String, expires_at: Int) {
    Entry(
      digest: "howdy-check-digest-" <> int.to_string(n),
      user_id:,
      method: "email",
      created_at: 100 + n,
      last_seen_at: 200 + n,
      expires_at:,
      client: "client-" <> int.to_string(n),
      version: n,
    )
  }
  let first = entry(1, ada, far)
  let second = entry(2, ada, far)
  let third = entry(3, ada, far)
  let other = entry(4, bob, far)
  let digests = fn(user_id) {
    use records <- result.map(call(store.list(user_id), "list"))
    list.map(records, fn(r: Entry) { r.digest }) |> list.sort(string.compare)
  }
  use _ <- result.try(call(store.delete_for_user(ada, None), "delete_for_user"))
  use _ <- result.try(call(store.delete_for_user(bob, None), "delete_for_user"))
  use _ <- result.try(
    list.try_each([first, second, third, other], fn(r) {
      call(store.insert(r), "insert")
    }),
  )
  use found <- result.try(call(store.get(first.digest), "get"))
  use _ <- result.try(expect(
    found == Some(first),
    "get must return the inserted record unchanged",
  ))
  use missing <- result.try(call(store.get("howdy-check-missing"), "get"))
  use _ <- result.try(expect(
    missing == None,
    "get must return None for an unknown digest",
  ))
  use _ <- result.try(call(store.touch(first.digest, 999, far), "touch"))
  use touched <- result.try(call(store.get(first.digest), "get"))
  use _ <- result.try(expect(
    touched == Some(Entry(..first, last_seen_at: 999)),
    "touch must change last_seen_at and leave an unchanged expires_at alone",
  ))
  use _ <- result.try(call(store.touch(first.digest, 1000, far + 60), "touch"))
  use renewed <- result.try(call(store.get(first.digest), "get"))
  use _ <- result.try(expect(
    renewed == Some(Entry(..first, last_seen_at: 1000, expires_at: far + 60)),
    "touch must set last_seen_at and expires_at and nothing else",
  ))
  use _ <- result.try(call(store.touch(first.digest, 1000, far), "touch"))
  use _ <- result.try(call(
    store.touch("howdy-check-missing", 999, far),
    "touch",
  ))
  use created <- result.try(call(store.get("howdy-check-missing"), "get"))
  use _ <- result.try(expect(created == None, "touch must not create a record"))
  use listed <- result.try(digests(ada))
  use _ <- result.try(expect(
    listed == [first.digest, second.digest, third.digest],
    "list must return exactly the user's records",
  ))
  use _ <- result.try(call(store.delete(other.digest, ada), "delete"))
  use kept <- result.try(call(store.get(other.digest), "get"))
  use _ <- result.try(expect(
    kept == Some(other),
    "delete must not remove another user's record",
  ))
  use _ <- result.try(call(store.delete(third.digest, ada), "delete"))
  use _ <- result.try(call(store.delete(third.digest, ada), "delete"))
  use gone <- result.try(call(store.get(third.digest), "get"))
  use _ <- result.try(expect(gone == None, "delete must remove the record"))
  use _ <- result.try(call(
    store.delete_for_user(ada, Some(first.digest)),
    "delete_for_user",
  ))
  use listed <- result.try(digests(ada))
  use _ <- result.try(expect(
    listed == [first.digest],
    "delete_for_user must keep only the digest it was given",
  ))
  use others <- result.try(digests(bob))
  use _ <- result.try(expect(
    others == [other.digest],
    "delete_for_user must not touch other users",
  ))
  use _ <- result.try(call(store.prune(50), "prune"))
  use unexpired <- result.try(call(store.get(first.digest), "get"))
  use _ <- result.try(expect(
    unexpired != None,
    "prune must keep records that have not expired",
  ))
  use _ <- result.try(call(store.delete_for_user(ada, None), "delete_for_user"))
  use _ <- result.try(call(store.delete_for_user(bob, None), "delete_for_user"))
  use listed <- result.try(digests(ada))
  expect(listed == [], "delete_for_user without a keep must remove everything")
}

fn call(answer: service.Result(a), operation: String) -> Result(a, String) {
  result.replace_error(answer, operation <> " returned an error")
}

fn expect(holds: Bool, rule: String) -> Result(Nil, String) {
  case holds {
    True -> Ok(Nil)
    False -> Error(rule)
  }
}
