import gleam/dict
import gleam/erlang/process
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import howdy
import howdy/context.{Context}
import howdy/controller.{type Context}
import howdy/rate_limit.{Allowed, Denied, Saturated}
import howdy/service
import howdy/testing

// -- fixed window ------------------------------------------------------------

pub fn fixed_window_allows_up_to_limit_test() {
  let limiter = rate_limit.fixed_window(limit: 3, per_seconds: 60)
  let t = 1000

  assert rate_limit.check_at(limiter, "k", t) == Allowed(3, 2, 59)
  assert rate_limit.check_at(limiter, "k", t) == Allowed(3, 1, 59)
  assert rate_limit.check_at(limiter, "k", t) == Allowed(3, 0, 59)
  assert rate_limit.check_at(limiter, "k", t) == Denied(3, 59)
}

pub fn fixed_window_resets_on_next_window_test() {
  let limiter = rate_limit.fixed_window(limit: 1, per_seconds: 10)

  assert rate_limit.check_at(limiter, "k", 0) == Allowed(1, 0, 10)
  assert rate_limit.check_at(limiter, "k", 9999) == Denied(1, 1)
  assert rate_limit.check_at(limiter, "k", 10_000) == Allowed(1, 0, 10)
}

pub fn fixed_window_handles_negative_clock_test() {
  // The BEAM monotonic clock usually starts negative.
  let limiter = rate_limit.fixed_window(limit: 5, per_seconds: 60)
  assert rate_limit.check_at(limiter, "k", -5000) == Allowed(5, 4, 5)
  // Same window until the boundary at zero.
  assert rate_limit.check_at(limiter, "k", -1) == Allowed(5, 3, 1)
  assert rate_limit.check_at(limiter, "k", 0) == Allowed(5, 4, 60)
}

pub fn fixed_window_keys_are_independent_test() {
  let limiter = rate_limit.fixed_window(limit: 1, per_seconds: 60)

  assert rate_limit.check_at(limiter, "a", 0) == Allowed(1, 0, 60)
  assert rate_limit.check_at(limiter, "a", 0) == Denied(1, 60)
  assert rate_limit.check_at(limiter, "b", 0) == Allowed(1, 0, 60)
}

// -- token bucket ------------------------------------------------------------

pub fn token_bucket_allows_burst_then_denies_test() {
  let limiter = rate_limit.token_bucket(capacity: 3, refill_per_second: 1)

  assert rate_limit.check_at(limiter, "k", 0) == Allowed(3, 2, 1)
  assert rate_limit.check_at(limiter, "k", 0) == Allowed(3, 1, 1)
  assert rate_limit.check_at(limiter, "k", 0) == Allowed(3, 0, 1)
  assert rate_limit.check_at(limiter, "k", 0) == Denied(3, 1)
}

pub fn token_bucket_refills_over_time_test() {
  let limiter = rate_limit.token_bucket(capacity: 2, refill_per_second: 1)

  assert rate_limit.check_at(limiter, "k", 0) == Allowed(2, 1, 1)
  assert rate_limit.check_at(limiter, "k", 0) == Allowed(2, 0, 1)
  assert rate_limit.check_at(limiter, "k", 0) == Denied(2, 1)
  // Half a second in: half a token, still short.
  assert rate_limit.check_at(limiter, "k", 500) == Denied(2, 1)
  // One full second since empty: exactly one token.
  assert rate_limit.check_at(limiter, "k", 1000) == Allowed(2, 0, 1)
  assert rate_limit.check_at(limiter, "k", 1000) == Denied(2, 1)
}

pub fn token_bucket_never_exceeds_capacity_test() {
  let limiter = rate_limit.token_bucket(capacity: 2, refill_per_second: 10)

  assert rate_limit.check_at(limiter, "k", 0) == Allowed(2, 1, 1)
  // A long wait refills, but only to capacity.
  assert rate_limit.check_at(limiter, "k", 60_000) == Allowed(2, 1, 1)
  assert rate_limit.check_at(limiter, "k", 60_000) == Allowed(2, 0, 1)
  assert rate_limit.check_at(limiter, "k", 60_000) == Denied(2, 1)
}

pub fn token_bucket_retry_after_reflects_shortfall_test() {
  // One token every 5 seconds.
  let limiter = rate_limit.token_bucket(capacity: 1, refill_per_second: 1)
  assert rate_limit.check_at(limiter, "k", 0) == Allowed(1, 0, 1)
  assert rate_limit.check_at(limiter, "k", 0) == Denied(1, 1)
  assert rate_limit.check_at(limiter, "k", 400) == Denied(1, 1)
}

pub fn concurrent_hits_are_counted_exactly_test() {
  // 50 processes each hit 20 times; exactly `limit` must be allowed.
  let limiter = rate_limit.fixed_window(limit: 100, per_seconds: 60)
  let results =
    list.repeat(Nil, 50)
    |> list.map(fn(_) {
      fn() {
        list.repeat(Nil, 20)
        |> list.count(fn(_) {
          case rate_limit.check_at(limiter, "k", 0) {
            Allowed(..) -> True
            Denied(..) | Saturated(..) -> False
          }
        })
      }
    })
    |> parallel
  assert list.fold(results, 0, fn(a, b) { a + b }) == 100
}

pub fn concurrent_token_bucket_never_over_allows_test() {
  let limiter = rate_limit.token_bucket(capacity: 25, refill_per_second: 1)
  let results =
    list.repeat(Nil, 50)
    |> list.map(fn(_) {
      fn() {
        list.repeat(Nil, 10)
        |> list.count(fn(_) {
          case rate_limit.check_at(limiter, "k", 0) {
            Allowed(..) -> True
            Denied(..) | Saturated(..) -> False
          }
        })
      }
    })
    |> parallel
  assert list.fold(results, 0, fn(a, b) { a + b }) == 25
}

pub fn concurrent_token_bucket_refills_exactly_once_test() {
  let limiter = rate_limit.token_bucket(capacity: 1, refill_per_second: 1)
  assert rate_limit.check_at(limiter, "k", 0) == Allowed(1, 0, 1)

  // Each round adds exactly one token. Every worker sees the same clock;
  // repeated rounds exercise both contention and repayment on the old code.
  use round <- list.each(
    list.index_map(list.repeat(Nil, 100), fn(_, i) { i + 1 }),
  )
  assert simultaneous_hits(limiter, round * 1000) == 1
}

pub fn concurrent_denials_preserve_fractional_refill_test() {
  let limiter = rate_limit.token_bucket(capacity: 1, refill_per_second: 1)
  assert rate_limit.check_at(limiter, "k", -1000) == Allowed(1, 0, 1)

  use round <- list.each(
    list.index_map(list.repeat(Nil, 20), fn(_, i) { i + 1 }),
  )
  let expected = case round % 4 == 0 {
    True -> 1
    False -> 0
  }
  assert simultaneous_hits(limiter, -1000 + round * 250) == expected
}

pub fn delayed_token_bucket_hit_does_not_reverse_time_test() {
  let limiter = rate_limit.token_bucket(capacity: 2, refill_per_second: 1)
  assert rate_limit.check_at(limiter, "k", -1000) == Allowed(2, 1, 1)
  assert rate_limit.check_at(limiter, "k", 0) == Allowed(2, 1, 1)
  // A request sampled its clock earlier but was scheduled after the last hit.
  assert rate_limit.check_at(limiter, "k", -1000) == Allowed(2, 0, 1)
  assert rate_limit.check_at(limiter, "k", 0) == Denied(2, 1)
  assert rate_limit.check_at(limiter, "k", 500) == Denied(2, 1)
  assert rate_limit.check_at(limiter, "k", 1000) == Allowed(2, 0, 1)
}

pub fn token_bucket_keys_are_literal_and_independent_test() {
  let limiter = rate_limit.token_bucket(capacity: 1, refill_per_second: 1)
  let keys = ["", "_", "$1", "雪", "ordinary"]
  use key <- list.each(keys)
  assert rate_limit.check_at(limiter, key, 0) == Allowed(1, 0, 1)
  assert rate_limit.check_at(limiter, key, 0) == Denied(1, 1)
  assert rate_limit.check_at(limiter, key, 1000) == Allowed(1, 0, 1)
  assert rate_limit.check_at(limiter, key, 1000) == Denied(1, 1)
}

// -- identity cap ------------------------------------------------------------

pub fn token_bucket_refuses_new_keys_at_cap_test() {
  let limiter =
    rate_limit.token_bucket(capacity: 1, refill_per_second: 1)
    |> rate_limit.max_identities(2)

  assert rate_limit.check_at(limiter, "a", 0) == Allowed(1, 0, 1)
  assert rate_limit.check_at(limiter, "b", 0) == Allowed(1, 0, 1)
  // Sweeps run every second for this limiter.
  assert rate_limit.check_at(limiter, "c", 0) == Saturated(1)
  // Tracked keys keep being limited while the table is full.
  assert rate_limit.check_at(limiter, "a", 0) == Denied(1, 1)
  assert rate_limit.check_at(limiter, "a", 1000) == Allowed(1, 0, 1)
  assert rate_limit.check_at(limiter, "c", 1000) == Saturated(1)
}

pub fn fixed_window_refuses_new_keys_at_cap_test() {
  let limiter =
    rate_limit.fixed_window(limit: 5, per_seconds: 60)
    |> rate_limit.max_identities(1)

  assert rate_limit.check_at(limiter, "a", 0) == Allowed(5, 4, 60)
  assert rate_limit.check_at(limiter, "b", 0) == Saturated(60)
  assert rate_limit.check_at(limiter, "a", 0) == Allowed(5, 3, 60)
}

pub fn max_identities_is_at_least_one_test() {
  let limiter =
    rate_limit.fixed_window(limit: 1, per_seconds: 60)
    |> rate_limit.max_identities(0)
  assert rate_limit.check_at(limiter, "a", 0) == Allowed(1, 0, 60)
  assert rate_limit.check_at(limiter, "b", 0) == Saturated(60)
}

pub fn long_keys_are_limited_like_any_other_test() {
  let limiter = rate_limit.token_bucket(capacity: 1, refill_per_second: 1)
  let key = string.repeat("k", 10_000)
  assert rate_limit.check_at(limiter, key, 0) == Allowed(1, 0, 1)
  assert rate_limit.check_at(limiter, key, 0) == Denied(1, 1)
  assert rate_limit.check_at(limiter, key <> "!", 0) == Allowed(1, 0, 1)
}

pub fn default_cap_admits_many_identities_test() {
  let limiter = rate_limit.fixed_window(limit: 1, per_seconds: 60)
  use i <- list.each(list.index_map(list.repeat(Nil, 5000), fn(_, i) { i }))
  assert rate_limit.check_at(limiter, int.to_string(i), 0) == Allowed(1, 0, 60)
}

fn simultaneous_hits(limiter: rate_limit.Limiter, time: Int) -> Int {
  list.repeat(Nil, 100)
  |> list.map(fn(_) { fn() { rate_limit.check_at(limiter, "k", time) } })
  |> parallel_at_once
  |> list.count(fn(decision) {
    case decision {
      Allowed(..) -> True
      Denied(..) | Saturated(..) -> False
    }
  })
}

@external(erlang, "howdy_test_ffi", "parallel_at_once")
fn parallel_at_once(tasks: List(fn() -> a)) -> List(a)

fn parallel(tasks: List(fn() -> a)) -> List(a) {
  let futures = list.map(tasks, spawn_task)
  list.map(futures, await)
}

@external(erlang, "howdy_test_ffi", "spawn_task")
fn spawn_task(task: fn() -> a) -> Future(a)

@external(erlang, "howdy_test_ffi", "await")
fn await(future: Future(a)) -> a

type Future(a)

// -- middleware --------------------------------------------------------------

fn handler(ctx: Context) {
  controller.text(ctx, "ok")
}

/// An app with `handler` mounted at `/`.
fn app(handler: controller.Handler) -> howdy.App {
  howdy.new()
  |> howdy.controller(controller.new("/") |> controller.get("/", handler))
}

fn send(app: howdy.App, headers: List(#(String, String))) {
  list.fold(headers, testing.get("/"), fn(req, h) {
    testing.header(req, h.0, h.1)
  })
  |> testing.send(app)
}

pub fn by_header_test() {
  let limiter = rate_limit.fixed_window(limit: 2, per_seconds: 60)
  let app =
    app(controller.wrap(handler, rate_limit.by_header(limiter, "x-api-key")))

  let res = send(app, [#("x-api-key", "a")])
  assert res.status == 200
  assert response.get_header(res, "x-ratelimit-limit") == Ok("2")
  assert response.get_header(res, "x-ratelimit-remaining") == Ok("1")
  assert response.get_header(res, "x-ratelimit-reset") != Error(Nil)

  let res = send(app, [#("x-api-key", "a")])
  assert response.get_header(res, "x-ratelimit-remaining") == Ok("0")

  let res = send(app, [#("x-api-key", "a")])
  assert res.status == 429
  assert testing.error(res) == Ok("too many requests")
  assert response.get_header(res, "retry-after") != Error(Nil)
  assert response.get_header(res, "x-ratelimit-remaining") == Ok("0")

  // A different key has its own budget.
  assert send(app, [#("x-api-key", "b")]).status == 200
}

pub fn saturated_limiter_responds_429_with_marker_test() {
  let limiter =
    rate_limit.fixed_window(limit: 2, per_seconds: 60)
    |> rate_limit.max_identities(1)
  let app =
    app(controller.wrap(handler, rate_limit.by_header(limiter, "x-api-key")))

  assert send(app, [#("x-api-key", "a")]).status == 200

  let res = send(app, [#("x-api-key", "b")])
  assert res.status == 429
  assert testing.error(res) == Ok("too many requests")
  assert response.get_header(res, "retry-after") == Ok("60")
  assert response.get_header(res, "x-ratelimit-saturated") == Ok("true")
  assert response.get_header(res, "x-ratelimit-limit") == Error(Nil)

  // The tracked key is unaffected by the refused one.
  let res = send(app, [#("x-api-key", "a")])
  assert res.status == 200
  assert response.get_header(res, "x-ratelimit-remaining") == Ok("0")
}

pub fn by_header_skips_requests_without_header_test() {
  let limiter = rate_limit.fixed_window(limit: 1, per_seconds: 60)
  let app =
    app(controller.wrap(handler, rate_limit.by_header(limiter, "x-api-key")))

  assert send(app, []).status == 200
  assert send(app, []).status == 200
  assert response.get_header(send(app, []), "x-ratelimit-limit") == Error(Nil)
}

pub fn by_ip_test() {
  let limiter = rate_limit.fixed_window(limit: 1, per_seconds: 60)
  let app = app(handler) |> howdy.middleware(rate_limit.by_ip(limiter))
  let from = fn(ip) {
    testing.get("/") |> testing.from_ip(ip) |> testing.send(app)
  }

  assert from("10.0.0.1").status == 200
  assert from("10.0.0.1").status == 429
  assert from("10.0.0.2").status == 200

  // Without a client address there is nothing to count.
  assert send(app, []).status == 200
  assert send(app, []).status == 200
  assert response.get_header(send(app, []), "x-ratelimit-limit") == Error(Nil)
}

pub fn by_custom_key_test() {
  let limiter = rate_limit.fixed_window(limit: 1, per_seconds: 60)
  let limited =
    controller.wrap(
      handler,
      rate_limit.by(limiter, fn(ctx) {
        case ctx.request.path {
          "/free" -> None
          path -> Some(path)
        }
      }),
    )
  let app =
    howdy.new()
    |> howdy.controller(
      controller.new("/")
      |> controller.get("/free", limited)
      |> controller.get("/paid", limited),
    )
  let at = fn(path) { testing.get(path) |> testing.send(app) }

  assert at("/free").status == 200
  assert at("/free").status == 200
  assert at("/paid").status == 200
  assert at("/paid").status == 429
}

pub fn innermost_limiter_headers_win_test() {
  let outer = rate_limit.fixed_window(limit: 100, per_seconds: 60)
  let inner = rate_limit.fixed_window(limit: 1, per_seconds: 60)
  let app =
    handler
    |> controller.wrap(rate_limit.by_header(inner, "x-api-key"))
    |> controller.wrap(rate_limit.by_header(outer, "x-api-key"))
    |> app

  let res = send(app, [#("x-api-key", "a")])
  assert response.get_header(res, "x-ratelimit-limit") == Ok("1")
  assert response.get_header(res, "x-ratelimit-remaining") == Ok("0")

  let res = send(app, [#("x-api-key", "a")])
  assert res.status == 429
  assert response.get_header(res, "x-ratelimit-limit") == Ok("1")
  assert response.get_header(res, "x-ratelimit-remaining") == Ok("0")
}

pub fn service_can_return_too_many_requests_test() {
  let ctx =
    Context(
      request: testing.get("/"),
      params: dict.new(),
      guard: Nil,
      version: None,
    )
  let res =
    service.respond(Error(service.TooManyRequests(30)), ctx, fn(_) {
      panic as "nothing to encode"
    })
  assert res.status == 429
  assert response.get_header(res, "retry-after") == Ok("30")
}

// -- shared ------------------------------------------------------------------

type Count {
  Increment(key: String, window: Int, reply: process.Subject(Int))
}

/// One store two "nodes" share, holding the store contract: a newer window
/// resets a key, an older one counts against the newer.
fn memory_store() -> rate_limit.Store {
  let assert Ok(started) =
    actor.new(dict.new())
    |> actor.on_message(fn(counts, message: Count) {
      let #(window, hits) = case dict.get(counts, message.key) {
        Ok(#(held, hits)) if held >= message.window -> #(held, hits + 1)
        _ -> #(message.window, 1)
      }
      process.send(message.reply, hits)
      actor.continue(dict.insert(counts, message.key, #(window, hits)))
    })
    |> actor.start
  rate_limit.Store(fn(key, window, _expires_at) {
    Ok(process.call(started.data, 1000, Increment(key, window, _)))
  })
}

pub fn shared_limiters_on_two_nodes_count_together_test() {
  let store = memory_store()
  let first = rate_limit.shared(limit: 3, per_seconds: 60, name: "api", store:)
  let second = rate_limit.shared(limit: 3, per_seconds: 60, name: "api", store:)
  let t = 1_800_000_000_000
  assert rate_limit.check_at(first, "ip", t)
    == Allowed(limit: 3, remaining: 2, reset_seconds: 60)
  assert rate_limit.check_at(second, "ip", t + 1000)
    == Allowed(limit: 3, remaining: 1, reset_seconds: 59)
  let assert Allowed(remaining: 0, ..) =
    rate_limit.check_at(first, "ip", t + 2000)
  assert rate_limit.check_at(second, "ip", t + 3000)
    == Denied(limit: 3, retry_after_seconds: 57)
  // Other keys, and other limiters on the same store, count apart.
  let assert Allowed(remaining: 2, ..) = rate_limit.check_at(second, "other", t)
  let other = rate_limit.shared(limit: 3, per_seconds: 60, name: "web", store:)
  let assert Allowed(remaining: 2, ..) = rate_limit.check_at(other, "ip", t)
  // The next window starts over.
  let assert Allowed(remaining: 2, ..) =
    rate_limit.check_at(first, "ip", t + 60_000)
}

pub fn a_failing_shared_store_allows_requests_test() {
  let broken = rate_limit.Store(fn(_, _, _) { Error(Nil) })
  let limiter =
    rate_limit.shared(limit: 1, per_seconds: 60, name: "api", store: broken)
  let assert Allowed(limit: 1, remaining: 1, ..) =
    rate_limit.check(limiter, "ip")
  let assert Allowed(..) = rate_limit.check(limiter, "ip")
}

@external(erlang, "howdy_ffi", "warn_at_most_every")
fn warn_at_most_every(key: String, interval_ms: Int) -> Bool

// A store outage is logged once per window, not once per request.
pub fn store_failure_warnings_are_throttled_test() {
  assert warn_at_most_every("throttle-test", 60_000)
  assert !warn_at_most_every("throttle-test", 60_000)
  assert !warn_at_most_every("throttle-test", 60_000)
  // Another limiter has its own window.
  assert warn_at_most_every("throttle-test-other", 60_000)
}
