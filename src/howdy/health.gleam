//// A health check for load balancers, container platforms and uptime
//// monitors. Mount it with `howdy.health_check`:
////
//// ```gleam
//// howdy.new()
//// |> howdy.controller(pages())
//// |> howdy.health_check(health.new())
//// ```
////
//// `GET /up` then answers `200` with `{"status":"ok"}` while the app is
//// running. It is answered before routing and before any middleware, so
//// rate limits, guards, CSRF checks and redirects cannot turn it away, and
//// the request logger and tracing leave it out, so a probe every few seconds
//// does not fill the logs.
////
//// Add checks for what the app cannot serve without, such as its database.
//// They run at the same time, and any that fails or runs out of time turns
//// the answer into a `503`:
////
//// ```gleam
//// health.new()
//// |> health.check("database", database.health_check(db))
//// ```

import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/string
import howdy/content.{type Content}
import howdy/context.{type Body}
import logging

/// Where the health check answers, and what it checks.
pub opaque type Health {
  Health(
    path: String,
    checks: List(#(String, fn() -> Result(Nil, String))),
    timeout: Int,
  )
}

/// A health check at `/up` with no checks: it answers `200` whenever the
/// app is running and accepting connections.
pub fn new() -> Health {
  Health(path: "/up", checks: [], timeout: 1000)
}

/// Answer at another path, such as `/healthz`. The path must start with `/`
/// and is matched exactly. A route of the app's own at the same path is
/// never reached by `GET` or `HEAD`.
pub fn at(health: Health, path path: String) -> Health {
  case string.starts_with(path, "/") {
    True -> Health(..health, path:)
    False -> panic as "howdy/health: the path must start with /"
  }
}

/// Add a check. `run` returns `Ok(Nil)` when what it checks is usable, or
/// an `Error` with the reason it is not. The reason is logged, at most once
/// every ten seconds per check, and never sent to the client: the response
/// only says which checks failed, by name.
///
/// A check that crashes counts as failed. One still running after the
/// timeout is stopped and counts as failed too, so keep checks quick and
/// cheap, such as a `SELECT 1`. Names must be unique.
pub fn check(
  health: Health,
  named name: String,
  run run: fn() -> Result(Nil, String),
) -> Health {
  case list.key_find(health.checks, name) {
    Ok(_) -> panic as { "howdy/health: two checks are named " <> name }
    Error(Nil) ->
      Health(..health, checks: list.append(health.checks, [#(name, run)]))
  }
}

/// How long the checks get, all together, in milliseconds. One second by
/// default. Keep it below the prober's own timeout, such as a Kubernetes
/// probe's `timeoutSeconds`, or the prober gives up first.
pub fn timeout(health: Health, milliseconds: Int) -> Health {
  Health(..health, timeout: milliseconds)
}

/// The health check's response when `request` is a `GET` or `HEAD` of its
/// path, or `Error(Nil)` for any other request.
@internal
pub fn answer(
  health: Health,
  request: Request(Body),
) -> Result(Response(Content), Nil) {
  case request.method, request.path == health.path {
    http.Get, True | http.Head, True -> Ok(respond(health))
    _, _ -> Error(Nil)
  }
}

fn respond(health: Health) -> Response(Content) {
  let outcomes = case health.checks {
    [] -> []
    checks ->
      run_all(list.map(checks, fn(check) { check.1 }), health.timeout)
      |> list.zip(checks, _)
      |> list.map(fn(pair) {
        let #(#(name, _), outcome) = pair
        #(name, report(name, outcome))
      })
  }
  let healthy = list.all(outcomes, fn(outcome) { outcome.1 == "ok" })
  let fields = [
    #(
      "status",
      json.string(case healthy {
        True -> "ok"
        False -> "error"
      }),
    ),
    ..case outcomes {
      [] -> []
      _ -> [
        #(
          "checks",
          json.object(
            list.map(outcomes, fn(outcome) {
              #(outcome.0, json.string(outcome.1))
            }),
          ),
        ),
      ]
    }
  ]
  response.new(case healthy {
    True -> 200
    False -> 503
  })
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_header("cache-control", "no-store")
  |> response.set_body(content.Text(json.to_string(json.object(fields))))
}

/// The check's status in the response, logging why it failed.
fn report(name: String, outcome: Result(Result(Nil, String), Nil)) -> String {
  let #(status, reason) = case outcome {
    Ok(Ok(Nil)) -> #("ok", "")
    Ok(Error(reason)) -> #("error", reason)
    Error(Nil) -> #("timeout", "it did not finish in time")
  }
  case status != "ok" && warn_at_most_every("health:" <> name, 10_000) {
    True ->
      logging.log(
        logging.Warning,
        "health check " <> name <> " failed: " <> reason,
      )
    False -> Nil
  }
  status
}

/// Run every check in a process of its own, all at once, and wait at most
/// `timeout` for them: each is `Ok` with its result, or `Error(Nil)` if it
/// had not finished.
@external(erlang, "howdy_health_ffi", "run_all")
fn run_all(
  checks: List(fn() -> Result(Nil, String)),
  timeout: Int,
) -> List(Result(Result(Nil, String), Nil))

@external(erlang, "howdy_ffi", "warn_at_most_every")
fn warn_at_most_every(key: String, interval_ms: Int) -> Bool
