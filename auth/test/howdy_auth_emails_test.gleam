//// The ready-made auth emails, sent through a howdy/mail outbox.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import howdy/auth
import howdy/auth/emails
import howdy/auth/secret
import howdy/auth/user
import howdy/mail
import howdy/mail/outbox
import howdy/mail/preview
import howdy/migration
import support.{with_repo}

fn mailer(box: outbox.Outbox) -> mail.Mailer {
  mail.mailer(outbox.adapter(box))
  |> mail.default_from(mail.named("Acme", "hello@acme.test"))
}

fn delivery(purpose: auth.Purpose) -> auth.Delivery {
  auth.Delivery(
    email: "ada@example.com",
    token: secret.wrap("tok-123"),
    purpose:,
    link: None,
    code: None,
    locale: None,
  )
}

pub fn sends_to_the_delivery_address_with_a_tag_test() {
  let box = outbox.start()
  let deliver = emails.deliver(emails.new(mailer(box), app_name: "Acme"))
  let assert Ok(Nil) =
    deliver(
      auth.Delivery(
        ..delivery(auth.SignIn),
        link: Some(secret.wrap("https://acme.test/auth/login#token=tok-123")),
        code: Some(secret.wrap("123456")),
      ),
    )
  let assert Ok(sent) = outbox.latest_to(box, "ada@example.com")
  assert sent.to == [mail.address("ada@example.com")]
  assert sent.from == mail.named("Acme", "hello@acme.test")
  assert sent.subject == "Sign in to Acme"
  assert sent.tags == ["auth.sign_in"]
  let assert Some(html) = sent.html
  let assert Some(text) = sent.text
  assert string.contains(
    html,
    "href=\"https://acme.test/auth/login#token=tok-123\"",
  )
  assert string.contains(html, "123456")
  // The link stands on its own line, so a text reader gets it whole.
  assert string.contains(
    text,
    "Sign in:\nhttps://acme.test/auth/login#token=tok-123\n\n",
  )
  assert string.contains(text, "Or enter this code: 123456")
}

pub fn without_a_link_or_code_the_token_is_shown_test() {
  let box = outbox.start()
  let deliver = emails.deliver(emails.new(mailer(box), app_name: "Acme"))
  let assert Ok(Nil) = deliver(delivery(auth.Registration))
  let assert Ok(sent) = outbox.latest_to(box, "ada@example.com")
  let assert Some(text) = sent.text
  assert string.contains(text, "tok-123")
  assert sent.tags == ["auth.registration"]
}

pub fn notices_carry_no_token_test() {
  let box = outbox.start()
  let deliver = emails.deliver(emails.new(mailer(box), app_name: "Acme"))
  let assert Ok(Nil) =
    deliver(
      auth.Delivery(..delivery(auth.PasswordChanged), token: secret.wrap("")),
    )
  let assert Ok(sent) = outbox.latest_to(box, "ada@example.com")
  assert sent.subject == "Your Acme password changed"
  let assert Some(text) = sent.text
  assert !string.contains(text, "Paste this token")
}

pub fn a_template_can_be_replaced_test() {
  let box = outbox.start()
  let custom =
    emails.new(mailer(box), app_name: "Acme")
    |> emails.with_template(for: auth.SignIn, build: fn(delivery) {
      mail.message()
      |> mail.subject("Custom")
      |> mail.text("Token: " <> secret.reveal(delivery.token))
    })
  let assert Ok(Nil) = emails.deliver(custom)(delivery(auth.SignIn))
  let assert Ok(sent) = outbox.latest_to(box, "ada@example.com")
  assert sent.subject == "Custom"
  assert sent.text == Some("Token: tok-123")
  assert sent.tags == ["auth.sign_in"]
  // Other purposes keep the default.
  let assert Ok(Nil) = emails.deliver(custom)(delivery(auth.EmailChange))
  let assert Ok(sent) = outbox.latest_to(box, "ada@example.com")
  assert sent.subject == "Confirm your new email address"
}

pub fn a_failed_send_is_an_error_test() {
  let failing =
    mail.adapter(named: "down", send: fn(_) {
      Error(mail.Unavailable("connection refused"))
    })
  let deliver =
    emails.deliver(emails.new(
      mail.mailer(failing) |> mail.default_from(mail.address("a@acme.test")),
      app_name: "Acme",
    ))
  assert deliver(delivery(auth.SignIn)) == Error(Nil)
}

pub fn mfa_codes_test() {
  let box = outbox.start()
  let deliver = emails.deliver_mfa(emails.new(mailer(box), app_name: "Acme"))
  let assert Ok(ada) = user_value("ada@example.com")
  let assert Ok(Nil) = deliver(ada, secret.wrap("482913"))
  let assert Ok(sent) = outbox.latest_to(box, "ada@example.com")
  assert sent.subject == "Your Acme verification code"
  assert sent.tags == ["auth.mfa_code"]
  let assert Some(text) = sent.text
  assert string.contains(text, "482913")
}

fn user_value(email: String) -> Result(user.User, Nil) {
  let now = timestamp_zero()
  Ok(user.User(
    id: "u1",
    email:,
    group_id: "default",
    created_at: now,
    updated_at: now,
    locale: None,
  ))
}

fn timestamp_zero() -> timestamp.Timestamp {
  timestamp.from_unix_seconds(0)
}

pub fn every_template_has_a_preview_that_would_send_test() {
  let box = outbox.start()
  let previews = emails.previews(emails.new(mailer(box), app_name: "Acme"))
  assert list.length(previews) == 8
  assert list.all(previews, fn(p) { preview.group(p) == "Auth" })
  list.each(previews, fn(p) {
    let assert Ok(message) = preview.build(p)
    let assert Ok(outgoing) = mail.prepare(mailer(box), message)
    assert outgoing.to == [mail.address("someone@example.com")]
  })
}

pub fn signs_in_with_the_emailed_token_test() {
  use db <- with_repo
  let box = outbox.start()
  let assert Ok(Nil) = migration.run(db, [auth.schema()])
  let assert Ok(identity) =
    auth.new(
      repo: db,
      origin: "http://localhost:8787",
      deliver: emails.deliver(emails.new(mailer(box), app_name: "Acme")),
    )
  let identity = auth.allow_registration(identity)
  let assert Ok(Nil) =
    auth.request_token(identity, "grace@example.com", auth.Register)
  let assert Ok(sent) = outbox.latest_to(box, "grace@example.com")
  assert sent.tags == ["auth.registration"]
  let assert Some(text) = sent.text
  // The token is the long line after the paste instruction.
  let assert Ok(#(_, after)) = string.split_once(text, "asked for it:")
  let token =
    string.split(after, "\n")
    |> list.map(string.trim)
    |> list.find(fn(line) { line != "" })
  let assert Ok(token) = token
  let assert Ok(session) = auth.exchange(identity, token)
  assert session.user.email == "grace@example.com"
}
