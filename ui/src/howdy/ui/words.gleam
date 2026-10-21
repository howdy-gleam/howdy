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
    /// Notification bells: the unread count, which may contain `{count}`,
    /// the buttons, what an empty or failed inbox says, and the browser
    /// notification switch. The bell's name is `notifications`.
    unread: String,
    mark_all_read: String,
    mark_read: String,
    mark_unread: String,
    caught_up: String,
    see_all_notifications: String,
    notifications_failed: String,
    push_on: String,
    push_off: String,
    push_blocked: String,
    calendar: calendar.Locale,
    uploader: uploader.Words,
    attachment: attachment.Words,
    rich_text: RichTextWords,
  )
}

/// What a rich text editor says. `heading` may contain `{level}`, and
/// `too_large` `{limit}`.
pub type RichTextWords {
  RichTextWords(
    toolbar: String,
    bold: String,
    italic: String,
    strike: String,
    code: String,
    link: String,
    heading: String,
    quote: String,
    bullet_list: String,
    numbered_list: String,
    code_block: String,
    divider: String,
    attach: String,
    undo: String,
    redo: String,
    link_address: String,
    link_apply: String,
    link_remove: String,
    bad_link: String,
    no_matches: String,
    remove: String,
    uploading: String,
    too_large: String,
    wrong_type: String,
    failed: String,
    wait: String,
    missing: String,
    unavailable: String,
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
    unread: "{count} unread",
    mark_all_read: "Mark all as read",
    mark_read: "Mark as read",
    mark_unread: "Mark as unread",
    caught_up: "You're all caught up.",
    see_all_notifications: "See all notifications",
    notifications_failed: "Notifications could not be loaded.",
    push_on: "Turn on browser notifications",
    push_off: "Turn off browser notifications",
    push_blocked: "Browser notifications are blocked in this browser's settings.",
    calendar: calendar.english(),
    uploader: uploader.english(),
    attachment: attachment.english(),
    rich_text: RichTextWords(
      toolbar: "Formatting",
      bold: "Bold",
      italic: "Italic",
      strike: "Strikethrough",
      code: "Code",
      link: "Link",
      heading: "Heading {level}",
      quote: "Quote",
      bullet_list: "Bulleted list",
      numbered_list: "Numbered list",
      code_block: "Code block",
      divider: "Divider",
      attach: "Attach files",
      undo: "Undo",
      redo: "Redo",
      link_address: "Link address",
      link_apply: "Apply",
      link_remove: "Remove link",
      bad_link: "Enter a web address, such as https://example.com.",
      no_matches: "No matches",
      remove: "Remove",
      uploading: "Uploading",
      too_large: "Too large: the limit is {limit}.",
      wrong_type: "This type of file is not accepted.",
      failed: "The file could not be uploaded.",
      wait: "Wait for the files to finish uploading.",
      missing: "Write something.",
      unavailable: "The editor could not load. Reload the page to try again.",
    ),
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
    // The bell fills the count in itself.
    unread: messages.bell_unread(t, count: "{count}"),
    mark_all_read: messages.bell_mark_all_read(t),
    mark_read: messages.bell_mark_read(t),
    mark_unread: messages.bell_mark_unread(t),
    caught_up: messages.bell_caught_up(t),
    see_all_notifications: messages.bell_see_all(t),
    notifications_failed: messages.bell_failed(t),
    push_on: messages.bell_push_on(t),
    push_off: messages.bell_push_off(t),
    push_blocked: messages.bell_push_blocked(t),
    calendar: calendar_words(t),
    uploader: uploader_words(t),
    attachment: attachment.Words(
      uploading: fn(name) { messages.uploading_file(t, name:) },
      processing: messages.processing(t),
    ),
    rich_text: rich_text_words(t),
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

fn rich_text_words(t: Translator) -> RichTextWords {
  RichTextWords(
    // The editor fills these placeholders in itself.
    toolbar: messages.editor_toolbar(t),
    bold: messages.editor_bold(t),
    italic: messages.editor_italic(t),
    strike: messages.editor_strike(t),
    code: messages.editor_code(t),
    link: messages.editor_link(t),
    heading: messages.editor_heading(t, level: "{level}"),
    quote: messages.editor_quote(t),
    bullet_list: messages.editor_bullet_list(t),
    numbered_list: messages.editor_numbered_list(t),
    code_block: messages.editor_code_block(t),
    divider: messages.editor_divider(t),
    attach: messages.editor_attach(t),
    undo: messages.editor_undo(t),
    redo: messages.editor_redo(t),
    link_address: messages.editor_link_address(t),
    link_apply: messages.editor_link_apply(t),
    link_remove: messages.editor_link_remove(t),
    bad_link: messages.editor_bad_link(t),
    no_matches: messages.editor_no_matches(t),
    remove: messages.editor_remove(t),
    uploading: messages.editor_uploading(t),
    too_large: messages.editor_too_large(t, limit: "{limit}"),
    wrong_type: messages.editor_wrong_type(t),
    failed: messages.editor_failed(t),
    wait: messages.editor_wait(t),
    missing: messages.editor_missing(t),
    unavailable: messages.editor_unavailable(t),
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
