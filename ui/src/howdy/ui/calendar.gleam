//// Calendars and date pickers: one date, a range, or several dates, over
//// one month or a few side by side.
////
//// ```gleam
//// calendar.new("due", year: 2026, month: 9)
//// |> calendar.selected(Some(calendar.Date(2026, 9, 24)))
//// |> calendar.today(calendar.Date(2026, 9, 24))
//// |> calendar.disabled(fn(date) { calendar.weekday(date) >= 6 })
//// |> calendar.navigation(
////   previous: [event.on_click(PreviousMonth)],
////   next: [event.on_click(NextMonth)],
//// )
//// |> calendar.name("due")
//// |> calendar.view
//// ```
////
//// Clicking a day selects it; the arrow keys move a day or a week, Home
//// and End go to the ends of the week, and Page Up and Page Down press the
//// previous and next month buttons. The choice is kept in the hidden input
//// called `name`, so it submits with a form and a live view hears it with
//// `live.on_value`:
////
//// - one date, with `selected`, as `2026-09-24`;
//// - a range, with `range`, as `2026-09-10/2026-09-14`: the first click
////   picks the start and the second the end;
//// - several dates, with `multiple`, as `2026-09-10,2026-09-14`: each
////   click adds or removes a day.
////
//// `months` shows several months side by side, and `locale` names the
//// months, weekdays and buttons in another language. Changing month is the
//// server's job: `navigation` takes the attributes of the previous and
//// next buttons, such as click handlers in a live view. On a page without
//// a live view, a native `<input type="date">` usually serves better for a
//// single date.
////
//// `picker` puts the calendar in a popover behind a button that shows the
//// choice.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order}
import gleam/string
import howdy/ui/style.{anchor_name, class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{percent, rem}

/// A day in the proleptic Gregorian calendar. Months and days count from 1.
pub type Date {
  Date(year: Int, month: Int, day: Int)
}

/// What is chosen.
pub type Selection {
  Single(Option(Date))
  /// A start and, once chosen, an end.
  Range(from: Option(Date), to: Option(Date))
  Multiple(List(Date))
}

/// The words a calendar uses. `weekday_names` and `weekday_abbreviations`
/// run from Monday; `heading` writes a month and year, given the year and
/// the month, as at the top of the calendar; `date_label` writes a date out
/// in full; `day_number` writes the number on each day; `first_day` is the
/// day weeks start on, from 1 for Monday to 7 for Sunday.
///
/// `english` is the default. `howdy/ui/words` holds one of these for its
/// locale, with names and formats from CLDR.
pub type Locale {
  Locale(
    weekday_names: List(String),
    weekday_abbreviations: List(String),
    heading: fn(Int, Int) -> String,
    date_label: fn(Date) -> String,
    day_number: fn(Int) -> String,
    first_day: Int,
    previous_month: String,
    next_month: String,
    choose_date: String,
  )
}

pub fn english() -> Locale {
  let weekday_names = [
    "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
  ]
  Locale(
    weekday_names:,
    weekday_abbreviations: list.map(weekday_names, string.slice(_, 0, 2)),
    heading: fn(year, month) { month_name(month) <> " " <> int.to_string(year) },
    date_label: long_date,
    day_number: int.to_string,
    first_day: 1,
    previous_month: "Previous month",
    next_month: "Next month",
    choose_date: "Choose a date",
  )
}

/// A calendar under construction.
pub opaque type Calendar(msg) {
  Calendar(
    id: String,
    year: Int,
    month: Int,
    months: Int,
    selection: Selection,
    today: Option(Date),
    disabled: fn(Date) -> Bool,
    first_day: Option(Int),
    previous: List(Attribute(msg)),
    next: List(Attribute(msg)),
    name: Option(String),
    locale: Locale,
  )
}

/// A calendar showing `month` of `year`. `id` must be unique in the
/// document.
pub fn new(id: String, year year: Int, month month: Int) -> Calendar(msg) {
  Calendar(
    id:,
    year:,
    month:,
    months: 1,
    selection: Single(None),
    today: None,
    disabled: fn(_) { False },
    first_day: None,
    previous: [],
    next: [],
    name: None,
    locale: english(),
  )
}

/// Choose one date; this one, if there is one.
pub fn selected(calendar: Calendar(msg), date: Option(Date)) -> Calendar(msg) {
  Calendar(..calendar, selection: Single(date))
}

/// Choose a range; this one, as far as it is chosen.
pub fn range(
  calendar: Calendar(msg),
  from from: Option(Date),
  to to: Option(Date),
) -> Calendar(msg) {
  Calendar(..calendar, selection: Range(from:, to:))
}

/// Choose any number of dates; these ones so far.
pub fn multiple(calendar: Calendar(msg), dates: List(Date)) -> Calendar(msg) {
  Calendar(..calendar, selection: Multiple(dates))
}

/// Show `count` months side by side, starting with the calendar's month.
pub fn months(calendar: Calendar(msg), count: Int) -> Calendar(msg) {
  Calendar(..calendar, months: int.max(count, 1))
}

/// Today, which is marked. The server's today may not be the user's, so
/// pass the date in the user's time zone when you know it.
pub fn today(calendar: Calendar(msg), date: Date) -> Calendar(msg) {
  Calendar(..calendar, today: Some(date))
}

/// Days that cannot be chosen, such as those in the past.
pub fn disabled(
  calendar: Calendar(msg),
  disabled: fn(Date) -> Bool,
) -> Calendar(msg) {
  Calendar(..calendar, disabled:)
}

/// Start weeks on Sunday, whatever the locale's custom.
pub fn sunday_first(calendar: Calendar(msg)) -> Calendar(msg) {
  first_day(calendar, 7)
}

/// Start weeks on this day, from 1 for Monday to 7 for Sunday, whatever
/// the locale's custom.
pub fn first_day(calendar: Calendar(msg), day: Int) -> Calendar(msg) {
  Calendar(..calendar, first_day: Some(int.clamp(day, 1, 7)))
}

fn week_start(calendar: Calendar(msg)) -> Int {
  option.unwrap(calendar.first_day, calendar.locale.first_day)
}

/// Name the months, weekdays and buttons in another language, and start
/// weeks on the locale's first day unless `first_day` says otherwise.
pub fn locale(calendar: Calendar(msg), locale: Locale) -> Calendar(msg) {
  Calendar(..calendar, locale:)
}

/// Show previous and next month buttons with these attributes.
pub fn navigation(
  calendar: Calendar(msg),
  previous previous: List(Attribute(msg)),
  next next: List(Attribute(msg)),
) -> Calendar(msg) {
  Calendar(..calendar, previous:, next:)
}

/// Keep the choice in a hidden input with this name.
pub fn name(calendar: Calendar(msg), name: String) -> Calendar(msg) {
  Calendar(..calendar, name: Some(name))
}

/// The calendar on its own.
pub fn view(calendar: Calendar(msg)) -> Element(msg) {
  let input = case calendar.name {
    Some(name) -> [hidden_input(name, calendar.selection)]
    None -> []
  }
  html.div(
    [
      class(root_class()),
      attribute.data("howdy-calendar", ""),
      attribute.data("mode", mode(calendar.selection)),
    ],
    list.append(input, [grids(calendar)]),
  )
}

/// A button showing the choice, or `placeholder`, that opens the calendar
/// in a popover. Choosing one date, or the end of a range, closes it. Give
/// the calendar a `name` so the choice is kept.
pub fn picker(
  calendar: Calendar(msg),
  placeholder placeholder: String,
) -> Element(msg) {
  let popover = calendar.id <> "-popover"
  let #(label, mark) = case describe(calendar) {
    Some(label) -> #(label, [])
    None -> #(placeholder, [attribute.data("placeholder", "")])
  }
  let input = case calendar.name {
    Some(name) -> [hidden_input(name, calendar.selection)]
    None -> []
  }
  html.div(
    [class(picker_class()), attribute.data("howdy-select", "")],
    list.append(input, [
      html.button(
        [
          class(trigger_class()),
          attribute.type_("button"),
          attribute.id(calendar.id),
          attribute.attribute("popovertarget", popover),
          attribute.data("howdy-select-trigger", ""),
          attribute.aria_haspopup("dialog"),
          attribute.data("howdy-anchor", anchor_name(popover)),
          ..mark
        ],
        [
          html.span(
            [
              attribute.data("howdy-select-value", ""),
              attribute.data("howdy-placeholder", placeholder),
            ],
            [text(label)],
          ),
        ],
      ),
      html.div(
        [
          class(popover_class()),
          attribute.id(popover),
          attribute.popover("auto"),
          attribute.role("dialog"),
          attribute.aria_label(calendar.locale.choose_date),
          attribute.data("howdy-anchored", anchor_name(popover)),
        ],
        [
          html.div(
            [
              class(root_class()),
              attribute.data("howdy-calendar", ""),
              attribute.data("mode", mode(calendar.selection)),
            ],
            [grids(Calendar(..calendar, id: calendar.id <> "-calendar"))],
          ),
        ],
      ),
    ]),
  )
}

fn mode(selection: Selection) -> String {
  case selection {
    Single(_) -> "single"
    Range(..) -> "range"
    Multiple(_) -> "multiple"
  }
}

/// What a picker's button says about the choice.
fn describe(calendar: Calendar(msg)) -> Option(String) {
  let label = calendar.locale.date_label
  case calendar.selection {
    Single(Some(date)) -> Some(label(date))
    Range(from: Some(from), to: Some(to)) ->
      Some(label(from) <> " – " <> label(to))
    Range(from: Some(from), to: None) -> Some(label(from) <> " – …")
    Multiple([_, ..] as dates) ->
      Some(dates |> list.map(label) |> string.join(", "))
    _ -> None
  }
}

fn hidden_input(name: String, selection: Selection) -> Element(msg) {
  html.input([
    attribute.type_("hidden"),
    attribute.name(name),
    attribute.value(selection_to_value(selection)),
  ])
}

/// The hidden input's value for a selection.
pub fn selection_to_value(selection: Selection) -> String {
  case selection {
    Single(Some(date)) -> to_iso(date)
    Single(None) -> ""
    Range(from: None, ..) -> ""
    Range(from: Some(from), to: None) -> to_iso(from) <> "/"
    Range(from: Some(from), to: Some(to)) -> to_iso(from) <> "/" <> to_iso(to)
    Multiple(dates) -> dates |> list.map(to_iso) |> string.join(",")
  }
}

/// Read a range as its hidden input sends it: `2026-09-10/2026-09-14`, or
/// `2026-09-10/` while only the start is chosen.
pub fn range_from_value(value: String) -> Result(#(Date, Option(Date)), Nil) {
  case string.split(value, "/") {
    [from, ""] -> from_iso(from) |> result_map(fn(from) { #(from, None) })
    [from, to] ->
      case from_iso(from), from_iso(to) {
        Ok(from), Ok(to) -> Ok(#(from, Some(to)))
        _, _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// Read several dates as their hidden input sends them. Anything that is
/// not a date is left out.
pub fn dates_from_value(value: String) -> List(Date) {
  value
  |> string.split(",")
  |> list.filter_map(from_iso)
}

fn result_map(result: Result(a, Nil), f: fn(a) -> b) -> Result(b, Nil) {
  case result {
    Ok(value) -> Ok(f(value))
    Error(Nil) -> Error(Nil)
  }
}

fn grids(calendar: Calendar(msg)) -> Element(msg) {
  let count = calendar.months
  html.div(
    [class(months_class())],
    list.repeat(Nil, count)
      |> list.index_map(fn(_, index) {
        let first = add_months(Date(calendar.year, calendar.month, 1), index)
        month(calendar, first, index == 0, index == count - 1, count > 1)
      }),
  )
}

fn month(
  calendar: Calendar(msg),
  first: Date,
  is_first: Bool,
  is_last: Bool,
  several: Bool,
) -> Element(msg) {
  let caption =
    calendar.id <> "-caption-" <> int.to_string(first.year * 12 + first.month)
  let title = calendar.locale.heading(first.year, first.month)
  let shown = case calendar.previous, calendar.next {
    [], [] -> False
    _, _ -> True
  }
  let previous = case shown && is_first {
    True -> [
      nav_button(
        calendar.previous,
        calendar.locale.previous_month,
        "‹",
        "previous",
      ),
    ]
    False -> []
  }
  let next = case shown && is_last {
    True -> [nav_button(calendar.next, calendar.locale.next_month, "›", "next")]
    False -> []
  }
  let start = week_start(calendar)
  let weekdays =
    list.map([0, 1, 2, 3, 4, 5, 6], fn(index) { { start - 1 + index } % 7 + 1 })
  html.div([], [
    html.div([class(heading_class())], [
      html.div([class(nav_class())], previous),
      html.div(
        [
          class(caption_class()),
          attribute.id(caption),
          attribute.aria_live("polite"),
        ],
        [text(title)],
      ),
      html.div([class(nav_class())], next),
    ]),
    html.table(
      [
        class(grid_class()),
        attribute.role("grid"),
        attribute.aria_labelledby(caption),
      ],
      [
        html.thead([], [
          html.tr(
            [],
            list.map(weekdays, fn(day) {
              let name = name_of_weekday(calendar.locale, day)
              html.th(
                [
                  class(weekday_class()),
                  attribute.attribute("scope", "col"),
                  attribute.attribute("abbr", name),
                ],
                [text(nth(calendar.locale.weekday_abbreviations, day))],
              )
            }),
          ),
        ]),
        html.tbody(
          [],
          list.map(weeks(calendar, first), week(calendar, first, several, _)),
        ),
      ],
    ),
  ])
}

fn name_of_weekday(locale: Locale, day: Int) -> String {
  nth(locale.weekday_names, day)
}

/// The `day`th name, counting from 1.
fn nth(names: List(String), day: Int) -> String {
  case list.drop(names, day - 1) {
    [name, ..] -> name
    [] -> int.to_string(day)
  }
}

fn nav_button(
  attributes: List(Attribute(msg)),
  label: String,
  symbol: String,
  which: String,
) -> Element(msg) {
  html.button(
    [
      class(nav_button_class()),
      attribute.type_("button"),
      attribute.aria_label(label),
      attribute.data("howdy-calendar-" <> which, ""),
      ..attributes
    ],
    [html.span([attribute.aria_hidden(True)], [text(symbol)])],
  )
}

/// The days shown: whole weeks from the one holding the 1st to the one
/// holding the last day of the month.
fn weeks(calendar: Calendar(msg), first: Date) -> List(List(Date)) {
  let offset = { weekday(first) - week_start(calendar) + 7 } % 7
  let start = add_days(first, -offset)
  let length = offset + days_in_month(first.year, first.month)
  let count = { length + 6 } / 7
  list.repeat(Nil, count * 7)
  |> list.index_map(fn(_, index) { add_days(start, index) })
  |> list.sized_chunk(7)
}

fn is_chosen(selection: Selection, date: Date) -> Bool {
  case selection {
    Single(chosen) -> chosen == Some(date)
    Range(from:, to:) -> from == Some(date) || to == Some(date)
    Multiple(dates) -> list.contains(dates, date)
  }
}

fn in_range(selection: Selection, date: Date) -> Bool {
  case selection {
    Range(from: Some(from), to: Some(to)) ->
      compare(date, from) == order.Gt && compare(date, to) == order.Lt
    _ -> False
  }
}

/// The day in the tab order: the first chosen day shown, else today, else
/// the first of the first month.
fn focus_day(calendar: Calendar(msg)) -> Date {
  let shown = fn(date: Date) {
    let first = Date(calendar.year, calendar.month, 1)
    let last = add_months(first, calendar.months)
    compare(date, first) != order.Lt && compare(date, last) == order.Lt
  }
  let chosen = case calendar.selection {
    Single(Some(date)) -> [date]
    Range(from: Some(from), ..) -> [from]
    Multiple(dates) -> dates
    _ -> []
  }
  case list.find(chosen, shown), calendar.today {
    Ok(date), _ -> date
    Error(Nil), Some(today) ->
      case shown(today) {
        True -> today
        False -> Date(calendar.year, calendar.month, 1)
      }
    Error(Nil), None -> Date(calendar.year, calendar.month, 1)
  }
}

fn week(
  calendar: Calendar(msg),
  first: Date,
  several: Bool,
  days: List(Date),
) -> Element(msg) {
  let focus = focus_day(calendar)
  let label = calendar.locale.date_label
  html.tr(
    [],
    list.map(days, fn(date) {
      let outside = date.month != first.month
      case outside && several {
        // With months side by side, a day belongs to its own month only.
        True -> html.td([], [])
        False -> {
          let flags =
            list.flatten([
              [
                attribute.aria_pressed(
                  case is_chosen(calendar.selection, date) {
                    True -> "true"
                    False -> "false"
                  },
                ),
              ],
              case in_range(calendar.selection, date) {
                True -> [attribute.data("in-range", "")]
                False -> []
              },
              case Some(date) == calendar.today {
                True -> [attribute.aria_current("date")]
                False -> []
              },
              case outside {
                True -> [attribute.data("outside", "")]
                False -> []
              },
              case calendar.disabled(date) {
                True -> [attribute.disabled(True)]
                False -> []
              },
            ])
          html.td([], [
            html.button(
              [
                class(day_class()),
                attribute.type_("button"),
                attribute.data("date", to_iso(date)),
                attribute.data("label", label(date)),
                attribute.aria_label(
                  name_of_weekday(calendar.locale, weekday(date))
                  <> ", "
                  <> label(date),
                ),
                attribute.tabindex(case date == focus {
                  True -> 0
                  False -> -1
                }),
                ..flags
              ],
              [text(calendar.locale.day_number(date.day))],
            ),
          ])
        }
      }
    }),
  )
}

// -- Dates -------------------------------------------------------------------

/// `YYYY-MM-DD`.
pub fn to_iso(date: Date) -> String {
  string.pad_start(int.to_string(date.year), 4, "0")
  <> "-"
  <> string.pad_start(int.to_string(date.month), 2, "0")
  <> "-"
  <> string.pad_start(int.to_string(date.day), 2, "0")
}

/// Read `YYYY-MM-DD`, as a hidden input or `<input type="date">` sends it.
pub fn from_iso(value: String) -> Result(Date, Nil) {
  case string.split(value, "-") {
    [year, month, day] -> {
      case int.parse(year), int.parse(month), int.parse(day) {
        Ok(year), Ok(month), Ok(day) if month >= 1 && month <= 12 && day >= 1 ->
          case day <= days_in_month(year, month) {
            True -> Ok(Date(year, month, day))
            False -> Error(Nil)
          }
        _, _, _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

/// "24 September 2026".
pub fn long_date(date: Date) -> String {
  int.to_string(date.day)
  <> " "
  <> month_name(date.month)
  <> " "
  <> int.to_string(date.year)
}

/// The day of the week, from 1 for Monday to 7 for Sunday.
pub fn weekday(date: Date) -> Int {
  // 1970-01-01 was a Thursday. `%` keeps the sign of negative days.
  case { to_days(date) + 3 } % 7 {
    remainder if remainder < 0 -> remainder + 8
    remainder -> remainder + 1
  }
}

pub fn add_days(date: Date, days: Int) -> Date {
  from_days(to_days(date) + days)
}

/// The same day in the month `months` later, or the last day of that month
/// when it is shorter.
pub fn add_months(date: Date, months: Int) -> Date {
  let index = date.year * 12 + date.month - 1 + months
  let year = floor_div(index, 12)
  let month = index - year * 12 + 1
  Date(year, month, int.min(date.day, days_in_month(year, month)))
}

pub fn days_in_month(year: Int, month: Int) -> Int {
  case month {
    2 ->
      case is_leap_year(year) {
        True -> 29
        False -> 28
      }
    4 | 6 | 9 | 11 -> 30
    _ -> 31
  }
}

pub fn is_leap_year(year: Int) -> Bool {
  { year % 4 == 0 && year % 100 != 0 } || year % 400 == 0
}

pub fn compare(a: Date, b: Date) -> Order {
  int.compare(to_days(a), to_days(b))
}

// Days since 1970-01-01, after Howard Hinnant's `days_from_civil`.
fn to_days(date: Date) -> Int {
  let y = case date.month <= 2 {
    True -> date.year - 1
    False -> date.year
  }
  let era = floor_div(y, 400)
  let yoe = y - era * 400
  let mp = { date.month + 9 } % 12
  let doy = { 153 * mp + 2 } / 5 + date.day - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146_097 + doe - 719_468
}

fn from_days(days: Int) -> Date {
  let z = days + 719_468
  let era = floor_div(z, 146_097)
  let doe = z - era * 146_097
  let yoe = { doe - doe / 1460 + doe / 36_524 - doe / 146_096 } / 365
  let doy = doe - { 365 * yoe + yoe / 4 - yoe / 100 }
  let mp = { 5 * doy + 2 } / 153
  let day = doy - { 153 * mp + 2 } / 5 + 1
  let month = case mp < 10 {
    True -> mp + 3
    False -> mp - 9
  }
  let year = yoe + era * 400
  let year = case month <= 2 {
    True -> year + 1
    False -> year
  }
  Date(year, month, day)
}

fn floor_div(a: Int, b: Int) -> Int {
  case int.floor_divide(a, b) {
    Ok(quotient) -> quotient
    Error(Nil) -> 0
  }
}

fn month_name(month: Int) -> String {
  case month {
    1 -> "January"
    2 -> "February"
    3 -> "March"
    4 -> "April"
    5 -> "May"
    6 -> "June"
    7 -> "July"
    8 -> "August"
    9 -> "September"
    10 -> "October"
    11 -> "November"
    _ -> "December"
  }
}

// -- Styles ------------------------------------------------------------------

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    root_class(),
    months_class(),
    heading_class(),
    caption_class(),
    nav_class(),
    nav_button_class(),
    grid_class(),
    weekday_class(),
    day_class(),
    picker_class(),
    trigger_class(),
    popover_class(),
  ]
}

pub fn root_class() -> Class {
  css.class([css.display("inline-block"), css.color(tokens.text)])
}

pub fn months_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_wrap("wrap"),
    css.gap(rem(1.5)),
  ])
}

pub fn heading_class() -> Class {
  css.class([
    css.display("flex"),
    css.align_items("center"),
    css.justify_content("space-between"),
    css.gap(rem(0.5)),
    css.margin_("0 0 " <> tokens.space_2),
    css.property("min-height", "2rem"),
  ])
}

pub fn caption_class() -> Class {
  css.class([
    css.padding_("0 " <> tokens.space_2),
    css.font_size(rem(0.875)),
    css.font_weight("500"),
  ])
}

pub fn nav_class() -> Class {
  css.class([css.display("flex"), css.gap(rem(0.25))])
}

pub fn nav_button_class() -> Class {
  css.class([
    // Arrows point the way the text runs.
    css.selector(":dir(rtl) > span", [
      css.display("inline-block"),
      css.transform_("scaleX(-1)"),
    ]),
    css.display("inline-flex"),
    css.align_items("center"),
    css.justify_content("center"),
    css.property("width", "2rem"),
    css.property("height", "2rem"),
    css.padding(rem(0.0)),
    style.bordered(),
    style.radius(tokens.radius_small),
    css.background("transparent"),
    css.color(tokens.text),
    css.font_size(rem(1.125)),
    css.line_height("1"),
    css.cursor("pointer"),
    css.hover([css.background(tokens.muted)]),
    style.focus_ring(),
  ])
}

pub fn grid_class() -> Class {
  css.class([
    css.border_collapse("collapse"),
    css.property("border-spacing", "0"),
  ])
}

pub fn weekday_class() -> Class {
  css.class([
    css.padding_("0 0 " <> tokens.space_1),
    css.font_size(rem(0.75)),
    css.font_weight("400"),
    css.color(tokens.text_muted),
    css.text_align("center"),
  ])
}

pub fn day_class() -> Class {
  css.class([
    css.display("inline-flex"),
    css.align_items("center"),
    css.justify_content("center"),
    css.property("width", "2.25rem"),
    css.property("height", "2.25rem"),
    css.padding(rem(0.0)),
    css.border("0"),
    style.radius(tokens.radius_small),
    css.background("transparent"),
    css.color(tokens.text),
    css.font_family(tokens.font_body),
    css.font_size(rem(0.875)),
    css.cursor("pointer"),
    css.hover([css.background(tokens.muted)]),
    style.focus_ring_offset("1px"),
    css.selector("[data-outside]", [css.color(tokens.text_muted)]),
    css.selector("[aria-current=\"date\"]", [
      css.property("box-shadow", "inset 0 0 0 1px " <> tokens.border),
      css.font_weight("600"),
    ]),
    // Days between a range's ends share a band of the muted colour.
    css.selector("[data-in-range]", [
      css.background(tokens.muted),
      style.radius("0"),
    ]),
    css.selector("[aria-pressed=\"true\"]", [
      css.background(tokens.primary),
      css.color(tokens.on_primary),
    ]),
    css.disabled([
      css.property("opacity", "0.4"),
      css.cursor("default"),
      css.background("transparent"),
      css.text_decoration("line-through"),
    ]),
  ])
}

pub fn picker_class() -> Class {
  css.class([css.display("block"), css.width(percent(100))])
}

pub fn trigger_class() -> Class {
  css.class([
    css.display("flex"),
    css.align_items("center"),
    css.width(percent(100)),
    css.padding_(tokens.space_2 <> " " <> tokens.space_3),
    css.background(tokens.surface),
    css.color(tokens.text),
    style.bordered(),
    style.radius(tokens.radius_medium),
    css.font_family(tokens.font_body),
    css.font_size(rem(1.0)),
    css.line_height("1.5"),
    css.text_align("start"),
    css.cursor("pointer"),
    css.selector("[data-placeholder]", [css.color(tokens.text_muted)]),
    style.focus_ring(),
  ])
}

pub fn popover_class() -> Class {
  css.class([
    css.inset("auto"),
    css.margin_("0.375rem 0"),
    css.property("position-area", "block-end span-inline-end"),
    css.property("position-try-fallbacks", "flip-block, flip-inline"),
    css.padding(rem(0.75)),
    css.background(tokens.surface),
    css.color(tokens.text),
    style.bordered(),
    style.radius(tokens.radius_medium),
    css.box_shadow("0 10px 30px -10px rgb(0 0 0 / 0.3)"),
  ])
}
