//// Optional bounded authorization cache. Never caches database errors.
////
//// The dirty flag and transaction depth live in the calling process's
//// dictionary (see `howdy_auth_ffi`). `transaction` and `changing` must
//// therefore run in the process that holds the database transaction: a
//// grant mutation made from a process spawned inside a transaction is not
//// seen by the outer transaction's hook and invalidates as soon as its own
//// `changing` returns, not after the outer commit.

import howdy/database
import howdy/migration
import howdy/service

pub type Cache

@external(erlang, "howdy_auth_ffi", "cache_new")
fn table() -> Cache

/// Migrations can rewrite grants and suspensions under a live cache, whichever
/// package they belong to, so every run on this node invalidates it. A grant
/// change inside an application's own transaction must invalidate after that
/// transaction commits, not after auth's savepoint, or a concurrent read could
/// cache the old grant again in between.
pub fn new() -> Cache {
  migration.around_runs("howdy_auth_cache", changing)
  database.around_transactions("howdy_auth_cache", transaction)
  table()
}

@external(erlang, "howdy_auth_ffi", "cache_run")
pub fn run(
  cache: Cache,
  key: #(String, String, String, String, String),
  seconds: Int,
  load: fn() -> service.Result(Bool),
) -> service.Result(Bool)

@external(erlang, "howdy_auth_ffi", "cache_invalidate")
pub fn invalidate() -> Nil

/// Carry a mutation's dirty flag through outer Howdy transaction boundaries.
/// Runs as the `around_transactions` hook, in the transaction's own process.
@external(erlang, "howdy_auth_ffi", "cache_transaction")
pub fn transaction(run: fn() -> a) -> a

/// Invalidate before a grant mutation and after its outermost transaction,
/// including rollback or exceptions. Ordinary auth transactions stay read-only
/// with respect to cache generations. Call it in the process that holds the
/// transaction, never from a process spawned inside one.
@external(erlang, "howdy_auth_ffi", "cache_changing")
pub fn changing(run: fn() -> a) -> a
