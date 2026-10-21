import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/option.{Some}
import gleam/time/timestamp
import howdy/mail
import howdy/mail/resend
import howdy/mail/sendgrid

fn outgoing() -> mail.Outgoing {
  mail.Outgoing(
    id: "abc123",
    date: timestamp.from_unix_seconds(1_790_000_000),
    from: mail.named("Acme, Inc.", "hello@acme.test"),
    to: [mail.named("Mike", "mike@example.com")],
    cc: [mail.address("MIKE@example.com"), mail.address("cc@example.com")],
    bcc: [mail.address("cc@example.com"), mail.address("bcc@example.com")],
    reply_to: Some(mail.address("support@acme.test")),
    subject: "Welcome",
    html: Some("<p>Hi</p>"),
    text: Some("Hi"),
    headers: [#("X-Campaign", "spring")],
    attachments: [
      mail.attachment("a.txt", "text/plain", <<"hello">>),
      mail.attachment("logo.png", "image/png", <<1, 2>>) |> mail.inline("logo"),
    ],
    tags: ["auth.sign_in"],
  )
}

fn field(body: String, path: List(String), decoder: decode.Decoder(a)) -> a {
  let assert Ok(value) = json.parse(body, decode.at(path, decoder))
  value
}

pub fn resend_request_test() {
  let config = resend.new("re_key")
  let assert Ok(req) = resend.request(config, outgoing())
  assert req.method == http.Post
  assert req.host == "api.resend.com"
  assert req.path == "/emails"
  assert request.get_header(req, "authorization") == Ok("Bearer re_key")
  assert request.get_header(req, "idempotency-key") == Ok("abc123")
  let body = req.body
  assert field(body, ["from"], decode.string)
    == "\"Acme, Inc.\" <hello@acme.test>"
  assert field(body, ["to"], decode.list(decode.string))
    == ["Mike <mike@example.com>"]
  assert field(body, ["reply_to"], decode.list(decode.string))
    == ["support@acme.test"]
  assert field(body, ["headers", "X-Campaign"], decode.string) == "spring"
  assert field(
      body,
      ["attachments"],
      decode.list(decode.at(["content"], decode.string)),
    )
    == ["aGVsbG8=", "AQI="]
  assert field(body, ["tags"], decode.list(decode.at(["name"], decode.string)))
    == ["auth_sign_in"]
}

pub fn resend_receipt_test() {
  let ok = response.new(200) |> response.set_body("{\"id\":\"re_1\"}")
  assert resend.receipt(outgoing(), ok)
    == Ok(mail.Receipt("abc123", Some("re_1")))
  let assert Error(mail.Unavailable(_)) =
    resend.receipt(outgoing(), response.new(429) |> response.set_body(""))
  let assert Error(mail.Unavailable(_)) =
    resend.receipt(outgoing(), response.new(503) |> response.set_body(""))
  let assert Error(mail.Refused(reason)) =
    resend.receipt(
      outgoing(),
      response.new(403)
        |> response.set_body("{\"message\":\"domain not verified\"}"),
    )
  assert reason == "Resend answered 403: {\"message\":\"domain not verified\"}"
}

pub fn sendgrid_request_test() {
  let config =
    sendgrid.new("sg_key") |> sendgrid.base_url("https://api.eu.sendgrid.com")
  let assert Ok(req) = sendgrid.request(config, outgoing())
  assert req.host == "api.eu.sendgrid.com"
  assert req.path == "/v3/mail/send"
  assert request.get_header(req, "authorization") == Ok("Bearer sg_key")
  let body = req.body
  let emails = decode.list(decode.at(["email"], decode.string))
  // Each address once across to, cc and bcc.
  assert field(
      body,
      ["personalizations"],
      decode.list(decode.at(["to"], emails)),
    )
    == [["mike@example.com"]]
  assert field(
      body,
      ["personalizations"],
      decode.list(decode.at(["cc"], emails)),
    )
    == [["cc@example.com"]]
  assert field(
      body,
      ["personalizations"],
      decode.list(decode.at(["bcc"], emails)),
    )
    == [["bcc@example.com"]]
  assert field(body, ["from", "name"], decode.string) == "Acme, Inc."
  assert field(
      body,
      ["content"],
      decode.list(decode.at(["type"], decode.string)),
    )
    == ["text/plain", "text/html"]
  assert field(
      body,
      ["attachments"],
      decode.list(decode.at(["disposition"], decode.string)),
    )
    == ["attachment", "inline"]
  assert field(body, ["categories"], decode.list(decode.string))
    == ["auth.sign_in"]
  assert field(body, ["custom_args", "howdy_id"], decode.string) == "abc123"
}

pub fn sendgrid_needs_a_to_recipient_test() {
  let assert Error(mail.Invalid(_)) =
    sendgrid.request(sendgrid.new("k"), mail.Outgoing(..outgoing(), to: []))
}

pub fn sendgrid_receipt_test() {
  let accepted =
    response.new(202)
    |> response.set_header("x-message-id", "sg_1")
    |> response.set_body("")
  assert sendgrid.receipt(outgoing(), accepted)
    == Ok(mail.Receipt("abc123", Some("sg_1")))
  let assert Error(mail.Refused(_)) =
    sendgrid.receipt(outgoing(), response.new(401) |> response.set_body(""))
  let assert Error(mail.Unavailable(_)) =
    sendgrid.receipt(outgoing(), response.new(500) |> response.set_body(""))
}

pub fn unreachable_provider_test() {
  let adapter =
    resend.new("k")
    |> resend.base_url("http://127.0.0.1:1")
    |> resend.timeout(1000)
    |> resend.adapter
  let assert Error(mail.Unavailable(_)) = mail.deliver(adapter, outgoing())
}
