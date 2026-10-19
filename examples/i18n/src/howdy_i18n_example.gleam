//// A small app in English, German, French and Arabic. Run with `gleam run`
//// from `examples/i18n`; it listens on 127.0.0.1:8793. Then try:
////
//// ```sh
//// curl -i http://localhost:8793/ -H 'accept-language: de-CH, en;q=0.5'   # 303 to /de/
//// curl http://localhost:8793/fr/?items=3
//// curl http://localhost:8793/ar/                                        # dir="rtl"
//// curl http://localhost:8793/de/signup -d 'name=&email=nope&password=abc'
//// ```
////
//// The messages live in `locales/*.json`. After changing them, regenerate
//// `src/howdy_i18n_example/messages.gleam` with
//// `gleam run -m howdy/i18n/cli -- gen`.

import gleam/dict
import gleam/erlang/process
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import howdy
import howdy/content.{type Content}
import howdy/controller.{type Context}
import howdy/form.{type Form}
import howdy/i18n.{type Translator}
import howdy/i18n/format
import howdy/locale.{type Locale}
import howdy/problem
import howdy/query
import howdy/service.{type FieldError}
import howdy/validate
import howdy_i18n_example/messages
import logging

/// The supported locales are the catalogues there are. A locale comes from
/// the path, then the visitor's choice, then their browser.
pub fn locales() -> locale.Negotiator {
  locale.negotiator(messages.locales, default: messages.source)
  |> locale.from_param("locale")
  |> locale.from_cookie("locale")
  |> locale.from_accept_language
}

pub fn app() -> howdy.App {
  let locales = locales()
  howdy.new()
  |> howdy.middleware(locale.middleware(locales))
  |> howdy.controller(
    controller.new("/")
    |> controller.get("/", fn(ctx) {
      redirect(ctx, "/" <> locale.to_string(locale.detect(ctx, locales)) <> "/")
    })
    |> controller.post("/locale", fn(ctx) { choose(ctx, locales) }),
  )
  |> howdy.controller(
    controller.new("/:locale")
    |> controller.get("/", fn(ctx) { home(ctx, locales) })
    |> controller.post("/signup", fn(ctx) { signup(ctx, locales) }),
  )
}

fn home(ctx: Context, locales: locale.Negotiator) {
  use l <- with_locale(ctx, locales)
  use items <- query.int_or(ctx, "items", default: 0)
  let t = translator(l)
  controller.html(ctx, page(l, t, body(t, items, None, [])))
}

fn signup(ctx: Context, locales: locale.Negotiator) {
  use l <- with_locale(ctx, locales)
  use fields <- form.read(ctx)
  let t = translator(l)
  case validate_signup(fields) {
    Ok(name) ->
      controller.html(
        ctx,
        page(l, t, "<p>" <> escape(messages.signup_welcome(t, name:)) <> "</p>"),
      )
    Error(errors) ->
      controller.html(ctx, page(l, t, body(t, 0, Some(#(fields, l)), errors)))
      |> controller.with_status(422)
  }
}

fn validate_signup(fields: Form) -> validate.Result(String) {
  use name <- form.string(fields, "name", [
    validate.trim(),
    validate.not_empty(),
  ])
  use _ <- form.string(fields, "email", [validate.trim(), validate.email()])
  use _ <- form.string(fields, "password", [validate.min_length(8)])
  validate.ok(name)
}

/// Store the visitor's choice in the cookie the negotiator reads, and go
/// to the page in that language.
fn choose(ctx: Context, locales: locale.Negotiator) {
  use fields <- form.read(ctx)
  case locale.match(locales, form.value(fields, "locale")) {
    Some(chosen) ->
      redirect(ctx, "/" <> locale.to_string(chosen) <> "/")
      |> locale.remember(locales, chosen)
    None -> controller.status(ctx, 400)
  }
}

/// The locale for a page under `/:locale`. A path naming a locale we do
/// not have is a 404, rather than a page in some other language.
fn with_locale(
  ctx: Context,
  locales: locale.Negotiator,
  next: fn(Locale) -> Response(Content),
) -> Response(Content) {
  let wanted = dict.get(ctx.params, "locale") |> result.unwrap("")
  let found = locale.match(locales, wanted)
  case option.map(found, locale.to_string) == Some(wanted), found {
    True, Some(found) -> next(found)
    _, _ -> controller.status(ctx, 404)
  }
}

fn translator(l: Locale) -> Translator {
  i18n.new(locale.to_string(l))
}

fn redirect(ctx: Context, to: String) {
  controller.status(ctx, 303)
  |> response.set_header("location", to)
}

// -- Pages -------------------------------------------------------------------

fn page(l: Locale, t: Translator, content: String) -> String {
  let dir = case locale.right_to_left(l) {
    True -> "rtl"
    False -> "ltr"
  }
  "<!doctype html><html lang=\""
  <> locale.to_string(l)
  <> "\" dir=\""
  <> dir
  <> "\"><head><meta charset=\"utf-8\"><title>"
  <> escape(messages.title(t))
  <> "</title></head><body><main>"
  <> switcher(l, t)
  <> content
  <> "</main></body></html>"
}

fn switcher(current: Locale, t: Translator) -> String {
  let options =
    locale.supported(locales())
    |> list.map(fn(l) {
      let tag = locale.to_string(l)
      let name = i18n.language_name(tag) |> result.unwrap(tag)
      let selected = case l == current {
        True -> " selected"
        False -> ""
      }
      "<option value=\""
      <> tag
      <> "\""
      <> selected
      <> ">"
      <> escape(name)
      <> "</option>"
    })
    |> string.concat
  "<form method=\"post\" action=\"/locale\"><label>"
  <> escape(messages.language(t))
  <> " <select name=\"locale\">"
  <> options
  <> "</select></label> <button>"
  <> escape(messages.change(t))
  <> "</button></form>"
}

fn body(
  t: Translator,
  items: Int,
  submitted: Option(#(Form, Locale)),
  errors: List(FieldError),
) -> String {
  let today =
    timestamp.system_time() |> timestamp.to_calendar(calendar.utc_offset)
  let words = case submitted {
    Some(#(_, l)) -> problem.translated(l)
    None -> problem.english()
  }
  let value = fn(name) {
    case submitted {
      Some(#(fields, _)) -> form.value(fields, name)
      None -> ""
    }
  }
  let field = fn(name, label, kind) {
    let error = case form.error(errors, name) {
      Some(found) ->
        "<p class=\"error\">" <> escape(problem.message(found, words)) <> "</p>"
      None -> ""
    }
    "<p><label>"
    <> escape(label)
    <> " <input type=\""
    <> kind
    <> "\" name=\""
    <> name
    <> "\" value=\""
    <> escape(value(name))
    <> "\"></label></p>"
    <> error
  }
  string.concat([
    "<h1>",
    escape(messages.greeting(t, name: "Ada")),
    "</h1><p>",
    escape(messages.cart(t, count: items)),
    " ",
    escape(messages.total(
      t,
      amount: format.currency(t, minor: items * 1999, code: "EUR"),
    )),
    "</p><p>",
    escape(messages.updated(t, ago: format.relative(t, -3, format.Day))),
    "</p><p>",
    escape(messages.today(t, date: today.0)),
    "</p><p>",
    escape(messages.team(t, names: format.list(t, ["Ada", "Grace", "Linus"]))),
    "</p><h2>",
    escape(messages.signup_heading(t)),
    "</h2><form method=\"post\" action=\"signup\">",
    field("name", messages.signup_name(t), "text"),
    field("email", messages.signup_email(t), "text"),
    field("password", messages.signup_password(t), "password"),
    "<button>",
    escape(messages.signup_submit(t)),
    "</button></form>",
  ])
}

fn escape(text: String) -> String {
  text
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
}

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Info)
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(howdy.supervised(
      app() |> howdy.bind(to: "127.0.0.1") |> howdy.listening(on: 8793),
    ))
    |> howdy.start_application(name: "howdy_i18n_example_server")
  process.sleep_forever()
}
