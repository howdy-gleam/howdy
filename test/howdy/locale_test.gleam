import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import howdy
import howdy/controller
import howdy/locale
import howdy/testing

fn tag(text: String) -> String {
  let assert Ok(parsed) = locale.parse(text)
  locale.to_string(parsed)
}

pub fn parse_normalises_case_test() {
  assert tag("EN-us") == "en-US"
  assert tag("zh-hant-tw") == "zh-Hant-TW"
  assert tag("pt_BR") == "pt-BR"
  assert tag("es-419") == "es-419"
  assert tag("abcd") == "abcd"
  assert tag(" de ") == "de"
}

pub fn parse_drops_variants_and_extensions_test() {
  assert tag("de-DE-u-co-phonebk") == "de-DE"
  assert tag("sl-rozaj") == "sl"
}

pub fn parse_rejects_nonsense_test() {
  assert locale.parse("") == Error(Nil)
  assert locale.parse("*") == Error(Nil)
  assert locale.parse("e") == Error(Nil)
  assert locale.parse("12") == Error(Nil)
  assert locale.parse("en!") == Error(Nil)
}

pub fn parts_test() {
  let assert Ok(l) = locale.parse("zh-Hant-TW")
  assert locale.language(l) == "zh"
  assert locale.script(l) == Some("Hant")
  assert locale.region(l) == Some("TW")
  assert list.map(locale.fallbacks(l), locale.to_string)
    == ["zh-Hant-TW", "zh-Hant", "zh"]
  let assert Ok(l) = locale.parse("de-CH")
  assert list.map(locale.fallbacks(l), locale.to_string) == ["de-CH", "de"]
}

pub fn right_to_left_test() {
  let rtl = fn(text) {
    let assert Ok(l) = locale.parse(text)
    locale.right_to_left(l)
  }
  assert rtl("ar")
  assert rtl("he-IL")
  assert rtl("fa")
  assert !rtl("en")
  assert !rtl("ku-Latn")
  assert rtl("az-Arab")
}

pub fn accept_language_orders_by_quality_test() {
  assert locale.accept_language("da, en-GB;q=0.8, en;q=0.7")
    == ["da", "en-GB", "en"]
  assert locale.accept_language("en;q=0.5, fr, de;q=0.9") == ["fr", "de", "en"]
  // Equal qualities keep their order; q=0 and * are dropped.
  assert locale.accept_language("fr;q=0.5,de;q=0.5,*;q=0.1,it;q=0")
    == ["fr", "de"]
  assert locale.accept_language("") == []
  assert locale.accept_language("en;q=1") == ["en"]
}

fn negotiator() {
  locale.negotiator(["en", "de", "fr-CA", "en-GB"], default: "en")
}

fn matched(text: String) {
  locale.match(negotiator(), text) |> option.map(locale.to_string)
}

pub fn match_test() {
  assert matched("de") == Some("de")
  // Lookup falls back from a region to its language.
  assert matched("de-CH") == Some("de")
  assert matched("en-GB") == Some("en-GB")
  assert matched("en-AU") == Some("en")
  // A bare language takes a regional locale when there is no bare one.
  assert matched("fr") == Some("fr-CA")
  assert matched("fr-FR") == Some("fr-CA")
  assert matched("ja") == None
  assert matched("nonsense!") == None
}

pub fn default_is_supported_test() {
  let n = locale.negotiator(["de"], default: "en")
  assert list.map(locale.supported(n), locale.to_string) == ["de", "en"]
  assert locale.to_string(locale.default(n)) == "en"
  assert locale.to_string(locale.negotiate(n, ["ja", "en-US"])) == "en"
  assert locale.to_string(locale.negotiate(n, [])) == "en"
}

fn app(n: locale.Negotiator) -> howdy.App {
  let show = fn(ctx) {
    controller.text(ctx, locale.to_string(locale.detect(ctx, n)))
  }
  howdy.new()
  |> howdy.controller(
    controller.new("/")
    |> controller.get("/", show)
    |> controller.get("/:locale/page", show),
  )
}

fn detected(req, n) {
  testing.text(testing.send(req, app(n)))
}

pub fn sources_are_tried_in_order_test() {
  let n =
    negotiator()
    |> locale.from_param("locale")
    |> locale.from_query("lang")
    |> locale.from_cookie("locale")
    |> locale.from_accept_language
  let browser = testing.header(_, "accept-language", "fr-FR, de;q=0.5")
  assert detected(testing.get("/") |> browser, n) == "fr-CA"
  assert detected(
      testing.get("/") |> browser |> testing.cookie("locale", "de"),
      n,
    )
    == "de"
  assert detected(
      testing.get("/")
        |> browser
        |> testing.cookie("locale", "de")
        |> testing.query([#("lang", "en-GB")]),
      n,
    )
    == "en-GB"
  assert detected(
      testing.get("/de/page") |> testing.query([#("lang", "en")]),
      n,
    )
    == "de"
}

pub fn unsupported_choices_fall_through_test() {
  let n =
    negotiator()
    |> locale.from_param("locale")
    |> locale.from_cookie("locale")
    |> locale.from_accept_language
  // The cookie names nothing supported, so the header decides.
  let req =
    testing.get("/ja/page")
    |> testing.cookie("locale", "xx")
    |> testing.header("accept-language", "ja, de;q=0.3")
  assert detected(req, n) == "de"
  assert detected(testing.get("/"), n) == "en"
}

pub fn path_segment_and_custom_test() {
  let n = negotiator() |> locale.from_path_segment
  assert detected(testing.get("/de/page"), n) == "de"
  assert detected(testing.get("/"), n) == "en"
  let n = negotiator() |> locale.from(fn(_) { Some("en-GB") })
  assert detected(testing.get("/"), n) == "en-GB"
  let n = negotiator() |> locale.from(fn(_) { None })
  assert detected(testing.get("/"), n) == "en"
}

pub fn middleware_stamps_responses_test() {
  let n =
    negotiator()
    |> locale.from_path_segment
    |> locale.from_cookie("locale")
    |> locale.from_accept_language
  let app = app(n) |> howdy.middleware(locale.middleware(n))
  let res =
    testing.get("/")
    |> testing.header("accept-language", "de")
    |> testing.send(app)
  assert response.get_header(res, "content-language") == Ok("de")
  assert response.get_header(res, "vary") == Ok("cookie, accept-language")
}

pub fn middleware_keeps_handler_headers_test() {
  let n = negotiator() |> locale.from_accept_language
  let app =
    howdy.new()
    |> howdy.controller(
      controller.new("/")
      |> controller.get("/", fn(ctx) {
        controller.text(ctx, "hi")
        |> response.set_header("content-language", "fr-CA")
        |> response.set_header("vary", "Accept-Language")
      }),
    )
    |> howdy.middleware(locale.middleware(n))
  let res = testing.send(testing.get("/"), app)
  assert response.get_header(res, "content-language") == Ok("fr-CA")
  assert response.get_header(res, "vary") == Ok("Accept-Language")
}

pub fn remember_sets_the_cookie_test() {
  let n = negotiator() |> locale.from_cookie("lang")
  let assert Ok(de) = locale.parse("de")
  let res = response.new(200) |> locale.remember(n, de)
  let assert Ok(header) = response.get_header(res, "set-cookie")
  let assert [first, ..] = string.split(header, ";")
  assert first == "lang=de"
}

pub fn malformed_qualities_are_ignored_test() {
  assert locale.accept_language("de;q=2,fr;q=bogus,en;q=0.5") == ["en"]
  assert locale.accept_language("de;q=-1,fr;q=0.1234,en;q=1.001") == []
  assert locale.accept_language("de;q=0.125,fr;q=1.000,en;q=0") == ["fr", "de"]
}

pub fn custom_sources_do_not_assume_cookie_cache_variation_test() {
  let n =
    negotiator()
    |> locale.from_cookie("locale")
    |> locale.from(fn(req) {
      request.get_header(req, "x-language") |> option.from_result
    })
    |> locale.from_accept_language
  let app = app(n) |> howdy.middleware(locale.middleware(n))
  let res =
    testing.get("/")
    |> testing.header("x-language", "de")
    |> testing.send(app)
  assert response.get_header(res, "content-language") == Ok("de")
  assert response.get_header(res, "vary") == Ok("*")
}
