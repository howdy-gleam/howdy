import gleam/option.{None, Some}
import gleam/string
import howdy/mail
import howdy/mail/smtp

type Server

@external(erlang, "howdy_mail_test_ffi", "start_smtp")
fn start_smtp(auth: Bool) -> Server

@external(erlang, "howdy_mail_test_ffi", "stop_smtp")
fn stop_smtp(server: Server) -> Nil

@external(erlang, "howdy_mail_test_ffi", "smtp_port")
fn smtp_port(server: Server) -> Int

@external(erlang, "howdy_mail_test_ffi", "attempts")
fn attempts(server: Server) -> Int

@external(erlang, "howdy_mail_test_ffi", "monotonic_ms")
fn now() -> Int

@external(erlang, "howdy_mail_test_ffi", "received")
fn received(timeout: Int) -> Result(#(String, List(String), String), Nil)

@external(erlang, "howdy_mail_test_ffi", "closed_port")
fn closed_port() -> Int

@external(erlang, "howdy_mail_test_ffi", "mime_header")
fn header(data: String, name: String) -> Result(String, Nil)

fn mailer(config: smtp.Config) -> mail.Mailer {
  mail.mailer(smtp.adapter(config))
  |> mail.default_from(mail.named("Acme", "hello@acme.test"))
}

fn message() -> mail.Message {
  mail.message()
  |> mail.to([mail.named("Mike", "mike@example.com")])
  |> mail.bcc([mail.address("audit@acme.test")])
  |> mail.subject("Your code")
  |> mail.text(".starts with a dot\nthen 123456")
}

pub fn from_url_test() {
  let assert Ok(config) =
    smtp.from_url("smtps://user%40acme.test:p%3Ass@smtp.acme.test")
  assert smtp.host(config) == "smtp.acme.test"
  assert smtp.port_of(config) == 465
  assert smtp.tls_of(config) == smtp.ImplicitTls(verify: True)
  assert smtp.username(config) == Some("user@acme.test")

  let assert Ok(config) = smtp.from_url("smtp://smtp.acme.test")
  assert smtp.port_of(config) == 587
  assert smtp.tls_of(config) == smtp.StartTls(verify: True)
  assert smtp.username(config) == None

  let assert Ok(config) = smtp.from_url("smtp://localhost:1025")
  assert smtp.port_of(config) == 1025
  assert smtp.tls_of(config) == smtp.NoTls
  let assert Ok(config) = smtp.from_url("smtp://mailpit:1025")
  assert smtp.tls_of(config) == smtp.NoTls
  let assert Ok(config) = smtp.from_url("smtp://127.0.0.1:1025?tls=starttls")
  assert smtp.tls_of(config) == smtp.StartTls(verify: True)

  assert smtp.from_url("http://smtp.acme.test") == Error(smtp.InvalidUrl)
  assert smtp.from_url("smtp://") == Error(smtp.InvalidUrl)
  assert smtp.from_url("smtp://a.b/path") == Error(smtp.InvalidUrl)
  assert smtp.from_url("smtp://a.b?tls=maybe")
    == Error(smtp.UnsupportedTls("maybe"))
}

pub fn sends_through_the_server_test() {
  let server = start_smtp(False)
  let config = smtp.new("127.0.0.1") |> smtp.port(smtp_port(server))
  let assert Ok(receipt) = mail.send(mailer(config), message())
  assert receipt.provider_id == Some("TEST123")
  let assert Ok(#(from, to, data)) = received(1000)
  assert from == "hello@acme.test"
  assert to == ["mike@example.com", "audit@acme.test"]
  assert header(data, "To") == Ok("Mike <mike@example.com>")
  assert header(data, "Bcc") == Error(Nil)
  // Dot-stuffing was undone by the server; the body is intact.
  assert string.contains(data, "\r\n.starts with a dot")
  stop_smtp(server)
}

pub fn authenticates_test() {
  let server = start_smtp(True)
  let config =
    smtp.new("127.0.0.1")
    |> smtp.port(smtp_port(server))
    |> smtp.credentials(username: "user@example.com", password: "s3cret")
  let assert Ok(_) = mail.send(mailer(config), message())
  let assert Ok(_) = received(1000)

  let wrong =
    config |> smtp.credentials(username: "user@example.com", password: "nope")
  let assert Error(mail.Refused(reason)) = mail.send(mailer(wrong), message())
  assert string.contains(reason, "authentication")
  stop_smtp(server)
}

pub fn refused_and_temporary_recipients_test() {
  let server = start_smtp(False)
  let config = smtp.new("127.0.0.1") |> smtp.port(smtp_port(server))
  let assert Error(mail.Refused(reason)) =
    mail.send(
      mailer(config),
      message() |> mail.to([mail.address("refused@example.com")]),
    )
  assert string.contains(reason, "550")
  let assert Error(mail.Unavailable(reason)) =
    mail.send(
      mailer(config),
      message() |> mail.to([mail.address("later@example.com")]),
    )
  assert string.contains(reason, "451")
  assert received(100) == Error(Nil)
  stop_smtp(server)
}

pub fn temporary_failures_are_retried_when_asked_test() {
  let server = start_smtp(False)
  let flaky = message() |> mail.to([mail.address("flaky@example.com")])
  let config = smtp.new("127.0.0.1") |> smtp.port(smtp_port(server))
  // Without retries, the first attempt's answer is the answer.
  let assert Error(mail.Unavailable(_)) = mail.send(mailer(config), flaky)
  assert attempts(server) == 1
  stop_smtp(server)

  let server = start_smtp(False)
  let config =
    smtp.new("127.0.0.1")
    |> smtp.port(smtp_port(server))
    |> smtp.retries(2)
    |> smtp.backoff(50)
  let assert Ok(_) = mail.send(mailer(config), flaky)
  assert attempts(server) == 2
  let assert Ok(_) = received(1000)
  stop_smtp(server)
}

pub fn retries_back_off_and_give_up_test() {
  let server = start_smtp(False)
  let config =
    smtp.new("127.0.0.1")
    |> smtp.port(smtp_port(server))
    |> smtp.retries(2)
    |> smtp.backoff(100)
  let started = now()
  let assert Error(mail.Unavailable(reason)) =
    mail.send(
      mailer(config),
      message() |> mail.to([mail.address("later@example.com")]),
    )
  assert string.contains(reason, "451")
  assert attempts(server) == 3
  // 100ms before the second attempt, 200ms before the third.
  assert now() - started >= 300
  assert received(100) == Error(Nil)
  stop_smtp(server)
}

pub fn refusals_are_not_retried_test() {
  let server = start_smtp(False)
  let config =
    smtp.new("127.0.0.1")
    |> smtp.port(smtp_port(server))
    |> smtp.retries(3)
    |> smtp.backoff(10)
  let assert Error(mail.Refused(_)) =
    mail.send(
      mailer(config),
      message() |> mail.to([mail.address("refused@example.com")]),
    )
  assert attempts(server) == 1
  stop_smtp(server)
}

pub fn required_starttls_is_not_skipped_test() {
  let server = start_smtp(False)
  let config =
    smtp.new("127.0.0.1")
    |> smtp.port(smtp_port(server))
    |> smtp.tls(smtp.StartTls(verify: True))
  let assert Error(mail.Refused(reason)) = mail.send(mailer(config), message())
  assert string.contains(reason, "STARTTLS")
  assert received(100) == Error(Nil)
  stop_smtp(server)
}

pub fn unreachable_server_test() {
  let config =
    smtp.new("127.0.0.1") |> smtp.port(closed_port()) |> smtp.timeout(1000)
  let assert Error(mail.Unavailable(reason)) =
    mail.send(mailer(config), message())
  assert string.contains(reason, "econnrefused")
}

pub fn from_env_treats_an_empty_variable_as_unset_test() {
  unsetenv("SMTP_URL")
  assert smtp.from_env() == Error(smtp.MissingUrl("SMTP_URL"))
  putenv("SMTP_URL", "")
  assert smtp.from_env() == Error(smtp.MissingUrl("SMTP_URL"))
  putenv("SMTP_URL", "smtp://mailpit:1025")
  let assert Ok(config) = smtp.from_env()
  assert smtp.host(config) == "mailpit"
  assert smtp.port_of(config) == 1025
  unsetenv("SMTP_URL")
}

@external(erlang, "howdy_mail_test_ffi", "putenv")
fn putenv(name: String, value: String) -> Nil

@external(erlang, "howdy_mail_test_ffi", "unsetenv")
fn unsetenv(name: String) -> Nil
