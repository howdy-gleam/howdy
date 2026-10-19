// Expected values match what JavaScript's Intl writes from the same CLDR
// release, except that dates here are always Gregorian.

import gleam/time/calendar
import howdy/i18n
import howdy/i18n/format

const date = calendar.Date(2026, calendar.October, 19)

const time = calendar.TimeOfDay(15, 4, 5, 0)

pub fn integers_test() {
  assert format.integer(i18n.new("en"), 1_234_567) == "1,234,567"
  assert format.integer(i18n.new("de"), -1234) == "-1.234"
  assert format.integer(i18n.new("fr"), 1_234_567) == "1\u{202F}234\u{202F}567"
  assert format.integer(i18n.new("de-CH"), 1_234_567) == "1'234'567"
  // Indian grouping, and Spanish leaves four digits ungrouped.
  assert format.integer(i18n.new("hi"), 1_234_567) == "12,34,567"
  assert format.integer(i18n.new("es"), 1234) == "1234"
  assert format.integer(i18n.new("es"), 12_345) == "12.345"
  // Persian digits.
  assert format.integer(i18n.new("fa"), 1_234_567) == "۱٬۲۳۴٬۵۶۷"
  assert format.integer(i18n.new("en"), 0) == "0"
}

pub fn decimals_test() {
  assert format.decimal(i18n.new("en"), 3.14159) == "3.142"
  assert format.decimal(i18n.new("de"), 3.14159) == "3,142"
  assert format.decimal(i18n.new("en"), 2.5) == "2.5"
  assert format.decimal(i18n.new("en"), 1234.0) == "1,234"
  assert format.decimal(i18n.new("en"), -0.0001) == "0"
  assert format.fixed(i18n.new("en"), 2.5, 2) == "2.50"
  assert format.fixed(i18n.new("de"), -1234.567, 1) == "-1.234,6"
}

pub fn percent_test() {
  assert format.percent(i18n.new("en"), 0.256) == "26%"
  assert format.percent(i18n.new("de"), 0.25) == "25\u{00A0}%"
  assert format.percent(i18n.new("tr"), 0.25) == "%25"
}

pub fn currency_test() {
  assert format.currency(i18n.new("en"), minor: 123_456, code: "EUR")
    == "€1,234.56"
  assert format.currency(i18n.new("en"), minor: -123_456, code: "USD")
    == "-$1,234.56"
  assert format.currency(i18n.new("de"), minor: 123_456, code: "EUR")
    == "1.234,56\u{00A0}€"
  // Yen have no minor unit.
  assert format.currency(i18n.new("en"), minor: 1234, code: "JPY") == "¥1,234"
  // A symbol of letters is kept apart from the digits.
  assert format.currency(i18n.new("en"), minor: 500, code: "CHF")
    == "CHF\u{00A0}5.00"
  assert format.currency(i18n.new("nl"), minor: -123_456, code: "USD")
    == "US$\u{00A0}-1.234,56"
  assert format.currency(i18n.new("en"), minor: 100, code: "XYZ")
    == "XYZ\u{00A0}1.00"
}

pub fn dates_test() {
  let en = i18n.new("en")
  assert format.date(en, date, format.Short) == "10/19/26"
  assert format.date(en, date, format.Medium) == "Oct 19, 2026"
  assert format.date(en, date, format.Long) == "October 19, 2026"
  assert format.date(en, date, format.Full) == "Monday, October 19, 2026"
  assert format.date(i18n.new("en-GB"), date, format.Short) == "19/10/2026"
  assert format.date(i18n.new("de"), date, format.Full)
    == "Montag, 19. Oktober 2026"
  assert format.date(i18n.new("ja"), date, format.Long) == "2026年10月19日"
  assert format.date(i18n.new("pl"), date, format.Long)
    == "19 października 2026"
}

pub fn times_test() {
  assert format.time(i18n.new("en"), time, format.Short) == "3:04\u{202F}PM"
  assert format.time(i18n.new("de"), time, format.Short) == "15:04"
  assert format.time(
      i18n.new("en"),
      calendar.TimeOfDay(0, 5, 0, 0),
      format.Short,
    )
    == "12:05\u{202F}AM"
  // Zone names are left out until time zones are supported.
  assert format.time(i18n.new("en"), time, format.Full) == "3:04:05\u{202F}PM"
  assert format.date_time(i18n.new("en"), date, time, format.Medium)
    == "Oct 19, 2026, 3:04:05\u{202F}PM"
}

pub fn calendar_words_test() {
  let en = i18n.new("en")
  assert format.month_year(en, 2026, calendar.October) == "October 2026"
  // Polish names a month differently on its own and inside a date.
  assert format.month_year(i18n.new("pl"), 2026, calendar.October)
    == "październik 2026"
  assert format.month_day(en, calendar.October, 19) == "October 19"
  let assert [monday, ..] = format.weekdays(en, format.Wide)
  assert monday == "Monday"
  let assert [first, ..] = format.months(i18n.new("de"), format.Abbreviated)
  assert first == "Jan."
  assert format.first_day_of_week(en) == 7
  assert format.first_day_of_week(i18n.new("de")) == 1
  assert format.first_day_of_week(i18n.new("en-GB")) == 1
}

pub fn relative_test() {
  let en = i18n.new("en")
  assert format.relative(en, -1, format.Day) == "yesterday"
  assert format.relative(en, 0, format.Day) == "today"
  assert format.relative(en, -3, format.Day) == "3 days ago"
  assert format.relative(en, 2, format.Hour) == "in 2 hours"
  assert format.relative(en, 1, format.Minute) == "in 1 minute"
  assert format.relative(i18n.new("de"), -3, format.Day) == "vor 3 Tagen"
  assert format.relative(i18n.new("pl"), 5, format.Year) == "za 5 lat"
}

pub fn lists_test() {
  let en = i18n.new("en")
  assert format.list(en, []) == ""
  assert format.list(en, ["A"]) == "A"
  assert format.list(en, ["A", "B"]) == "A and B"
  assert format.list(en, ["A", "B", "C"]) == "A, B, and C"
  assert format.list(en, ["A", "B", "C", "D"]) == "A, B, C, and D"
  assert format.or_list(en, ["A", "B", "C"]) == "A, B, or C"
  assert format.list(i18n.new("de"), ["A", "B", "C"]) == "A, B und C"
  assert format.list(i18n.new("ja"), ["A", "B", "C"]) == "A、B、C"
}

// Halfway values round in decimal, including when percent shifts the point.
pub fn decimal_rounding_test() {
  let en = i18n.new("en")
  assert format.fixed(en, -0.0, 2) == "0.00"
  assert format.fixed(en, 1.005, 2) == "1.01"
  assert format.fixed(en, 1.015, 2) == "1.02"
  assert format.fixed(en, -1.005, 2) == "-1.01"
  assert format.fixed(en, 9.995, 2) == "10.00"
  assert format.fixed(en, 100_000_000_000_000.5, 2) == "100,000,000,000,000.50"
  assert format.decimal(en, 0.000_000_1) == "0"
  assert format.fixed(en, 1.0e20, 2) == "100,000,000,000,000,000,000.00"
  assert format.percent(en, 1.005) == "101%"
  assert format.percent(en, 0.000_000_1) == "0%"
  assert format.percent(en, 0.0) == "0%"
}

pub fn currency_separators_test() {
  assert format.currency(i18n.new("de-AT"), minor: 123_456, code: "EUR")
    == "€\u{00A0}1.234,56"
  assert format.currency(i18n.new("fr-CH"), minor: 123_456, code: "CHF")
    == "1\u{202F}234.56\u{00A0}CHF"
}

pub fn list_items_are_not_patterns_test() {
  assert format.list(i18n.new("en"), ["{1}", "B"]) == "{1} and B"
  assert format.list(i18n.new("en"), ["{0}", "B", "C"]) == "{0}, B, and C"
}

pub fn narrow_months_use_cldr_names_test() {
  assert format.months(i18n.new("ja"), format.Narrow)
    == ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12"]
  assert format.months(i18n.new("zh"), format.Narrow)
    == ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12"]
}
