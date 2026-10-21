import gleam/list
import gleam/option.{None, Some}
import howdy/mail
import howdy/telemetry
import howdy/telemetry/recorder

fn recording() -> recorder.Recorder {
  let recorder = recorder.new(keep: 10)
  let assert Ok(Nil) =
    telemetry.new("howdy-mail-test")
    |> telemetry.record(recorder)
    |> telemetry.start
  recorder
}

fn mailer(result: Result(Nil, mail.Error)) -> mail.Mailer {
  mail.adapter(named: "capture", send: fn(outgoing: mail.Outgoing) {
    case result {
      Ok(Nil) -> Ok(mail.Receipt(outgoing.id, None))
      Error(error) -> Error(error)
    }
  })
  |> mail.mailer
  |> mail.default_from(mail.address("hello@acme.test"))
}

fn message() -> mail.Message {
  mail.message()
  |> mail.to([mail.address("mike@example.com")])
  |> mail.subject("Your secret code")
  |> mail.text("Hello")
  |> mail.tag("welcome")
}

fn only_span(recorder: recorder.Recorder) -> recorder.Span {
  let assert [trace] = recorder.traces(recorder, limit: 5)
  trace.root
}

pub fn sending_is_a_span_without_addresses_test() {
  let recorder = recording()
  let assert Ok(receipt) = mail.send(mailer(Ok(Nil)), message())
  telemetry.stop()
  let span = only_span(recorder)
  assert span.name == "mail.send"
  assert recorder.attribute(span, "mail.adapter")
    == Some(recorder.Text("capture"))
  assert recorder.attribute(span, "mail.recipients")
    == Some(recorder.Integer(1))
  assert recorder.attribute(span, "mail.id") == Some(recorder.Text(receipt.id))
  assert recorder.attribute(span, "mail.tags")
    == Some(recorder.Many([recorder.Text("welcome")]))
  let texts =
    list.map(span.attributes, fn(pair) { recorder.value_to_string(pair.1) })
  assert !list.contains(texts, "mike@example.com")
  assert !list.contains(texts, "Your secret code")
}

pub fn a_refused_message_fails_the_span_test() {
  let recorder = recording()
  let assert Error(_) =
    mail.send(
      mailer(Error(mail.Refused("mike@example.com rejected"))),
      message(),
    )
  telemetry.stop()
  let span = only_span(recorder)
  assert span.status == recorder.Failed("mail refused")
  assert recorder.attribute(span, "error.type")
    == Some(recorder.Text("refused"))
}
