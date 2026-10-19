//// Words: everything howdy_ui's components say, in one language.
////
//// ```gleam
//// let t = i18n.new(locale.to_string(locale.detect(ctx, locales)))
//// let w = words.translated(t)
////
//// pagination.pagination(w, current: 3, total: 12, href: page_href)
//// toast.region(w, [], toasts)
//// calendar.new("due", year: 2026, month: 9) |> calendar.locale(w.calendar)
//// data_table.new(columns, rows) |> data_table.words(w)
//// ```
////
//// Components that are plain functions take the words as their first
//// argument; those built step by step take them with a `words` step and
//// speak English without one. Calendars, uploaders and attachments keep
//// their own words, which are fields here.
////
//// `english` is what the components have always said. `translated` gives
//// the words for a translator's locale from howdy_ui's catalogues, with
//// numbers, dates and the first day of the week from CLDR; locales without
//// a catalogue fall back to English words with their own number formats.
//// The catalogues were machine translated and are waiting for review by
//// native speakers. Change a few words with a record update:
//// `Words(..words.english(), dismiss: "Close")`.
////
//// The catalogues live in `ui/locales`. After changing them, regenerate
//// `howdy/ui/internal/messages` from the `i18n` directory:
////
//// ```sh
//// gleam run -m howdy/i18n/cli -- gen --locales=../ui/locales --out=../ui/src/howdy/ui/internal/messages.gleam
//// ```

import gleam/float
import gleam/int
import gleam/string
import gleam/time/calendar as time_calendar
import howdy/i18n.{type Translator}
import howdy/i18n/format
import howdy/ui/attachment
import howdy/ui/calendar
import howdy/ui/internal/messages
import howdy/ui/uploader

pub type Words {
  Words(
    /// The BCP 47 tag of the words' language, such as `de`.
    locale: String,
    /// A whole number, such as a page number.
    number: fn(Int) -> String,
    /// A value in a chart: thousands separators and at most two decimal
    /// places.
    decimal: fn(Float) -> String,
    /// A share of a whole, given as a fraction, such as `0.25` for 25%.
    percent: fn(Float) -> String,
    /// A position in a sequence, such as "2 of 5", given the position and
    /// the count.
    position: fn(Int, Int) -> String,
    /// Pagination: the navigation's name and the links on either side.
    pagination: String,
    previous_page: String,
    next_page: String,
    breadcrumb: String,
    /// Toasts: the region's name and each toast's close button.
    notifications: String,
    dismiss: String,
    /// Command menus and comboboxes.
    command_menu: String,
    clear: String,
    /// The remove button on a chosen option's chip, given its label.
    remove: fn(String) -> String,
    /// Data tables.
    no_results: String,
    select_row: String,
    select_all_rows: String,
    /// Carousels: what a screen reader calls a carousel and a slide, and
    /// the buttons.
    carousel: String,
    slide: String,
    previous_slide: String,
    next_slide: String,
    pause_slides: String,
    play_slides: String,
    /// A drawer's handle.
    resize: String,
    /// The button that appears in a conversation scrolled back from the
    /// newest message.
    jump_to_newest: String,
    /// Charts: the button that shows the table, the label in a donut's
    /// middle, and a value out of a maximum, given both written out.
    show_data: String,
    total: String,
    out_of: fn(String, String) -> String,
    /// A range slider's two thumbs.
    minimum: String,
    maximum: String,
    /// Questionnaires: "Question 2 of 5", given the number and the count,
    /// the progress bar, the buttons, and why an answer was not accepted.
    question_count: fn(Int, Int) -> String,
    progress: String,
    back: String,
    skip: String,
    next: String,
    finish: String,
    answer_required: String,
    choose_one: String,
    choose_from: String,
    choose_on_scale: String,
    give_one_answer: String,
    /// A label for a spinner.
    loading: String,
    calendar: calendar.Locale,
    uploader: uploader.Words,
    attachment: attachment.Words,
  )
}

/// The words in English.
pub fn english() -> Words {
  Words(
    locale: "en",
    number: int.to_string,
    decimal: english_decimal,
    percent: fn(share) { int.to_string(float.round(share *. 100.0)) <> "%" },
    position: fn(index, count) {
      int.to_string(index) <> " of " <> int.to_string(count)
    },
    pagination: "Pagination",
    previous_page: "Previous",
    next_page: "Next",
    breadcrumb: "Breadcrumb",
    notifications: "Notifications",
    dismiss: "Dismiss",
    command_menu: "Command menu",
    clear: "Clear",
    remove: fn(label) { "Remove " <> label },
    no_results: "No results.",
    select_row: "Select row",
    select_all_rows: "Select all rows",
    carousel: "carousel",
    slide: "slide",
    previous_slide: "Previous slide",
    next_slide: "Next slide",
    pause_slides: "Pause slides",
    play_slides: "Play slides",
    resize: "Resize",
    jump_to_newest: "Jump to newest",
    show_data: "Show data",
    total: "Total",
    out_of: fn(value, max) { value <> " of " <> max },
    minimum: "minimum",
    maximum: "maximum",
    question_count: fn(number, count) {
      "Question " <> int.to_string(number) <> " of " <> int.to_string(count)
    },
    progress: "Progress",
    back: "Back",
    skip: "Skip",
    next: "Next",
    finish: "Finish",
    answer_required: "Answer this to go on.",
    choose_one: "Choose one of the options.",
    choose_from: "Choose from the options.",
    choose_on_scale: "Choose a number on the scale.",
    give_one_answer: "Give one answer.",
    loading: "Loading",
    calendar: calendar.english(),
    uploader: uploader.english(),
    attachment: attachment.english(),
  )
}

/// The words for a translator's locale.
pub fn translated(translator t: Translator) -> Words {
  Words(
    locale: i18n.locale(t),
    number: format.integer(t, _),
    decimal: fn(value) { format.decimal(t, float.to_precision(value, 2)) },
    percent: format.percent(t, _),
    position: fn(index, count) { messages.position(t, index:, count:) },
    pagination: messages.pagination(t),
    previous_page: messages.previous_page(t),
    next_page: messages.next_page(t),
    breadcrumb: messages.breadcrumb(t),
    notifications: messages.notifications(t),
    dismiss: messages.dismiss(t),
    command_menu: messages.command_menu(t),
    clear: messages.clear(t),
    remove: fn(item) { messages.remove_item(t, item:) },
    no_results: messages.no_results(t),
    select_row: messages.select_row(t),
    select_all_rows: messages.select_all_rows(t),
    carousel: messages.carousel(t),
    slide: messages.slide(t),
    previous_slide: messages.previous_slide(t),
    next_slide: messages.next_slide(t),
    pause_slides: messages.pause_slides(t),
    play_slides: messages.play_slides(t),
    resize: messages.resize(t),
    jump_to_newest: messages.jump_to_newest(t),
    show_data: messages.show_data(t),
    total: messages.total(t),
    out_of: fn(value, max) { messages.out_of(t, value:, max:) },
    minimum: messages.minimum(t),
    maximum: messages.maximum(t),
    question_count: fn(number, count) {
      messages.question_count(t, number:, count:)
    },
    progress: messages.progress(t),
    back: messages.back(t),
    skip: messages.skip(t),
    next: messages.next(t),
    finish: messages.finish(t),
    answer_required: messages.answer_required(t),
    choose_one: messages.choose_one(t),
    choose_from: messages.choose_from(t),
    choose_on_scale: messages.choose_on_scale(t),
    give_one_answer: messages.give_one_answer(t),
    loading: messages.loading(t),
    calendar: calendar_words(t),
    uploader: uploader_words(t),
    attachment: attachment.Words(
      uploading: fn(name) { messages.uploading_file(t, name:) },
      processing: messages.processing(t),
    ),
  )
}

/// Month and weekday names, the first day of the week and the date format
/// from CLDR; the buttons' labels from the catalogues.
fn calendar_words(t: Translator) -> calendar.Locale {
  calendar.Locale(
    weekday_names: format.weekdays(t, format.Wide),
    weekday_abbreviations: format.weekdays(t, format.Narrow),
    heading: fn(year, month) { format.month_year(t, year, time_month(month)) },
    date_label: fn(date: calendar.Date) {
      format.date(
        t,
        time_calendar.Date(date.year, time_month(date.month), date.day),
        format.Long,
      )
    },
    day_number: format.integer(t, _),
    first_day: format.first_day_of_week(t),
    previous_month: messages.calendar_previous_month(t),
    next_month: messages.calendar_next_month(t),
    choose_date: messages.calendar_choose_date(t),
  )
}

fn time_month(month: Int) -> time_calendar.Month {
  case time_calendar.month_from_int(month) {
    Ok(month) -> month
    Error(Nil) -> time_calendar.January
  }
}

fn uploader_words(t: Translator) -> uploader.Words {
  uploader.Words(
    prompt: messages.uploader_prompt(t),
    remove: messages.uploader_remove(t),
    retry: messages.uploader_retry(t),
    uploading: messages.uploader_uploading(t),
    // The uploader fills these placeholders in itself.
    too_large: messages.uploader_too_large(t, limit: "{limit}"),
    wrong_type: messages.uploader_wrong_type(t),
    too_many: messages.uploader_too_many(t, count: "{count}"),
    failed: messages.uploader_failed(t),
    wait: messages.uploader_wait(t),
    missing: messages.uploader_missing(t),
  )
}

/// The locales howdy_ui has catalogues for. Others still get their own
/// number and date formats from `translated`, with English words.
pub fn locales() -> List(String) {
  messages.locales
}

/// Thousands separators and at most two decimal places: 12,500 or 3.25.
pub fn english_decimal(value: Float) -> String {
  let sign = case value <. 0.0 {
    True -> "-"
    False -> ""
  }
  let hundredths = float.round(float.absolute_value(value) *. 100.0)
  let whole = hundredths / 100
  let decimals = case hundredths % 100 {
    0 -> ""
    f if f % 10 == 0 -> "." <> int.to_string(f / 10)
    f -> "." <> string.pad_start(int.to_string(f), 2, "0")
  }
  sign <> group_thousands(int.to_string(whole)) <> decimals
}

fn group_thousands(digits: String) -> String {
  case string.length(digits) > 3 {
    True ->
      group_thousands(string.drop_end(digits, 3))
      <> ","
      <> string.slice(digits, string.length(digits) - 3, 3)
    False -> digits
  }
}
