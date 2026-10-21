//// What auth adds to traces: a span per sign-in step, the user on the
//// request's span, and audit events as span events. Never credentials.

import gleam/list
import gleam/option.{Some}
import gleam/string
import howdy/auth
import howdy/auth/secret
import howdy/auth/user
import howdy/service
import howdy/telemetry
import howdy/telemetry/recorder
import howdy/trace
import support.{fixture, signup}

const password = "an uncommon orchard phrase 947!"

fn recording() -> recorder.Recorder {
  let recorder = recorder.new(keep: 50)
  let assert Ok(Nil) =
    telemetry.new("howdy-auth-test")
    |> telemetry.record(recorder)
    |> telemetry.start
  recorder
}

fn spans_of(recorder: recorder.Recorder, trace_id: String) {
  let assert Ok(spans) = recorder.trace(recorder, trace_id)
  spans
}

fn named(spans: List(recorder.Span), name: String) -> recorder.Span {
  let assert Ok(span) = list.find(spans, fn(span) { span.name == name })
  span
}

pub fn sign_in_steps_are_spans_without_credentials_test() {
  use _database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let assert Ok(Nil) = auth.set_password(identity, principal, password)
  let recorder = recording()

  let #(trace_id, token) = {
    use <- trace.span("request", [])
    let assert Error(service.Unauthorized) =
      auth.login_password(identity, "ada@example.com", "wrong password")
    let assert Ok(login) =
      auth.login_password(identity, "ada@example.com", password)
    let assert Ok(_) = auth.authenticate(identity, secret.reveal(login.token))
    let assert Some(id) = trace.trace_id()
    #(id, secret.reveal(login.token))
  }
  telemetry.stop()

  let spans = spans_of(recorder, trace_id)
  let assert [refused, accepted] =
    list.filter(spans, fn(span) { span.name == "auth.login_password" })
  assert recorder.attribute(refused, "auth.refused")
    == Some(recorder.Integer(401))
  assert refused.status == recorder.Unset
  assert recorder.attribute(accepted, "auth.refused") == option.None
  let request = named(spans, "request")
  assert recorder.attribute(request, "enduser.id")
    == Some(recorder.Text(session.user.id))

  let recorded =
    list.flat_map(spans, fn(span) {
      list.map(span.attributes, fn(pair) { recorder.value_to_string(pair.1) })
    })
  assert !list.any(recorded, string.contains(_, "ada@example.com"))
  assert !list.any(recorded, string.contains(_, password))
  assert !list.any(recorded, string.contains(_, token))
}

pub fn audit_events_are_span_events_test() {
  use _database, identity, _, mailbox <- fixture
  let session = signup(identity, mailbox, "ada@example.com")
  let recorder = recording()
  let trace_id = {
    use <- trace.span("request", [])
    let assert Ok(principal) =
      auth.authenticate(identity, secret.reveal(session.token))
    let assert Ok(Nil) =
      auth.revoke_sessions(
        identity,
        principal.user.id,
        by: user.Acting(principal),
      )
    let assert Some(id) = trace.trace_id()
    id
  }
  telemetry.stop()
  // The event lands on the innermost span, here the transaction it was
  // written in.
  let events =
    list.flat_map(spans_of(recorder, trace_id), fn(span) { span.events })
  let assert Ok(event) =
    list.find(events, fn(event) { event.name == "sessions.revoked" })
  assert list.key_find(event.attributes, "enduser.id")
    == Ok(recorder.Text(session.user.id))
}
