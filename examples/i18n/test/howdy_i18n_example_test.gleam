import gleam/http/response
import gleam/string
import gleeunit
import howdy/testing
import howdy_i18n_example as example

pub fn main() -> Nil {
  gleeunit.main()
}

fn get(path: String) {
  testing.get(path) |> testing.send(example.app())
}

pub fn root_redirects_to_the_browsers_language_test() {
  let res =
    testing.get("/")
    |> testing.header("accept-language", "de-CH, en;q=0.5")
    |> testing.send(example.app())
  assert res.status == 303
  assert response.get_header(res, "location") == Ok("/de/")
  assert response.get_header(res, "vary") == Ok("cookie, accept-language")
}

pub fn a_chosen_language_beats_the_browser_test() {
  let res =
    testing.get("/")
    |> testing.header("accept-language", "de")
    |> testing.cookie("locale", "fr")
    |> testing.send(example.app())
  assert response.get_header(res, "location") == Ok("/fr/")
}

pub fn unsupported_languages_get_the_default_test() {
  let res =
    testing.get("/")
    |> testing.header("accept-language", "ja")
    |> testing.send(example.app())
  assert response.get_header(res, "location") == Ok("/en/")
}

pub fn pages_are_translated_test() {
  let res = get("/de/?items=3")
  assert res.status == 200
  assert response.get_header(res, "content-language") == Ok("de")
  let html = testing.text(res)
  assert string.contains(html, "<html lang=\"de\" dir=\"ltr\">")
  assert string.contains(html, "Hallo, Ada!")
  assert string.contains(html, "Sie haben 3 Artikel im Warenkorb.")
  assert string.contains(html, "Summe: 59,97\u{00A0}€")
  assert string.contains(html, "Preise zuletzt geändert vor 3 Tagen.")
  assert string.contains(html, "Gemacht von Ada, Grace und Linus.")
  assert string.contains(html, "<option value=\"fr\">français</option>")
}

pub fn english_plurals_test() {
  assert string.contains(testing.text(get("/en/")), "Your basket is empty.")
  assert string.contains(
    testing.text(get("/en/?items=1")),
    "You have 1 item in your basket. Total: €19.99",
  )
}

pub fn arabic_runs_right_to_left_test() {
  let html = testing.text(get("/ar/?items=2"))
  assert string.contains(html, "<html lang=\"ar\" dir=\"rtl\">")
  assert string.contains(html, "في سلتك عنصران.")
}

pub fn unknown_locales_are_not_found_test() {
  assert get("/xx/").status == 404
  // A supported locale must be spelt as it is listed.
  assert get("/de-CH/").status == 404
}

pub fn validation_messages_are_translated_test() {
  let res =
    testing.post_form("/de/signup", [
      #("name", " "),
      #("email", "nope"),
      #("password", "abc"),
    ])
    |> testing.send(example.app())
  assert res.status == 422
  let html = testing.text(res)
  assert string.contains(html, "darf nicht leer sein")
  assert string.contains(html, "muss eine gültige E-Mail-Adresse sein")
  assert string.contains(html, "muss mindestens 8 Zeichen lang sein")
  // What was typed is kept, escaped.
  assert string.contains(html, "value=\"nope\"")
}

pub fn signing_up_test() {
  let res =
    testing.post_form("/fr/signup", [
      #("name", "Ada"),
      #("email", "ada@example.com"),
      #("password", "correct horse"),
    ])
    |> testing.send(example.app())
  assert res.status == 200
  assert string.contains(testing.text(res), "Bienvenue, Ada\u{00A0}!")
}

pub fn choosing_a_language_test() {
  let res =
    testing.post_form("/locale", [#("locale", "ar")])
    |> testing.send(example.app())
  assert res.status == 303
  assert response.get_header(res, "location") == Ok("/ar/")
  assert testing.cookies(res) == [#("locale", "ar")]
  let res =
    testing.post_form("/locale", [#("locale", "nonsense")])
    |> testing.send(example.app())
  assert res.status == 400
}
