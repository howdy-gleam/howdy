import gleam/list
import gleam/string
import howdy/i18n
import howdy/locale
import howdy/ui/calendar
import howdy/ui/carousel
import howdy/ui/chart
import howdy/ui/data_table
import howdy/ui/direction
import howdy/ui/pagination
import howdy/ui/questionnaire
import howdy/ui/toast
import howdy/ui/words
import lustre/element.{type Element, text}

fn render(element: Element(msg)) -> String {
  element.to_string(element)
}

fn page_links(w: words.Words) -> String {
  render(pagination.pagination(w, current: 2, total: 12, href: fn(_) { "#" }))
}

pub fn english_is_unchanged_test() {
  let html = page_links(words.english())
  assert string.contains(html, "aria-label=\"Pagination\"")
  assert string.contains(html, "Previous")
  assert string.contains(html, "Next")
  assert string.contains(html, ">12</a>")
  let w = words.english()
  assert w.locale == "en"
  assert w.position(2, 5) == "2 of 5"
  assert w.question_count(1, 3) == "Question 1 of 3"
  assert w.decimal(1234.567) == "1,234.57"
  assert w.decimal(3.0) == "3"
  assert w.percent(0.25) == "25%"
  assert w.remove("Gleam") == "Remove Gleam"
  assert w.calendar.heading(2026, 10) == "October 2026"
  assert w.calendar.date_label(calendar.Date(2026, 10, 19)) == "19 October 2026"
  assert chart.format_number(1_234_567.0) == "1,234,567"
}

pub fn pagination_in_german_test() {
  let html = page_links(words.translated(i18n.new("de")))
  assert string.contains(html, "aria-label=\"Seitennavigation\"")
  assert string.contains(html, "Zurück")
  assert string.contains(html, "Weiter")
  assert !string.contains(html, "Previous")
}

pub fn pagination_in_arabic_test() {
  let w = words.translated(i18n.new("ar"))
  let html = page_links(w)
  assert string.contains(html, "السابق")
  assert string.contains(html, "التالي")
  assert w.locale == "ar"
  assert w.position(2, 5) == "2 من 5"
}

pub fn locales_without_a_catalogue_keep_their_numbers_test() {
  // Swedish has no catalogue, so the words are English, but numbers are
  // written the Swedish way.
  let w = words.translated(i18n.new("sv"))
  assert w.next_page == "Next"
  assert w.number(12_345) == "12\u{00A0}345"
  assert w.locale == "sv"
}

pub fn persian_digits_test() {
  let w = words.translated(i18n.new("fa"))
  assert w.number(12) == "۱۲"
}

pub fn calendar_heading_uses_the_standalone_month_test() {
  let w = words.translated(i18n.new("pl"))
  let html =
    calendar.new("due", year: 2026, month: 10)
    |> calendar.locale(w.calendar)
    |> calendar.view
    |> render
  // On its own, October is "październik"; inside a date, "października".
  assert string.contains(html, "październik 2026")
  assert string.contains(html, "19 października 2026")
  assert string.contains(html, "abbr=\"poniedziałek\"")
}

pub fn calendar_starts_the_week_where_the_locale_does_test() {
  let heading = fn(w: words.Words) {
    let html =
      calendar.new("due", year: 2026, month: 10)
      |> calendar.locale(w.calendar)
      |> calendar.view
      |> render
    let assert Ok(#(_, after)) = string.split_once(html, "<th")
    after
  }
  // The US starts weeks on Sunday, Germany on Monday.
  assert string.contains(
    heading(words.translated(i18n.new("en-US"))),
    "abbr=\"Sunday\"",
  )
  let first_de = heading(words.translated(i18n.new("de")))
  assert string.starts_with(
    first_de |> string.split("abbr=\"") |> list.drop(1) |> string.join(""),
    "Montag",
  )
  // English words keep Monday first, and `sunday_first` still wins.
  let html =
    calendar.new("due", year: 2026, month: 10)
    |> calendar.locale(words.translated(i18n.new("de")).calendar)
    |> calendar.sunday_first
    |> calendar.view
    |> render
  let assert Ok(#(_, after)) = string.split_once(html, "abbr=\"")
  assert string.starts_with(after, "Sonntag")
}

pub fn components_speak_the_words_test() {
  let w = words.translated(i18n.new("fr"))
  let region = render(toast.region(w, [], []))
  assert string.contains(region, "aria-label=\"Notifications\"")
  let table =
    data_table.new([], [])
    |> data_table.words(w)
    |> data_table.view
    |> render
  assert string.contains(table, "Aucun résultat.")
  let slides =
    render(
      carousel.carousel(w, "tour", label: "Visite", attributes: [], slides: [
        carousel.slide([text("A")]),
        carousel.slide([text("B")]),
      ]),
    )
  assert string.contains(slides, "aria-roledescription=\"carrousel\"")
  assert string.contains(slides, "aria-label=\"1 sur 2\"")
  assert string.contains(slides, "data-text-play=\"Lire les diapositives\"")
  let pie =
    chart.donut(title: "Parts", labels: ["A", "B"], values: [1500.0, 500.0])
    |> chart.words(w)
    |> chart.view
    |> render
  assert string.contains(pie, "Afficher les données")
  assert string.contains(pie, "75\u{00A0}%")
  assert string.contains(pie, "2\u{202F}000")
}

pub fn questionnaire_reasons_test() {
  let questions = [
    questionnaire.question("name", "Name?", questionnaire.Short)
    |> questionnaire.required,
  ]
  let asked =
    questionnaire.submit(questions, [
      #("questionnaire-step", "0"),
      #("questionnaire-action", "next"),
    ])
  let html =
    render(questionnaire.view(words.translated(i18n.new("de")), asked, []))
  assert string.contains(html, "Frage 1 von 1")
  assert string.contains(html, "Beantworten Sie diese Frage, um fortzufahren.")
  assert string.contains(html, "Fertig")
}

pub fn direction_of_a_locale_test() {
  let assert Ok(ar) = locale.parse("ar-EG")
  let assert Ok(de) = locale.parse("de")
  assert direction.of(ar) == direction.Rtl
  assert direction.of(de) == direction.Ltr
  assert direction.of_tag("he") == direction.Rtl
  assert direction.of_tag("!!") == direction.Ltr
}

pub fn every_locale_has_a_catalogue_test() {
  assert list.contains(words.locales(), "en")
  assert list.length(words.locales()) == 11
}
