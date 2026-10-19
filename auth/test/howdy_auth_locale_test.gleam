//// Pages, API answers and emails in the locale `auth.with_locales` chooses.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import howdy/auth
import howdy/auth/emails
import howdy/auth/pages
import howdy/auth/secret
import howdy/i18n
import howdy/locale
import howdy/mail
import howdy/mail/outbox
import howdy/service
import howdy/testing
import support.{app, fixture}

fn locales() {
  locale.negotiator(["en", "de", "ar"], default: "en")
  |> locale.from_cookie("locale")
  |> locale.from_accept_language
}

fn in(req, tag: String) {
  testing.header(req, "accept-language", tag)
}

pub fn pages_are_written_in_the_request_locale_test() {
  use _, identity, permissions, _ <- fixture
  let identity = auth.with_locales(identity, locales())
  let app = app(identity, permissions)
  let page =
    testing.get("/auth/login") |> in("de-CH, en;q=0.5") |> testing.send(app)
  let html = testing.text(page)
  assert string.contains(html, "<html lang=\"de\" dir=\"ltr\">")
  assert string.contains(html, "<h1>Anmelden</h1>")
  assert string.contains(html, "E-Mail-Adresse")
  // The script's words come in the page's language too.
  assert string.contains(html, "\"signed_in\":\"Sie sind angemeldet.")
  let page = testing.get("/auth/login") |> in("ar") |> testing.send(app)
  assert string.contains(testing.text(page), "<html lang=\"ar\" dir=\"rtl\">")
  // Without with_locales, or for an unsupported language, English.
  let page = testing.get("/auth/login") |> in("ja") |> testing.send(app)
  assert string.contains(testing.text(page), "<html lang=\"en\" dir=\"ltr\">")
  assert string.contains(testing.text(page), "<h1>Sign in</h1>")
}

pub fn english_by_default_test() {
  use _, identity, permissions, _ <- fixture
  let page =
    testing.get("/auth/login")
    |> in("de")
    |> testing.send(app(identity, permissions))
  assert string.contains(testing.text(page), "<html lang=\"en\" dir=\"ltr\">")
}

pub fn the_words_block_cannot_end_its_script_test() {
  use _, identity, _, _ <- fixture
  let block = pages.words_json(identity, i18n.new("en"))
  let assert Ok(_) = json.parse(block, decode_any())
  // A translation holding markup or line separators stays inert, and reads
  // back as written.
  let hostile = "</script><!-- & \u{2028}\u{2029}"
  let safe = pages.script_safe(json.to_string(json.string(hostile)))
  assert !string.contains(safe, "<")
  assert !string.contains(safe, ">")
  assert !string.contains(safe, "&")
  assert !string.contains(safe, "\u{2028}")
  assert json.parse(safe, decode.string) == Ok(hostile)
}

fn decode_any() {
  decode.dict(decode.string, decode.string)
}

pub fn error_responses_carry_codes_test() {
  use _, identity, permissions, _ <- fixture
  let app = app(identity, permissions)
  let res =
    testing.post(
      "/api/auth/session",
      json.object([#("token", json.string("not-a-real-token"))]),
    )
    |> testing.header("origin", "https://example.test")
    |> testing.send(app)
  assert res.status == 401
  assert testing.json(res, decode.at(["code"], decode.string))
    == Ok("unauthorized")
  assert testing.error(res) == Ok("unauthorized")
  // Answers that tell the reader something carry a code as well.
  let res =
    testing.post(
      "/api/auth/register",
      json.object([#("email", json.string("ada@example.com"))]),
    )
    |> testing.header("origin", "https://example.test")
    |> testing.send(app)
  assert res.status == 202
  assert string.contains(testing.text(res), "\"code\":\"token_sent\"")
}

pub fn flows_give_their_errors_codes_test() {
  use _, identity, _, mailbox <- fixture
  let identity = auth.with_locales(identity, locales())
  let session = support.signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let assert Error(error) =
    auth.set_locale(identity, principal, locale: Some("ja"))
  assert service.code(error) == "locale_unsupported"
  assert service.uncoded(error) == service.Invalid("unsupported locale")
}

pub fn oversized_passwords_report_the_maximum_in_the_page_words_test() {
  use _, identity, permissions, _ <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let response =
    testing.post(
      "/api/auth/password/register",
      json.object([
        #("email", json.string("ada@example.com")),
        #("password", json.string(string.repeat("a", 1025))),
      ]),
    )
    |> testing.header("origin", "https://example.test")
    |> testing.send(app(identity, permissions))
  assert response.status == 400
  assert testing.error(response)
    == Ok("password must contain at most 1024 UTF-8 bytes")
  assert json.parse(
      testing.text(response),
      decode.field("code", decode.string, decode.success),
    )
    == Ok("password_too_long")
  let words = pages.words_json(identity, i18n.new("en"))
  assert json.parse(
      words,
      decode.field("error.password_too_long", decode.string, decode.success),
    )
    == Ok("Choose a password with at most 1,024 UTF-8 bytes.")
}

pub fn registration_remembers_the_locale_test() {
  use _, identity, permissions, mailbox <- fixture
  let identity = auth.with_locales(identity, locales())
  let app = app(identity, permissions)
  let res =
    testing.post(
      "/api/auth/register",
      json.object([#("email", json.string("ada@example.com"))]),
    )
    |> testing.header("origin", "https://example.test")
    |> in("de")
    |> testing.send(app)
  assert res.status == 202
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  // The registration email is written in the request's locale.
  assert delivery.locale == Some("de")
  let session =
    testing.post(
      "/api/auth/session",
      json.object([#("token", json.string(secret.reveal(delivery.token)))]),
    )
    |> testing.header("origin", "https://example.test")
    |> in("de")
    |> testing.send(app)
  assert session.status == 200
  let assert Ok(principal) =
    auth.authenticate(identity, session_secret(identity, session))
  assert principal.user.locale == Some("de")
  // Later emails use the stored locale whatever the request says.
  let assert Ok(Nil) =
    auth.request_token(identity, "ada@example.com", auth.Login)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert delivery.locale == Some("de")
}

fn session_secret(identity, response) {
  let name = auth.cookie_name(identity)
  let assert Ok(#(_, value)) =
    testing.cookies(response)
    |> list_find(fn(c: #(String, String)) { c.0 == name })
  value
}

fn list_find(items, predicate) {
  list.find(items, predicate)
}

pub fn users_can_choose_their_locale_test() {
  use _, identity, permissions, mailbox <- fixture
  let identity = auth.with_locales(identity, locales())
  let session = support.signup(identity, mailbox, "ada@example.com")
  let app = app(identity, permissions)
  let cookie = secret.reveal(session.token)
  let choose = fn(value) {
    testing.post("/api/auth/locale", json.object([#("locale", value)]))
    |> testing.cookie(auth.cookie_name(identity), cookie)
    |> testing.header("origin", "https://example.test")
    |> testing.send(app)
  }
  assert { choose(json.string("ar")) }.status == 204
  let assert Ok(principal) = auth.authenticate(identity, cookie)
  assert principal.user.locale == Some("ar")
  // The account page offers the choice, and the source reads it back.
  let page =
    testing.get("/auth/account")
    |> testing.cookie(auth.cookie_name(identity), cookie)
    |> testing.send(app)
  assert string.contains(testing.text(page), "id=\"locale-form\"")
  let source = auth.locale_source(identity)
  let req =
    testing.get("/") |> testing.cookie(auth.cookie_name(identity), cookie)
  assert source(req) == Some("ar")
  let unsupported = choose(json.string("ja"))
  assert unsupported.status == 400
  assert string.contains(testing.text(unsupported), "locale_unsupported")
  assert { choose(json.null()) }.status == 204
  let assert Ok(principal) = auth.authenticate(identity, cookie)
  assert principal.user.locale == None
}

pub fn emails_are_written_in_the_delivery_locale_test() {
  let box = outbox.start()
  let mailer =
    mail.mailer(outbox.adapter(box))
    |> mail.default_from(mail.named("Acme", "hello@acme.test"))
  let deliver = emails.deliver(emails.new(mailer, app_name: "Acme"))
  let delivery = fn(locale) {
    auth.Delivery(
      email: "ada@example.com",
      token: secret.wrap("tok-123"),
      purpose: auth.SignIn,
      link: None,
      code: Some(secret.wrap("123456")),
      locale:,
    )
  }
  let assert Ok(Nil) = deliver(delivery(Some("de")))
  let assert Ok(sent) = outbox.latest_to(box, "ada@example.com")
  assert sent.subject == "Bei Acme anmelden"
  let assert Some(text) = sent.text
  assert string.contains(text, "Oder geben Sie diesen Code ein: 123456")
  let assert Some(html) = sent.html
  assert string.contains(html, "lang=\"de\"")
  let assert Ok(Nil) = deliver(delivery(Some("ar")))
  let assert Ok(sent) = outbox.latest_to(box, "ada@example.com")
  let assert Some(html) = sent.html
  assert string.contains(html, "dir=\"rtl\"")
  let assert Ok(Nil) = deliver(delivery(None))
  let assert Ok(sent) = outbox.latest_to(box, "ada@example.com")
  assert sent.subject == "Sign in to Acme"
}

pub fn previews_in_each_locale_test() {
  let mailer = mail.mailer(outbox.adapter(outbox.start()))
  let previews =
    emails.previews_in(emails.new(mailer, app_name: "Acme"), ["de", "ja"])
  assert list.length(previews) == 16
}
