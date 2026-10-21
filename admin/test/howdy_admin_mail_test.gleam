//// The mail pages: the outbox, one message in every form, and previews.

import gleam/erlang/process
import gleam/http/request
import gleam/list
import gleam/string
import howdy
import howdy/admin
import howdy/mail
import howdy/mail/outbox
import howdy/mail/preview
import howdy/testing

fn app(register: fn(admin.Admin) -> admin.Admin) -> howdy.App {
  howdy.new() |> admin.mount(admin.new() |> register)
}

fn request(
  app: howdy.App,
  path: String,
) -> #(Int, List(#(String, String)), String) {
  let res =
    testing.get(path) |> request.set_host("localhost") |> testing.send(app)
  #(res.status, res.headers, testing.text(res))
}

fn get(app: howdy.App, path: String) -> String {
  let #(status, _, body) = request(app, path)
  assert status == 200
    as { "GET " <> path <> " gave " <> string.inspect(status) }
  body
}

fn post(app: howdy.App, path: String) -> String {
  let res =
    testing.post_form(path, [])
    |> request.set_host("localhost")
    |> testing.header("sec-fetch-site", "same-origin")
    |> testing.send(app)
  assert res.status == 303
    as {
      "POST "
      <> path
      <> " gave "
      <> string.inspect(res.status)
      <> ": "
      <> testing.text(res)
    }
  let assert Ok(location) = list.key_find(res.headers, "location")
  location
}

fn mailer(box: outbox.Outbox) -> mail.Mailer {
  mail.mailer(outbox.adapter(box))
  |> mail.default_from(mail.named("Acme", "hello@acme.test"))
}

fn welcome() -> mail.Message {
  mail.message()
  |> mail.to([mail.named("Mike", "mike@example.com")])
  |> mail.subject("Welcome to Acme")
  |> mail.html(
    "<html><head></head><body><p>Hi</p><img src=\"cid:logo\"><a href=\"https://acme.test/start\">Start</a></body></html>",
  )
  |> mail.text("Hi\nStart at https://acme.test/start")
  |> mail.tag("onboarding.welcome")
  |> mail.attach(
    mail.attachment("logo.png", "image/png", <<1, 2, 3>>) |> mail.inline("logo"),
  )
  |> mail.attach(mail.attachment("terms.txt", "text/plain", <<"terms">>))
}

pub fn hidden_until_registered_test() {
  let bare = app(fn(a) { a })
  let #(status, _, _) = request(bare, "/_howdy/mail")
  assert status == 404
  let overview = get(bare, "/_howdy")
  assert string.contains(overview, "howdy_mail")
  assert !string.contains(overview, "Outbox")
}

pub fn shows_a_sent_message_test() {
  let box = outbox.start()
  let app = app(admin.mail(_, box))
  let assert Ok(receipt) = mail.send(mailer(box), welcome())
  let base = "/_howdy/mail/message/" <> receipt.id

  let overview = get(app, "/_howdy")
  assert string.contains(overview, "1 message in the outbox")
  let outbox_page = get(app, "/_howdy/mail")
  assert string.contains(outbox_page, "/_howdy/live/mail")

  let page = get(app, base)
  assert string.contains(page, "Welcome to Acme")
  assert string.contains(page, "Acme &lt;hello@acme.test&gt;")
  assert string.contains(page, "onboarding.welcome")
  assert string.contains(page, "terms.txt")
  assert string.contains(
    page,
    "sandbox=\"allow-popups allow-popups-to-escape-sandbox\"",
  )
  // The text's URL is a link.
  assert string.contains(page, "href=\"https://acme.test/start\"")
  assert string.contains(get(app, base <> "?width=mobile"), "375px")

  let #(status, headers, html) = request(app, base <> "/html")
  assert status == 200
  let assert Ok(policy) = list.key_find(headers, "content-security-policy")
  assert string.starts_with(policy, "sandbox ")
  assert string.contains(policy, "default-src 'none'")
  assert string.contains(html, "<head><base target=\"_blank\">")
  assert string.contains(html, "src=\"data:image/png;base64,AQID\"")

  let #(_, headers, source) = request(app, base <> "/source")
  assert list.key_find(headers, "content-type") == Ok("message/rfc822")
  assert string.contains(source, "Subject: Welcome to Acme")

  let #(status, headers, body) = request(app, base <> "/attachment/1")
  assert status == 200
  assert body == "terms"
  assert list.key_find(headers, "content-disposition")
    == Ok("attachment; filename=\"terms.txt\"")
  let #(status, _, _) = request(app, base <> "/attachment/9")
  assert status == 404

  assert post(app, "/_howdy/mail/clear") == "/_howdy/mail"
  assert outbox.messages(box) == Ok([])
  assert string.contains(get(app, base), "No such message")
}

fn previews() -> List(preview.Preview) {
  [
    preview.new("Welcome", welcome),
    preview.new("Broken", fn() { panic as "no sample user" })
      |> preview.in_group("Billing"),
    preview.new("Unaddressed", fn() {
      mail.message() |> mail.subject("Nobody") |> mail.text("x")
    })
      |> preview.in_group("Billing"),
  ]
}

pub fn renders_previews_test() {
  let box = outbox.start()
  let app =
    app(fn(a) {
      a
      |> admin.mail(box)
      |> admin.mail_previews(previews(), send_with: mailer(box))
    })
  let page = get(app, "/_howdy/mail/previews")
  assert string.contains(page, "Emails · Welcome")
  assert string.contains(page, "Billing")
  assert string.contains(page, "Send to outbox")
  assert string.contains(page, "Through outbox")
  // Rendered with the mailer's default sender.
  assert string.contains(page, "Acme &lt;hello@acme.test&gt;")
  assert string.contains(page, "/_howdy/mail/previews/html?p=emails.welcome")

  let html = get(app, "/_howdy/mail/previews/html?p=emails.welcome")
  assert string.contains(html, "<base target=\"_blank\">")

  let broken = get(app, "/_howdy/mail/previews?p=billing.broken")
  assert string.contains(broken, "The template crashed")
  assert string.contains(broken, "no sample user")

  let unaddressed = get(app, "/_howdy/mail/previews?p=billing.unaddressed")
  assert string.contains(unaddressed, "would not be sent")
  assert string.contains(unaddressed, "no recipients")

  let #(status, _, _) = request(app, "/_howdy/mail/previews/html?p=nope")
  assert status == 404
}

pub fn sends_a_preview_to_the_outbox_test() {
  let box = outbox.start()
  let app =
    app(fn(a) {
      a
      |> admin.mail(box)
      |> admin.mail_previews(previews(), send_with: mailer(box))
    })
  let location = post(app, "/_howdy/mail/previews/send?p=emails.welcome")
  let assert Ok([sent]) = outbox.messages(box)
  assert location == "/_howdy/mail/message/" <> sent.id
  assert sent.subject == "Welcome to Acme"
}

pub fn sends_a_preview_without_an_outbox_test() {
  let box = outbox.start()
  let app = app(admin.mail_previews(_, previews(), send_with: mailer(box)))
  let page = get(app, "/_howdy/mail/previews")
  assert string.contains(page, ">Send<")
  // Without an outbox registered, Outbox is not in the navigation and
  // /mail leads to the previews.
  assert !string.contains(page, ">Outbox<")
  let #(status, headers, _) = request(app, "/_howdy/mail")
  assert status == 303
  assert list.key_find(headers, "location") == Ok("/_howdy/mail/previews")
  let location = post(app, "/_howdy/mail/previews/send?p=emails.welcome")
  assert location == "/_howdy/mail/previews?p=emails.welcome&sent=outbox"
  let assert Ok([_]) = outbox.messages(box)
}

pub fn previews_from_several_calls_are_shown_together_test() {
  let box = outbox.start()
  let registered =
    admin.new()
    |> admin.mail_previews(
      [preview.new("One", welcome)],
      send_with: mailer(box),
    )
    |> admin.mail_previews(
      [preview.new("Two", welcome)],
      send_with: mailer(box),
    )
  assert admin.preview_count(registered) == 2
}

pub fn an_outbox_that_is_not_running_is_reported_test() {
  let box = outbox.start()
  let app = app(admin.mail(_, box))
  // The outbox is linked to the test, so let go of it before stopping it.
  let assert Ok(pid) = outbox.pid(box)
  process.unlink(pid)
  process.kill(pid)
  let assert Error(_) = outbox.messages(box)

  let overview = get(app, "/_howdy")
  assert string.contains(overview, "The outbox could not be read")
  assert !string.contains(overview, "in the outbox")

  // Clearing cannot redirect as if it worked: the page says why instead.
  let res =
    testing.post_form("/_howdy/mail/clear", [])
    |> request.set_host("localhost")
    |> testing.header("sec-fetch-site", "same-origin")
    |> testing.send(app)
  assert res.status == 200
  assert string.contains(testing.text(res), "The outbox was not cleared")
}
