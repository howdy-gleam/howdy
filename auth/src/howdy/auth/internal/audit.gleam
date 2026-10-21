//// Audit events and sign-in spans, shared by every flow. `howdy/auth` is the
//// public face; it re-exports `event` and `event_from` for the package's
//// other modules.

import gloo/repo.{type Repo}
import howdy/auth/internal/store
import howdy/auth/user.{type Actor}
import howdy/service
import howdy/trace

/// Record an audit event on the caller's connection, so it commits or rolls
/// back with the change it describes. The client is taken from the actor,
/// which for `Acting` is the principal's own request.
pub fn event(
  conn: Repo,
  user_id: String,
  action: String,
  actor: Actor,
  detail: String,
) -> service.Result(Nil) {
  event_from(conn, user_id, action, actor, detail, user.actor_client(actor))
}

/// As `event`, for the self-service flows that know the request's client
/// before there is a principal to carry it.
pub fn event_from(
  conn: Repo,
  user_id: String,
  action: String,
  actor: Actor,
  detail: String,
  client: String,
) -> service.Result(Nil) {
  trace.event(action, [
    trace.string("enduser.id", user_id),
    trace.string("auth.actor_id", user.actor_id(actor)),
  ])
  store.insert_event(
    conn,
    user_id:,
    action:,
    actor_id: user.actor_id(actor),
    detail:,
    client:,
  )
}

/// Run a sign-in step in a span. Refusing a sign-in is the step working, so
/// the span only fails for an `Internal` error; any other error's status
/// code is recorded as `auth.refused`. Emails, passwords and tokens are
/// never recorded.
pub fn traced(
  name: String,
  attributes: List(trace.Attribute),
  run: fn() -> service.Result(a),
) -> service.Result(a) {
  use <- trace.span(name, attributes)
  let outcome = run()
  case outcome {
    Ok(_) -> Nil
    Error(service.Internal(_)) -> trace.set_error("internal error")
    Error(error) ->
      trace.set_attributes([
        trace.int("auth.refused", service.status_code(error)),
      ])
  }
  outcome
}
