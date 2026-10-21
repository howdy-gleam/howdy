//// Rate limiting middleware.
////
//// Create a limiter once at startup, then attach it at any level with a
//// choice of how to identify the client.
////
//// ```gleam
//// let api = rate_limit.fixed_window(limit: 100, per_seconds: 60)
//// let writes = rate_limit.token_bucket(capacity: 10, refill_per_second: 1)
////
//// howdy.new()
//// |> howdy.middleware(rate_limit.by_ip(api))
////
//// controller.post("/", create |> middleware.wrap(rate_limit.by_header(writes, "x-api-key")))
//// ```
////
//// Counters live in an ETS table owned by the process that called the
//// constructor. Create limiters in `main`, not inside a handler.
//// A linked cleanup process expires old windows every window or minute,
//// whichever is shorter. It exits when the constructor's process exits.
//// Token buckets are evicted once they have refilled to capacity, which is
//// the same as not existing; a bucket is never evicted while it is short of
//// tokens. Sweeps run at most a minute apart.
////
//// Each limiter tracks at most `default_max_identities` distinct keys, which
//// `max_identities` adjusts. The bound is exact: a slot is reserved
//// atomically before a row is inserted, so concurrent first hits cannot
//// overshoot it. Keys over 64 bytes are stored as their SHA-256, so row size
//// is bounded too. Keys already in the table keep being limited even when
//// the table is full. A key not yet in the table is refused with
//// `Saturated`, so an attacker who can mint keys (a spoofed header, a large
//// IPv6 range) cannot grow memory without bound, and cannot switch limiting
//// off either. Trade-off: while saturated, new legitimate clients are
//// refused too, and room only returns when a sweep finds rows to evict.
//// Size the cap for your identity space.
////
//// Behind a proxy every request shares the proxy's IP, so use `by_header`
//// with the header your proxy sets rather than `by_ip`.
////
//// Those counters belong to one node: behind a load balancer each node allows
//// the full limit, and a restart forgets it. `shared` keeps a fixed window's
//// counts in a `Store` every node can reach, such as a database table, at
//// the cost of one round trip per request.

import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/option.{type Option, None, Some}
import howdy/content.{type Content}
import howdy/context
import howdy/controller.{type Context, type Middleware}
import howdy/service
import logging

type Table

/// Whether the store accepted a hit. `Refused` means the key was new and the
/// identity cap was reached.
type Admission {
  Admitted(Int)
  Refused
}

/// Constructors return the table and the sweep interval in milliseconds.
@external(erlang, "howdy_rate_limit_ffi", "fixed_window_new")
fn fixed_window_new(window_ms: Int) -> #(Table, Int)

@external(erlang, "howdy_rate_limit_ffi", "token_bucket_new")
fn token_bucket_new(capacity_milli: Int, rate_per_second: Int) -> #(Table, Int)

@external(erlang, "howdy_rate_limit_ffi", "token_bucket_check")
fn token_bucket_check(
  table: Table,
  key: String,
  capacity_milli: Int,
  rate_per_second: Int,
  max_identities: Int,
) -> Admission

@external(erlang, "howdy_rate_limit_ffi", "now_ms")
fn now_ms() -> Int

@external(erlang, "howdy_rate_limit_ffi", "system_ms")
fn system_ms() -> Int

@external(erlang, "howdy_rate_limit_ffi", "fixed_window_hit")
fn fixed_window_hit(
  table: Table,
  key: String,
  window: Int,
  max_identities: Int,
) -> Admission

@external(erlang, "howdy_rate_limit_ffi", "token_bucket_hit")
fn token_bucket_hit(
  table: Table,
  key: String,
  capacity_milli: Int,
  rate_per_second: Int,
  max_identities: Int,
  now_ms: Int,
) -> Admission

/// How many distinct keys a limiter tracks unless `max_identities` says
/// otherwise. At roughly a hundred bytes per row this is a few tens of
/// megabytes at worst.
pub const default_max_identities = 100_000

pub opaque type Limiter {
  FixedWindow(
    table: Table,
    limit: Int,
    window_ms: Int,
    sweep_ms: Int,
    max_identities: Int,
  )
  TokenBucket(
    table: Table,
    capacity: Int,
    refill_per_second: Int,
    sweep_ms: Int,
    max_identities: Int,
  )
  Shared(store: Store, name: String, limit: Int, window_ms: Int)
}

/// Counts kept outside this node. `increment(key, window, expires_at_ms)`
/// adds a hit to `key` in fixed window number `window` and returns how many
/// that window has counted, this one included. It must be atomic per key.
/// A hit for a window older than the one a key holds (a node with a slow
/// clock) should count against the newer window rather than reset it. The
/// count is not needed after `expires_at_ms`, Unix time in milliseconds.
pub type Store {
  Store(increment: fn(String, Int, Int) -> Result(Int, Nil))
}

/// The outcome of checking a key against a limiter.
pub type Decision {
  /// The request may proceed. `remaining` is how many more are allowed
  /// before the limit; `reset_seconds` is when that number goes back up.
  Allowed(limit: Int, remaining: Int, reset_seconds: Int)
  /// The request is over the limit. Try again after `retry_after_seconds`.
  Denied(limit: Int, retry_after_seconds: Int)
  /// The key is new and the limiter already tracks its maximum number of
  /// identities. Nothing was counted. The next sweep runs within
  /// `retry_after_seconds`; it frees room only if some rows have expired
  /// or refilled by then.
  Saturated(retry_after_seconds: Int)
}

/// Allow `limit` requests per key in each window of `per_seconds`. Simple
/// and predictable; a client can make up to twice `limit` requests around a
/// window boundary.
pub fn fixed_window(limit limit: Int, per_seconds per_seconds: Int) -> Limiter {
  let window_ms = int.max(per_seconds, 1) * 1000
  let #(table, sweep_ms) = fixed_window_new(window_ms)
  FixedWindow(
    table:,
    limit: int.max(limit, 1),
    window_ms:,
    sweep_ms:,
    max_identities: default_max_identities,
  )
}

/// Each key has a bucket holding up to `capacity` tokens, refilled at
/// `refill_per_second`. A request takes one token. Allows short bursts while
/// holding the long-run rate.
pub fn token_bucket(
  capacity capacity: Int,
  refill_per_second refill_per_second: Int,
) -> Limiter {
  let capacity = int.max(capacity, 1)
  let refill_per_second = int.max(refill_per_second, 1)
  let #(table, sweep_ms) = token_bucket_new(capacity * 1000, refill_per_second)
  TokenBucket(
    table:,
    capacity:,
    refill_per_second:,
    sweep_ms:,
    max_identities: default_max_identities,
  )
}

/// Allow `limit` requests per key in each window of `per_seconds`, counted in
/// `store` so every node shares them. `name` separates this limiter's keys
/// from any other limiter using the same store; give each a different one.
/// Windows follow the system clock, so keep nodes' clocks synchronised.
///
/// If the store fails, the request is allowed and a warning logged: a limiter
/// is abuse protection, and one that failed closed would turn an outage of
/// its store into an outage of every route behind it.
pub fn shared(
  limit limit: Int,
  per_seconds per_seconds: Int,
  name name: String,
  store store: Store,
) -> Limiter {
  Shared(
    store:,
    name:,
    limit: int.max(limit, 1),
    window_ms: int.max(per_seconds, 1) * 1000,
  )
}

/// Track at most `count` distinct keys instead of `default_max_identities`.
/// Counts rows in the table: for a fixed window a key's previous window also
/// occupies a row until the sweep after the boundary, so allow for that.
///
/// ```gleam
/// rate_limit.fixed_window(limit: 100, per_seconds: 60)
/// |> rate_limit.max_identities(1_000_000)
/// ```
pub fn max_identities(limiter: Limiter, count: Int) -> Limiter {
  let count = int.max(count, 1)
  case limiter {
    FixedWindow(..) -> FixedWindow(..limiter, max_identities: count)
    TokenBucket(..) -> TokenBucket(..limiter, max_identities: count)
    // The store bounds its own size.
    Shared(..) -> limiter
  }
}

/// Record a hit for `key` and decide whether it is allowed.
pub fn check(limiter: Limiter, key: String) -> Decision {
  case limiter {
    FixedWindow(..) -> check_at(limiter, key, now_ms())
    Shared(..) -> check_at(limiter, key, system_ms())
    TokenBucket(table:, capacity:, refill_per_second:, max_identities:, ..) ->
      case
        token_bucket_check(
          table,
          key,
          capacity * 1000,
          refill_per_second,
          max_identities,
        )
      {
        Admitted(available) ->
          bucket_decision(available, capacity, refill_per_second)
        Refused -> saturated(limiter)
      }
  }
}

/// Like `check` but with the current time supplied in milliseconds. Exposed
/// so tests can drive the clock without sleeping. Automatic cleanup uses the
/// VM monotonic clock; use its time domain and do not replay times whose state
/// has already expired. Use `check` for live traffic: it resamples time when
/// retrying after concurrent updates or eviction.
/// A token bucket treats timestamps older than its last update as that last
/// update's time, so delayed concurrent requests cannot reverse its clock.
pub fn check_at(limiter: Limiter, key: String, now_ms: Int) -> Decision {
  case limiter {
    FixedWindow(table:, limit:, window_ms:, max_identities:, ..) -> {
      // The monotonic clock can be negative, so floor rather than truncate.
      let window = floor_div(now_ms, window_ms)
      let reset_ms = { window + 1 } * window_ms - now_ms
      let reset_seconds = ceil_seconds(reset_ms)
      case fixed_window_hit(table, key, window, max_identities) {
        Admitted(count) ->
          case count <= limit {
            True -> Allowed(limit:, remaining: limit - count, reset_seconds:)
            False -> Denied(limit:, retry_after_seconds: reset_seconds)
          }
        Refused -> saturated(limiter)
      }
    }
    Shared(store:, name:, limit:, window_ms:) -> {
      let window = floor_div(now_ms, window_ms)
      let expires_at = { window + 1 } * window_ms
      let reset_seconds = ceil_seconds(expires_at - now_ms)
      case store.increment(name <> "\u{0}" <> key, window, expires_at) {
        Ok(count) if count <= limit ->
          Allowed(limit:, remaining: limit - count, reset_seconds:)
        Ok(_) -> Denied(limit:, retry_after_seconds: reset_seconds)
        Error(Nil) -> {
          // Once per window per limiter, not once per request: an outage
          // would otherwise write a line for every request behind it.
          case warn_at_most_every(name, window_ms) {
            True ->
              logging.log(
                logging.Warning,
                "rate limit store failed for "
                  <> name
                  <> "; allowing requests until it recovers",
              )
            False -> Nil
          }
          Allowed(limit:, remaining: limit, reset_seconds:)
        }
      }
    }
    TokenBucket(table:, capacity:, refill_per_second:, max_identities:, ..) ->
      case
        token_bucket_hit(
          table,
          key,
          capacity * 1000,
          refill_per_second,
          max_identities,
          now_ms,
        )
      {
        Admitted(available) ->
          bucket_decision(available, capacity, refill_per_second)
        Refused -> saturated(limiter)
      }
  }
}

fn saturated(limiter: Limiter) -> Decision {
  let sweep_ms = case limiter {
    FixedWindow(sweep_ms:, ..) | TokenBucket(sweep_ms:, ..) -> sweep_ms
    // Never saturates: the store bounds its own size.
    Shared(window_ms:, ..) -> window_ms
  }
  Saturated(retry_after_seconds: ceil_seconds(sweep_ms))
}

fn bucket_decision(
  available: Int,
  capacity: Int,
  refill_per_second: Int,
) -> Decision {
  // Milliseconds until one whole token exists, given the balance.
  let ms_per_token = 1000 / refill_per_second
  case available >= 1000 {
    True -> {
      let remaining = { available - 1000 } / 1000
      Allowed(
        limit: capacity,
        remaining:,
        reset_seconds: ceil_seconds(ms_per_token),
      )
    }
    False -> {
      let shortfall = 1000 - available
      Denied(
        limit: capacity,
        retry_after_seconds: ceil_seconds(shortfall * ms_per_token / 1000),
      )
    }
  }
}

fn floor_div(a: Int, b: Int) -> Int {
  let q = a / b
  case a % b < 0 {
    True -> q - 1
    False -> q
  }
}

fn ceil_seconds(ms: Int) -> Int {
  int.max({ ms + 999 } / 1000, 1)
}

// -- Middleware --------------------------------------------------------------

/// When limiters are nested, the innermost one has already set its headers by
/// the time an outer one runs, and the innermost is the most specific limit
/// for that route, so its headers are kept.
fn set_if_absent(
  res: response.Response(Content),
  name: String,
  value: String,
) -> response.Response(Content) {
  case response.get_header(res, name) {
    Ok(_) -> res
    Error(Nil) -> response.set_header(res, name, value)
  }
}

/// Limit by the client's socket address. Behind a proxy, prefer `by_header`.
pub fn by_ip(limiter: Limiter) -> Middleware {
  by(limiter, fn(ctx) { context.client_ip(ctx.request) })
}

/// Limit by the value of a request header. Requests without the header are
/// not limited; combine with an auth middleware that requires it.
pub fn by_header(limiter: Limiter, header: String) -> Middleware {
  by(limiter, fn(ctx) {
    request.get_header(ctx.request, header) |> option.from_result
  })
}

/// Limit by any key you derive from the request. `None` skips limiting.
pub fn by(limiter: Limiter, key: fn(Context) -> Option(String)) -> Middleware {
  fn(ctx, next) {
    case key(ctx) {
      None -> next(ctx)
      Some(key) ->
        case check(limiter, key) {
          Allowed(limit:, remaining:, reset_seconds:) ->
            next(ctx)
            |> set_if_absent("x-ratelimit-limit", int.to_string(limit))
            |> set_if_absent("x-ratelimit-remaining", int.to_string(remaining))
            |> set_if_absent("x-ratelimit-reset", int.to_string(reset_seconds))
          Denied(limit:, retry_after_seconds:) ->
            service.error_response(
              ctx,
              service.TooManyRequests(retry_after_seconds),
            )
            |> response.set_header("x-ratelimit-limit", int.to_string(limit))
            |> response.set_header("x-ratelimit-remaining", "0")
          Saturated(retry_after_seconds:) ->
            service.error_response(
              ctx,
              service.TooManyRequests(retry_after_seconds),
            )
            |> response.set_header("x-ratelimit-saturated", "true")
        }
    }
  }
}

@external(erlang, "howdy_ffi", "warn_at_most_every")
fn warn_at_most_every(key: String, interval_ms: Int) -> Bool
