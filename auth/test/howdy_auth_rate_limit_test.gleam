import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/time/timestamp
import howdy
import howdy/auth
import howdy/auth/routes
import howdy/rate_limit
import howdy/testing
import support.{count, exec, fixture}

/// A node serving the auth API, with every request from one client.
fn node(identity: auth.Auth) -> howdy.App {
  howdy.new()
  |> howdy.controller(
    routes.api_limited_by(identity, at: "/api/auth", key: fn(_) {
      Some("203.0.113.9")
    }),
  )
}

/// Windows follow the clock's minutes, so a run that crossed one would see
/// its count reset partway through and prove nothing. Instead of sleeping
/// clear of the boundary, `run` is repeated when the minute changed under it;
/// it must start from a clean count each time.
fn within_one_window(run: fn() -> a) -> a {
  let started = minute()
  let outcome = run()
  case minute() == started {
    True -> outcome
    False -> within_one_window(run)
  }
}

fn minute() -> Int {
  let #(seconds, _) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  seconds / 60
}

fn attempt(app: howdy.App) -> Int {
  testing.post(
    "/api/auth/token",
    json.object([#("token", json.string("not-a-real-token"))]),
  )
  |> testing.send(app)
  |> fn(answer) { answer.status }
}

pub fn nodes_share_the_per_client_limit_test() {
  use database, identity, _, _ <- fixture
  let identity = auth.with_shared_rate_limits(identity)
  let #(statuses, first_after, second_after) =
    within_one_window(fn() {
      exec(database, "DELETE FROM howdy_auth_rate_limits")
      // Two nodes, as behind a load balancer: same database, separate
      // processes' worth of limiters.
      let first = node(identity)
      let second = node(identity)
      let statuses =
        list.repeat(Nil, routes.credential_limit)
        |> list.index_map(fn(_, i) {
          case i % 2 {
            0 -> attempt(first)
            _ -> attempt(second)
          }
        })
      #(statuses, attempt(first), attempt(second))
    })
  assert list.all(statuses, fn(status) { status == 401 })
  assert first_after == 429
  assert second_after == 429
  // Clients are stored only as digests.
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_rate_limits WHERE key LIKE '%203.0.113.9%'",
    )
    == 0
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_rate_limits") == 1
}

pub fn unshared_nodes_count_apart_test() {
  use _, identity, _, _ <- fixture
  let #(statuses, first_after, second_after) =
    within_one_window(fn() {
      // Fresh nodes each time: an unshared limiter's count lives in the node.
      let first = node(identity)
      let second = node(identity)
      let statuses =
        list.map(list.repeat(Nil, routes.credential_limit), fn(_) {
          attempt(first)
        })
      #(statuses, attempt(first), attempt(second))
    })
  assert list.all(statuses, fn(status) { status == 401 })
  assert first_after == 429
  assert second_after == 401
}

pub fn concurrent_hits_are_all_counted_test() {
  use database, identity, _, _ <- fixture
  let store = auth.rate_limit_store(identity)
  let limiter =
    rate_limit.shared(limit: 1000, per_seconds: 60, name: "app.test", store:)
  let #(decisions, last) =
    within_one_window(fn() {
      exec(database, "DELETE FROM howdy_auth_rate_limits")
      let done = process.new_subject()
      list.each(list.repeat(Nil, 40), fn(_) {
        process.spawn(fn() {
          process.send(done, rate_limit.check(limiter, "client"))
        })
      })
      let decisions =
        list.map(list.repeat(Nil, 40), fn(_) {
          let assert Ok(decision) = process.receive(done, 5000)
          decision
        })
      #(decisions, rate_limit.check(limiter, "client"))
    })
  list.each(decisions, fn(decision) {
    let assert rate_limit.Allowed(..) = decision
  })
  let assert rate_limit.Allowed(remaining:, ..) = last
  assert remaining == 1000 - 41
}

pub fn prune_expired_clears_old_windows_test() {
  use database, identity, _, _ <- fixture
  let identity = auth.with_shared_rate_limits(identity)
  let _ = attempt(node(identity))
  exec(
    database,
    "INSERT INTO howdy_auth_rate_limits(key, window_start, hits, expires_at) VALUES ('old', 1, 5, 1000)",
  )
  let assert Ok(Nil) = auth.prune_expired(identity)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_rate_limits") == 1
}
