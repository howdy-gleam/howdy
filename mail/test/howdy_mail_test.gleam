import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import howdy/mail
import howdy/service
import smail/email
import smail/html

pub fn main() -> Nil {
  gleeunit.main()
}

fn capture() -> #(mail.Mailer, fn() -> List(mail.Outgoing)) {
  let table = new_table()
  let adapter =
    mail.adapter(named: "capture", send: fn(outgoing: mail.Outgoing) {
      table_push(table, outgoing)
      Ok(mail.Receipt(outgoing.id, None))
    })
  #(
    mail.mailer(adapter)
      |> mail.default_from(mail.named("Acme", "hello@acme.test")),
    fn() { table_all(table) },
  )
}

type Table

@external(erlang, "howdy_mail_test_ffi", "new_table")
fn new_table() -> Table

@external(erlang, "howdy_mail_test_ffi", "table_push")
fn table_push(table: Table, value: a) -> Nil

@external(erlang, "howdy_mail_test_ffi", "table_all")
fn table_all(table: Table) -> List(a)

fn welcome() -> mail.Message {
  mail.message()
  |> mail.to([mail.address("mike@example.com")])
  |> mail.subject("Welcome")
  |> mail.text("Hello")
}

pub fn parse_address_test() {
  assert mail.parse_address("mike@example.com")
    == Ok(mail.Address(None, "mike@example.com"))
  assert mail.parse_address("  Mike Jones <mike@example.com> ")
    == Ok(mail.Address(Some("Mike Jones"), "mike@example.com"))
  assert mail.parse_address("\"Jones, Mike\" <mike@example.com>")
    == Ok(mail.Address(Some("Jones, Mike"), "mike@example.com"))
  assert mail.parse_address("<mike@example.com>")
    == Ok(mail.Address(None, "mike@example.com"))
  assert mail.parse_address("not an address") == Error(Nil)
  assert mail.parse_address("Mike <mike@@example.com>") == Error(Nil)
}

pub fn valid_email_test() {
  assert mail.valid_email("a@b.co")
  assert mail.valid_email("first.last+tag@sub.example.com")
  assert mail.valid_email("dev@localhost")
  assert !mail.valid_email("a@b")
  assert !mail.valid_email("@b.co")
  assert !mail.valid_email("a@.b.co")
  assert !mail.valid_email("a@b..co")
  assert !mail.valid_email("a b@c.co")
  assert !mail.valid_email("a@b.co>\r\nBcc: x@y.z")
  assert !mail.valid_email("ü@b.co")
}

pub fn send_applies_the_default_sender_test() {
  let #(mailer, sent) = capture()
  let assert Ok(receipt) = mail.send(mailer, welcome())
  let assert [outgoing] = sent()
  assert outgoing.id == receipt.id
  assert outgoing.from == mail.named("Acme", "hello@acme.test")
  assert outgoing.text == Some("Hello")
  assert outgoing.html == None
  assert string.length(outgoing.id) == 32
}

pub fn own_sender_wins_test() {
  let #(mailer, sent) = capture()
  let assert Ok(_) =
    mail.send(mailer, welcome() |> mail.from(mail.address("other@acme.test")))
  let assert [outgoing] = sent()
  assert outgoing.from == mail.address("other@acme.test")
}

pub fn lists_accumulate_test() {
  let #(mailer, sent) = capture()
  let assert Ok(_) =
    mail.send(
      mailer,
      welcome()
        |> mail.to([mail.address("two@example.com")])
        |> mail.cc([mail.address("three@example.com")])
        |> mail.bcc([mail.address("four@example.com")])
        |> mail.tag("a")
        |> mail.tag("b"),
    )
  let assert [outgoing] = sent()
  assert list.map(mail.recipients(outgoing), fn(a) { a.email })
    == [
      "mike@example.com",
      "two@example.com",
      "three@example.com",
      "four@example.com",
    ]
  assert outgoing.tags == ["a", "b"]
}

pub fn template_renders_html_and_text_test() {
  let #(mailer, sent) = capture()
  let element =
    email.html([], [
      email.head([], []),
      email.body([], [email.paragraph([], [html.text("Sign in to Acme")])]),
    ])
  let assert Ok(_) =
    mail.send(
      mailer,
      mail.message()
        |> mail.to([mail.address("mike@example.com")])
        |> mail.subject("Sign in")
        |> mail.template(element),
    )
  let assert [outgoing] = sent()
  let assert Some(html) = outgoing.html
  let assert Some(text) = outgoing.text
  assert string.contains(html, "<html")
  assert string.contains(html, "Sign in to Acme")
  assert string.contains(text, "Sign in to Acme")
  assert !string.contains(text, "<")
}

pub fn explicit_text_beats_template_text_test() {
  let element = email.html([], [email.body([], [html.text("generated")])])
  let #(mailer, sent) = capture()
  let assert Ok(_) =
    mail.send(mailer, welcome() |> mail.text("mine") |> mail.template(element))
  let assert [outgoing] = sent()
  assert outgoing.text == Some("mine")
}

pub fn invalid_messages_are_refused_before_the_adapter_test() {
  let #(mailer, sent) = capture()
  let invalid = fn(message) {
    case mail.send(mailer, message) {
      Error(mail.Invalid(_)) -> True
      _ -> False
    }
  }
  assert invalid(welcome() |> mail.subject("Hi\r\nBcc: victim@example.com"))
  assert invalid(mail.message() |> mail.subject("x") |> mail.text("x"))
  assert invalid(welcome() |> mail.subject("  "))
  assert invalid(
    mail.message()
    |> mail.to([mail.address("mike@example.com")])
    |> mail.subject("no body"),
  )
  assert invalid(welcome() |> mail.to([mail.address("nope")]))
  assert invalid(
    welcome() |> mail.to([mail.named("Evil\nBcc: x@y.z", "a@b.co")]),
  )
  assert invalid(welcome() |> mail.header("Subject", "again"))
  assert invalid(welcome() |> mail.header("Bad Name", "x"))
  assert invalid(welcome() |> mail.header("X-Ok", "line\nbreak"))
  assert invalid(
    welcome() |> mail.attach(mail.attachment("a.txt", "text", <<"x">>)),
  )
  assert invalid(
    welcome() |> mail.attach(mail.attachment("", "text/plain", <<>>)),
  )
  assert invalid(welcome() |> mail.tag(""))
  assert sent() == []
}

pub fn no_sender_test() {
  let adapter =
    mail.adapter(named: "unused", send: fn(o: mail.Outgoing) {
      Ok(mail.Receipt(o.id, None))
    })
  let assert Error(mail.Invalid(reason)) =
    mail.send(mail.mailer(adapter), welcome())
  assert string.contains(reason, "sender")
}

pub fn redirect_all_test() {
  let #(mailer, sent) = capture()
  let redirected =
    mail.redirect_all(
      mail.mailer_adapter(mailer),
      to: mail.address("qa@acme.test"),
    )
  let assert Ok(_) =
    mail.send(
      mail.mailer(redirected) |> mail.default_from(mail.address("a@acme.test")),
      welcome()
        |> mail.cc([mail.address("cc@example.com")])
        |> mail.bcc([mail.address("bcc@example.com")]),
    )
  let assert [outgoing] = sent()
  assert outgoing.to == [mail.address("qa@acme.test")]
  assert outgoing.cc == []
  assert outgoing.bcc == []
  assert list.key_find(outgoing.headers, "X-Original-To")
    == Ok("mike@example.com, cc@example.com, bcc@example.com")
}

pub fn fallback_only_on_unavailable_test() {
  let #(backup, sent) = capture()
  let failing = fn(error) {
    mail.adapter(named: "failing", send: fn(_) { Error(error) })
  }
  let send = fn(primary) {
    mail.mailer(mail.fallback(primary, mail.mailer_adapter(backup)))
    |> mail.default_from(mail.address("a@acme.test"))
    |> mail.send(welcome())
  }
  let assert Ok(_) = send(failing(mail.Unavailable("down")))
  assert list.length(sent()) == 1
  let assert Error(mail.Refused("no")) = send(failing(mail.Refused("no")))
  assert list.length(sent()) == 1
}

pub fn errors_test() {
  assert mail.retryable(mail.Unavailable("x"))
  assert !mail.retryable(mail.Refused("x"))
  assert !mail.retryable(mail.Invalid("x"))
  assert mail.to_service_error(mail.Invalid("no subject"))
    == service.Invalid("no subject")
  let assert service.Internal(_) = mail.to_service_error(mail.Refused("x"))
}

// -- Keeping messages ----------------------------------------------------------

pub fn a_message_survives_json_test() {
  let message =
    mail.message()
    |> mail.from(mail.named("Acme", "hello@acme.test"))
    |> mail.to([
      mail.address("ada@example.com"),
      mail.named("Bo", "bo@example.com"),
    ])
    |> mail.cc([mail.address("cc@example.com")])
    |> mail.bcc([mail.address("bcc@example.com")])
    |> mail.reply_to(mail.address("support@acme.test"))
    |> mail.subject("Your invoice ✓")
    |> mail.template(
      email.html([], [
        email.head([], []),
        email.body([], [email.paragraph([], [html.text("Hi!")])]),
      ]),
    )
    |> mail.header("List-Unsubscribe", "<https://acme.test/u>")
    |> mail.attach(
      mail.attachment(
        filename: "invoice.pdf",
        content_type: "application/pdf",
        content: <<0, 1, 2, 255>>,
      ),
    )
    |> mail.attach(
      mail.attachment(filename: "logo.png", content_type: "image/png", content: <<
        9,
      >>)
      |> mail.inline("logo"),
    )
    |> mail.tag("billing")
  let stored = json.to_string(mail.message_to_json(message))
  let assert Ok(read) = json.parse(stored, mail.message_decoder())
  let mailer = mail.mailer(mail.adapter(named: "none", send: fn(_) { panic }))
  let assert Ok(before) = mail.prepare(mailer, message)
  let assert Ok(after) = mail.prepare(mailer, read)
  assert mail.Outgoing(..after, id: before.id, date: before.date) == before
  // Text set by hand wins over the generated text, after a round trip too.
  let assert Ok(read) =
    json.parse(
      json.to_string(mail.message_to_json(mail.text(message, "By hand"))),
      mail.message_decoder(),
    )
  let assert Ok(after) = mail.prepare(mailer, read)
  assert after.text == Some("By hand")
}

pub fn an_unknown_format_is_refused_test() {
  let assert Error(_) = json.parse("{\"format\": 2}", mail.message_decoder())
}
