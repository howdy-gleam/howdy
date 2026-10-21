//// A `rate_limit.Store` in the auth database, so every node shares counts.

import gleam/dynamic/decode
import gleam/int
import gleam/result
import gloo/repo.{type Repo}
import gloo/sql
import howdy/auth/internal/database as db
import howdy/auth/internal/token
import howdy/rate_limit
import howdy/service

pub fn new(repo: Repo) -> rate_limit.Store {
  rate_limit.Store(fn(key, window, expires_at) {
    {
      use conn <- db.connect(repo)
      // Rows are only read by their own key, so stale ones cost space, not
      // correctness; clearing them on a small share of hits bounds that.
      use _ <- result.try(case int.random(256) {
        0 -> delete_expired(conn, token.now() * 1000)
        _ -> Ok(Nil)
      })
      hit(conn, token.digest(key), window, expires_at)
    }
    |> result.replace_error(Nil)
  })
}

/// A newer window starts the count over; an older one, from a node whose
/// clock is behind, counts against the newer rather than resetting it.
fn hit(
  conn: Repo,
  key: String,
  window: Int,
  expires_at: Int,
) -> service.Result(Int) {
  use rows <- result.try(db.query(
    conn,
    "INSERT INTO howdy_auth_rate_limits(key, window_start, hits, expires_at) VALUES ($1, $2, 1, $3) ON CONFLICT(key) DO UPDATE SET hits = CASE WHEN excluded.window_start > howdy_auth_rate_limits.window_start THEN 1 ELSE howdy_auth_rate_limits.hits + 1 END, window_start = CASE WHEN excluded.window_start > howdy_auth_rate_limits.window_start THEN excluded.window_start ELSE howdy_auth_rate_limits.window_start END, expires_at = CASE WHEN excluded.window_start > howdy_auth_rate_limits.window_start THEN excluded.expires_at ELSE howdy_auth_rate_limits.expires_at END RETURNING hits",
    [sql.string(key), sql.int(window), sql.int(expires_at)],
    decode.field(0, decode.int, decode.success),
  ))
  case rows {
    [hits] -> Ok(hits)
    _ -> Error(service.Internal("rate limit update returned no count"))
  }
}

pub fn delete_expired(conn: Repo, now_ms: Int) -> service.Result(Nil) {
  db.execute(conn, "DELETE FROM howdy_auth_rate_limits WHERE expires_at <= $1", [
    sql.int(now_ms),
  ])
}
