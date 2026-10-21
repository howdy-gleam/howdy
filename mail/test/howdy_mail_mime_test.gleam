import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import howdy/mail
import howdy/mail/mime

@external(erlang, "howdy_mail_test_ffi", "mime_header")
fn header(data: String, name: String) -> Result(String, Nil)

@external(erlang, "howdy_mail_test_ffi", "mime_leaves")
fn leaves(data: String) -> List(#(String, BitArray))

fn outgoing() -> mail.Outgoing {
  mail.Outgoing(
    id: "0123456789abcdef0123456789abcdef",
    date: timestamp.from_unix_seconds(1_790_000_000),
    from: mail.named("Acme", "hello@acme.test"),
    to: [mail.address("mike@example.com")],
    cc: [],
    bcc: [],
    reply_to: None,
    subject: "Welcome",
    html: None,
    text: Some("Hello"),
    headers: [],
    attachments: [],
    tags: [],
  )
}

pub fn headers_test() {
  let data =
    mime.encode(
      mail.Outgoing(
        ..outgoing(),
        cc: [mail.named("Jones, Mike", "cc@example.com")],
        bcc: [mail.address("secret@example.com")],
        reply_to: Some(mail.address("support@acme.test")),
        headers: [#("List-Unsubscribe", "<https://acme.test/u>")],
      ),
    )
  assert header(data, "Subject") == Ok("Welcome")
  assert header(data, "From") == Ok("Acme <hello@acme.test>")
  assert header(data, "Cc") == Ok("\"Jones, Mike\" <cc@example.com>")
  assert header(data, "Reply-To") == Ok("support@acme.test")
  assert header(data, "Message-ID")
    == Ok("<0123456789abcdef0123456789abcdef@acme.test>")
  assert header(data, "Date") == Ok("Mon, 21 Sep 2026 14:13:20 +0000")
  assert header(data, "List-Unsubscribe") == Ok("<https://acme.test/u>")
  assert header(data, "Bcc") == Error(Nil)
  assert !string.contains(data, "secret@example.com")
  assert string.contains(data, "\r\n\r\n")
  assert !string.contains(string.replace(data, "\r\n", ""), "\n")
}

pub fn unicode_headers_test() {
  let subject =
    "Grüße aus Köln — your sign-in link is here, valid for 15 minutes 🎉"
  let data =
    mime.encode(
      mail.Outgoing(
        ..outgoing(),
        subject:,
        from: mail.named("Zoë Café", "hello@acme.test"),
      ),
    )
  assert header(data, "Subject") == Ok(subject)
  assert header(data, "From") == Ok("Zoë Café <hello@acme.test>")
  // Every header line stays short, and the raw header is ASCII.
  let assert Ok(#(head, _)) = string.split_once(data, "\r\n\r\n")
  assert list.all(string.split(head, "\r\n"), fn(line) {
    string.length(line) <= 78
  })
  assert !string.contains(head, "ü")
}

pub fn long_ascii_subject_folds_test() {
  let subject = string.repeat("word ", 40) |> string.trim
  let data = mime.encode(mail.Outgoing(..outgoing(), subject:))
  let assert Ok(#(head, _)) = string.split_once(data, "\r\n\r\n")
  assert list.all(string.split(head, "\r\n"), fn(line) {
    string.length(line) <= 78
  })
  // RFC 5322 unfolding removes the line breaks and keeps the spaces.
  // (mimemail also drops the spaces, so it is not used here.)
  let assert Ok(#(_, rest)) = string.split_once(head, "Subject: ")
  let assert Ok(#(folded, _)) = string.split_once(rest, "\r\nMessage-ID")
  assert string.replace(folded, "\r\n", "") == subject
}

pub fn alternative_bodies_test() {
  let html = "<p>Hi " <> string.repeat("é", 100) <> " = done</p>"
  let text =
    "Line one\nLine two with trailing space \n. a dot line\n"
    <> string.repeat("x", 200)
  let data =
    mime.encode(mail.Outgoing(..outgoing(), html: Some(html), text: Some(text)))
  assert string.contains(data, "multipart/alternative")
  let assert [#("text/plain", plain), #("text/html", rich)] = leaves(data)
  assert plain == <<string.replace(text, "\n", "\r\n"):utf8>>
  assert rich == <<html:utf8>>
  // Quoted-printable keeps every line within 76 characters.
  assert list.all(string.split(data, "\r\n"), fn(line) {
    string.length(line) <= 998
  })
}

pub fn attachments_test() {
  let logo = <<137, 80, 78, 71, 0, 1, 2, 3, 255>>
  let pdf = list.repeat(<<"%PDF-1.7 ">>, 100) |> bit_array_concat
  let data =
    mime.encode(
      mail.Outgoing(
        ..outgoing(),
        html: Some("<img src=\"cid:logo\">"),
        text: Some("see attached"),
        attachments: [
          mail.attachment("logo.png", "image/png", logo) |> mail.inline("logo"),
          mail.attachment("Rechnung für März.pdf", "application/pdf", pdf),
        ],
      ),
    )
  assert string.contains(data, "multipart/mixed")
  assert string.contains(data, "multipart/related")
  assert string.contains(data, "Content-ID: <logo>")
  assert string.contains(
    data,
    "filename*=UTF-8''Rechnung%20f%C3%BCr%20M%C3%A4rz.pdf",
  )
  let assert [
    #("text/plain", _),
    #("text/html", _),
    #("image/png", png),
    #("application/pdf", document),
  ] = leaves(data)
  assert png == logo
  assert document == pdf
}

fn bit_array_concat(parts: List(BitArray)) -> BitArray {
  list.fold(parts, <<>>, fn(acc, part) { <<acc:bits, part:bits>> })
}

pub fn quoted_printable_test() {
  assert mime.quoted_printable("a=b") == "a=3Db"
  assert mime.quoted_printable("trailing \nnext") == "trailing=20\r\nnext"
  assert mime.quoted_printable("é") == "=C3=A9"
  let long = mime.quoted_printable(string.repeat("é", 40))
  assert list.all(string.split(long, "\r\n"), fn(line) {
    string.length(line) <= 76
  })
  assert string.contains(long, "=\r\n")
}
