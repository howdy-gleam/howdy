//// Numbers, money, dates, relative times and lists, written the way a
//// translator's locale writes them.
////
//// ```gleam
//// let t = i18n.new("de")
//// format.integer(t, 1_234_567)                    // "1.234.567"
//// format.decimal(t, 3.14159)                      // "3,142"
//// format.percent(t, 0.25)                         // "25 %"
//// format.currency(t, minor: 123_456, code: "EUR") // "1.234,56 €"
//// format.date(t, date, format.Long)               // "19. Oktober 2026"
//// format.relative(t, -1, format.Day)              // "gestern"
//// format.list(t, ["Anna", "Ben", "Cem"])          // "Anna, Ben und Cem"
//// ```
////
//// The patterns come from CLDR. Times are written as given: there is no
//// time zone support yet, so convert to the reader's zone first, and the
//// zone names some locales put in their longer time formats are left out.

import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date, type Month, type TimeOfDay}
import howdy/i18n.{type Translator}
import howdy/i18n/internal/cldr
import howdy/i18n/internal/data.{type Data, type ListPattern, type Styles}
import howdy/i18n/plural

/// How much detail a date or time shows. In English, `Short` is
/// `10/19/26`, `Medium` `Oct 19, 2026`, `Long` `October 19, 2026` and
/// `Full` `Monday, October 19, 2026`.
pub type Style {
  Short
  Medium
  Long
  Full
}

/// How long a month or weekday name is: `January`, `Jan` or `J`.
pub type Width {
  Wide
  Abbreviated
  Narrow
}

pub type Unit {
  Second
  Minute
  Hour
  Day
  Week
  Month
  Quarter
  Year
}

// -- Numbers -----------------------------------------------------------------

/// A whole number with the locale's digit grouping: `1,234,567`.
pub fn integer(translator: Translator, number: Int) -> String {
  let numbers = i18n.data(translator).numbers
  let pattern = parse_number_pattern(numbers.decimal_pattern)
  render_number(
    numbers,
    pattern,
    int.to_string(int.absolute_value(number)),
    "",
    number < 0,
    "",
  )
}

/// A number with up to three digits after the decimal point, as the
/// locale usually writes them: `3.142`.
pub fn decimal(translator: Translator, number: Float) -> String {
  let numbers = i18n.data(translator).numbers
  let pattern = parse_number_pattern(numbers.decimal_pattern)
  float_number(
    numbers,
    pattern,
    number,
    0,
    pattern.min_fraction,
    pattern.max_fraction,
    "",
  )
}

/// A number with exactly `digits` digits after the decimal point:
/// `fixed(t, 2.5, 2)` is `2.50`.
pub fn fixed(translator: Translator, number: Float, digits: Int) -> String {
  let numbers = i18n.data(translator).numbers
  let pattern = parse_number_pattern(numbers.decimal_pattern)
  float_number(numbers, pattern, number, 0, digits, digits, "")
}

/// A fraction as a percentage, so `0.25` is `25%`, rounded to a whole
/// percent.
pub fn percent(translator: Translator, fraction: Float) -> String {
  let numbers = i18n.data(translator).numbers
  let pattern = parse_number_pattern(numbers.percent_pattern)
  float_number(
    numbers,
    pattern,
    fraction,
    2,
    pattern.min_fraction,
    pattern.max_fraction,
    "",
  )
}

/// An amount of money in the currency's smallest unit, such as cents, so
/// that no amount is ever a float: `currency(t, minor: 1999, code: "USD")`
/// is `$19.99`. `code` is an ISO 4217 code; currencies without a symbol in
/// the locale's data show their code.
pub fn currency(
  translator: Translator,
  minor minor: Int,
  code code: String,
) -> String {
  let data = i18n.data(translator)
  let numbers =
    data.Numbers(
      ..data.numbers,
      decimal: data.numbers.currency_decimal,
      group: data.numbers.currency_group,
    )
  let pattern = parse_number_pattern(numbers.currency_pattern)
  let digits = cldr.currency_digits(code)
  let symbol = list.key_find(data.currencies, code) |> result.unwrap(code)
  let whole = int.absolute_value(minor)
  let unit = power_of_ten(digits)
  let fraction = case digits {
    0 -> ""
    _ -> string.pad_start(int.to_string(whole % unit), digits, "0")
  }
  render_number(
    numbers,
    pattern,
    int.to_string(whole / unit),
    fraction,
    minor < 0,
    symbol,
  )
}

type NumberPattern {
  NumberPattern(
    prefix: String,
    suffix: String,
    negative: Result(#(String, String), Nil),
    primary: Int,
    secondary: Int,
    min_integer: Int,
    min_fraction: Int,
    max_fraction: Int,
  )
}

fn parse_number_pattern(pattern: String) -> NumberPattern {
  let #(positive, negative) = case string.split_once(pattern, ";") {
    Ok(#(positive, negative)) -> #(positive, Ok(negative))
    Error(Nil) -> #(pattern, Error(Nil))
  }
  let #(prefix, number, suffix) = split_number(positive)
  let #(integer_part, fraction_part) = case string.split_once(number, ".") {
    Ok(#(integer, fraction)) -> #(integer, fraction)
    Error(Nil) -> #(number, "")
  }
  let groups = string.split(integer_part, ",")
  let #(primary, secondary) = case list.reverse(groups) {
    [last, middle, _, ..] -> #(string.length(last), string.length(middle))
    [last, _] -> #(string.length(last), string.length(last))
    _ -> #(0, 0)
  }
  let negative =
    result.map(negative, fn(negative) {
      let #(prefix, _, suffix) = split_number(negative)
      #(prefix, suffix)
    })
  NumberPattern(
    prefix:,
    suffix:,
    negative:,
    primary:,
    secondary:,
    min_integer: count(integer_part, "0"),
    min_fraction: count(fraction_part, "0"),
    max_fraction: string.length(fraction_part),
  )
}

/// Split a pattern into the text before the number, the number, and the
/// text after it.
fn split_number(pattern: String) -> #(String, String, String) {
  let graphemes = string.to_graphemes(pattern)
  let is_number = fn(g) { g == "#" || g == "0" || g == "," || g == "." }
  let prefix = list.take_while(graphemes, fn(g) { !is_number(g) })
  let rest = list.drop(graphemes, list.length(prefix))
  let number = list.take_while(rest, is_number)
  let suffix = list.drop(rest, list.length(number))
  #(string.concat(prefix), string.concat(number), string.concat(suffix))
}

fn count(text: String, grapheme: String) -> Int {
  string.to_graphemes(text) |> list.count(fn(g) { g == grapheme })
}

fn float_number(
  numbers: data.Numbers,
  pattern: NumberPattern,
  number: Float,
  shift: Int,
  min_fraction: Int,
  max_fraction: Int,
  symbol: String,
) -> String {
  // Round the decimal representation, so binary multiplication cannot
  // turn a halfway value such as 1.005 into 1.0049999999999999.
  let max_fraction = int.max(max_fraction, 0)
  let #(whole, fraction) = decimal_parts(number, shift)
  let kept =
    string.slice(fraction, 0, max_fraction)
    |> string.pad_end(max_fraction, "0")
  let next =
    string.slice(fraction, max_fraction, 1)
    |> int.parse
    |> result.unwrap(0)
  let digits = case next >= 5 {
    True -> increment(whole <> kept)
    False -> whole <> kept
  }
  let whole =
    string.drop_end(digits, max_fraction)
    |> string.to_graphemes
    |> list.drop_while(fn(d) { d == "0" })
    |> string.concat
  let whole = case whole {
    "" -> "0"
    whole -> whole
  }
  let fraction =
    string.slice(digits, string.length(digits) - max_fraction, max_fraction)
    |> trim_zeros(min_fraction)
  let nonzero = string.to_graphemes(digits) |> list.any(fn(d) { d != "0" })
  render_number(
    numbers,
    pattern,
    whole,
    fraction,
    nonzero && number <. 0.0,
    symbol,
  )
}

fn decimal_parts(number: Float, shift: Int) -> #(String, String) {
  let text = case number >=. 0.0 && number <=. 0.0 {
    True -> "0.0"
    False -> float.to_string(float.absolute_value(number))
  }
  let #(base, exponent) = case string.split_once(text, "e") {
    Ok(#(base, exponent)) -> #(base, int.parse(exponent) |> result.unwrap(0))
    Error(Nil) -> #(text, 0)
  }
  let #(whole, fraction) = case string.split_once(base, ".") {
    Ok(parts) -> parts
    Error(Nil) -> #(base, "")
  }
  let digits = whole <> fraction
  let point = string.length(whole) + exponent + shift
  let length = string.length(digits)
  case point {
    point if point <= 0 -> #("0", string.repeat("0", 0 - point) <> digits)
    point if point >= length -> #(
      digits <> string.repeat("0", point - string.length(digits)),
      "",
    )
    point -> #(string.slice(digits, 0, point), string.drop_start(digits, point))
  }
}

fn increment(digits: String) -> String {
  case string.last(digits) {
    Error(Nil) -> "1"
    Ok("9") -> increment(string.drop_end(digits, 1)) <> "0"
    Ok(last) -> {
      let assert Ok(digit) = int.parse(last)
      string.drop_end(digits, 1) <> int.to_string(digit + 1)
    }
  }
}

fn trim_zeros(fraction: String, keep: Int) -> String {
  case string.length(fraction) > keep && string.ends_with(fraction, "0") {
    True -> trim_zeros(string.drop_end(fraction, 1), keep)
    False -> fraction
  }
}

fn power_of_ten(digits: Int) -> Int {
  int.product(list.repeat(10, digits))
}

fn render_number(
  numbers: data.Numbers,
  pattern: NumberPattern,
  whole: String,
  fraction: String,
  negative: Bool,
  symbol: String,
) -> String {
  let whole = string.pad_start(whole, pattern.min_integer, "0")
  let grouped = group(whole, pattern, numbers)
  let digits = case fraction {
    "" -> grouped
    _ -> grouped <> numbers.decimal <> fraction
  }
  let digits = substitute_digits(digits, numbers.digits)
  let #(prefix, suffix) = case negative, pattern.negative {
    True, Ok(#(prefix, suffix)) -> #(prefix, suffix)
    True, Error(Nil) -> #("-" <> pattern.prefix, pattern.suffix)
    False, _ -> #(pattern.prefix, pattern.suffix)
  }
  let prefix = affix(prefix, numbers, symbol)
  let suffix = affix(suffix, numbers, symbol)
  // A symbol made of letters, such as CHF, is kept apart from the digits.
  let prefix = case string.last(prefix) {
    Ok(last) if symbol != "" ->
      case is_letter(last) {
        True -> prefix <> "\u{00A0}"
        False -> prefix
      }
    _ -> prefix
  }
  let suffix = case string.first(suffix) {
    Ok(first) if symbol != "" ->
      case is_letter(first) {
        True -> "\u{00A0}" <> suffix
        False -> suffix
      }
    _ -> suffix
  }
  prefix <> digits <> suffix
}

fn affix(text: String, numbers: data.Numbers, symbol: String) -> String {
  text
  |> string.replace("¤", symbol)
  |> string.replace("%", numbers.percent)
  |> string.replace("-", numbers.minus)
  |> string.replace("'", "")
}

fn group(
  whole: String,
  pattern: NumberPattern,
  numbers: data.Numbers,
) -> String {
  let length = string.length(whole)
  case
    pattern.primary > 0 && length >= pattern.primary + numbers.minimum_grouping
  {
    False -> whole
    True -> {
      let head = string.drop_end(whole, pattern.primary)
      let tail = string.slice(whole, length - pattern.primary, pattern.primary)
      group_rest(head, pattern.secondary, numbers.group)
      <> numbers.group
      <> tail
    }
  }
}

fn group_rest(digits: String, size: Int, separator: String) -> String {
  let length = string.length(digits)
  case length > size && size > 0 {
    False -> digits
    True ->
      group_rest(string.drop_end(digits, size), size, separator)
      <> separator
      <> string.slice(digits, length - size, size)
  }
}

fn substitute_digits(text: String, digits: String) -> String {
  case digits {
    "" -> text
    _ -> {
      let native = string.to_graphemes(digits)
      string.to_graphemes(text)
      |> list.map(fn(g) {
        case int.parse(g) {
          Ok(n) -> list.drop(native, n) |> list.first |> result.unwrap(g)
          Error(Nil) -> g
        }
      })
      |> string.concat
    }
  }
}

fn is_letter(grapheme: String) -> Bool {
  case string.to_utf_codepoints(grapheme) {
    [c, ..] -> {
      let c = string.utf_codepoint_to_int(c)
      { c >= 65 && c <= 90 }
      || { c >= 97 && c <= 122 }
      || { c >= 0xC0 && c <= 0x24F && c != 0xD7 && c != 0xF7 }
      || { c >= 0x370 && c <= 0x52F }
    }
    [] -> False
  }
}

// -- Dates and times ---------------------------------------------------------

/// A date: `October 19, 2026` in English at `Long`.
pub fn date(translator: Translator, date: Date, style: Style) -> String {
  let data = i18n.data(translator)
  render_date(data, pick_style(data.dates.date, style), Ok(date), Error(Nil))
}

/// A time of day: `3:04 PM` in English at `Short`. `Long` and `Full`
/// include seconds.
pub fn time(translator: Translator, time: TimeOfDay, style: Style) -> String {
  let data = i18n.data(translator)
  render_date(data, pick_style(data.dates.time, style), Error(Nil), Ok(time))
}

/// A date and a time together, each at `style`.
pub fn date_time(
  translator: Translator,
  date: Date,
  time: TimeOfDay,
  style: Style,
) -> String {
  let data = i18n.data(translator)
  let date_text =
    render_date(data, pick_style(data.dates.date, style), Ok(date), Error(Nil))
  let time_text =
    render_date(data, pick_style(data.dates.time, style), Error(Nil), Ok(time))
  pick_style(data.dates.date_time, style)
  |> tokens
  |> list.map(fn(token) {
    case token {
      Literal(text) ->
        text
        |> string.replace("{1}", date_text)
        |> string.replace("{0}", time_text)
      Field(letter, size) -> string.repeat(letter, size)
    }
  })
  |> string.concat
}

/// A month and year, as in a calendar's heading: `October 2026`.
pub fn month_year(translator: Translator, year: Int, month: Month) -> String {
  let data = i18n.data(translator)
  render_date(
    data,
    data.dates.month_year,
    Ok(calendar.Date(year:, month:, day: 1)),
    Error(Nil),
  )
}

/// A day and month without the year: `October 19`.
pub fn month_day(translator: Translator, month: Month, day: Int) -> String {
  let data = i18n.data(translator)
  render_date(
    data,
    data.dates.month_day,
    Ok(calendar.Date(year: 2000, month:, day:)),
    Error(Nil),
  )
}

/// The names of the months, January first. `Wide` names are as used on
/// their own, as in a heading, which in some languages differs from their
/// form inside a date.
pub fn months(translator: Translator, width: Width) -> List(String) {
  let dates = i18n.data(translator).dates
  case width {
    Wide -> dates.months_standalone
    Abbreviated -> dates.months_short
    Narrow -> dates.months_narrow
  }
}

/// The names of the days of the week, Monday first. `Narrow` names are the
/// shortest the locale writes for a calendar's column headings, such as
/// `Mo` or `M`.
pub fn weekdays(translator: Translator, width: Width) -> List(String) {
  let dates = i18n.data(translator).dates
  case width {
    Wide -> dates.weekdays
    Abbreviated -> dates.weekdays_short
    Narrow -> dates.weekdays_narrow
  }
}

/// The day weeks start on where the locale is used, from 1 for Monday to
/// 7 for Sunday.
pub fn first_day_of_week(translator: Translator) -> Int {
  i18n.data(translator).first_day
}

fn pick_style(styles: Styles, style: Style) -> String {
  case style {
    Short -> styles.short
    Medium -> styles.medium
    Long -> styles.long
    Full -> styles.full
  }
}

type Token {
  Literal(String)
  Field(letter: String, size: Int)
}

/// Split a CLDR date pattern into fields, runs of one letter such as
/// `MMMM`, and literal text, which may be quoted: `'at'`, with `''` for an
/// apostrophe.
fn tokens(pattern: String) -> List(Token) {
  do_tokens(string.to_graphemes(pattern), []) |> list.reverse
}

fn do_tokens(graphemes: List(String), acc: List(Token)) -> List(Token) {
  case graphemes {
    [] -> acc
    ["'", "'", ..rest] -> do_tokens(rest, add_literal(acc, "'"))
    ["'", ..rest] -> {
      let #(quoted, rest) = take_quoted(rest, "")
      do_tokens(rest, add_literal(acc, quoted))
    }
    [g, ..rest] ->
      case is_ascii_letter(g) {
        True -> {
          let run = list.take_while(rest, fn(next) { next == g })
          let rest = list.drop(rest, list.length(run))
          do_tokens(rest, [Field(g, list.length(run) + 1), ..acc])
        }
        False -> do_tokens(rest, add_literal(acc, g))
      }
  }
}

fn take_quoted(
  graphemes: List(String),
  acc: String,
) -> #(String, List(String)) {
  case graphemes {
    [] -> #(acc, [])
    ["'", "'", ..rest] -> take_quoted(rest, acc <> "'")
    ["'", ..rest] -> #(acc, rest)
    [g, ..rest] -> take_quoted(rest, acc <> g)
  }
}

fn add_literal(acc: List(Token), text: String) -> List(Token) {
  case acc {
    [Literal(previous), ..rest] -> [Literal(previous <> text), ..rest]
    _ -> [Literal(text), ..acc]
  }
}

fn is_ascii_letter(g: String) -> Bool {
  case string.to_utf_codepoints(g) {
    [c] -> {
      let c = string.utf_codepoint_to_int(c)
      { c >= 65 && c <= 90 } || { c >= 97 && c <= 122 }
    }
    _ -> False
  }
}

fn render_date(
  data: Data,
  pattern: String,
  date: Result(Date, Nil),
  time: Result(TimeOfDay, Nil),
) -> String {
  let digits = data.numbers.digits
  let number = fn(n, size) {
    substitute_digits(string.pad_start(int.to_string(n), size, "0"), digits)
  }
  let dates = data.dates
  tokens(pattern)
  |> list.map(fn(token) {
    case token, date, time {
      Literal(text), _, _ -> text
      Field("G", _), Ok(date), _ ->
        case date.year > 0 {
          True -> dates.eras.1
          False -> dates.eras.0
        }
      Field("y", 2), Ok(date), _ -> number(date.year % 100, 2)
      Field("y", size), Ok(date), _ | Field("u", size), Ok(date), _ ->
        number(date.year, size)
      Field("M", size), Ok(date), _ | Field("L", size), Ok(date), _ -> {
        let month = calendar.month_to_int(date.month)
        case size, token {
          1, _ | 2, _ -> number(month, size)
          3, _ -> nth(dates.months_short, month - 1)
          4, Field("L", _) -> nth(dates.months_standalone, month - 1)
          4, _ -> nth(dates.months, month - 1)
          _, _ -> nth(dates.months_narrow, month - 1)
        }
      }
      Field("d", size), Ok(date), _ -> number(date.day, size)
      Field("E", size), Ok(date), _
      | Field("c", size), Ok(date), _
      | Field("e", size), Ok(date), _
      -> {
        let day = weekday_number(date) - 1
        let numeric = token != Field("E", size) && size <= 2
        case numeric, size {
          True, _ -> number(day + 1, 1)
          False, 4 -> nth(dates.weekdays, day)
          False, 5 -> first_grapheme(nth(dates.weekdays, day))
          False, 6 -> nth(dates.weekdays_narrow, day)
          False, _ -> nth(dates.weekdays_short, day)
        }
      }
      Field("a", _), _, Ok(time)
      | Field("b", _), _, Ok(time)
      | Field("B", _), _, Ok(time)
      ->
        case time.hours < 12 {
          True -> dates.am
          False -> dates.pm
        }
      Field("h", size), _, Ok(time) ->
        number(
          case time.hours % 12 {
            0 -> 12
            hour -> hour
          },
          size,
        )
      Field("H", size), _, Ok(time) -> number(time.hours, size)
      Field("K", size), _, Ok(time) -> number(time.hours % 12, size)
      Field("k", size), _, Ok(time) ->
        number(
          case time.hours {
            0 -> 24
            hour -> hour
          },
          size,
        )
      Field("m", size), _, Ok(time) -> number(time.minutes, size)
      Field("s", size), _, Ok(time) -> number(time.seconds, size)
      Field("S", size), _, Ok(time) ->
        string.pad_start(int.to_string(time.nanoseconds), 9, "0")
        |> string.slice(0, size)
        |> substitute_digits(digits)
      Field(letter, size), _, _ -> string.repeat(letter, size)
    }
  })
  |> string.concat
  |> string.trim
}

fn weekday_number(date: Date) -> Int {
  case calendar.day_of_week(date) {
    calendar.Monday -> 1
    calendar.Tuesday -> 2
    calendar.Wednesday -> 3
    calendar.Thursday -> 4
    calendar.Friday -> 5
    calendar.Saturday -> 6
    calendar.Sunday -> 7
  }
}

fn nth(items: List(String), index: Int) -> String {
  list.drop(items, index) |> list.first |> result.unwrap("")
}

fn first_grapheme(text: String) -> String {
  string.first(text) |> result.unwrap("")
}

// -- Relative times ----------------------------------------------------------

/// A time relative to now: `relative(t, -3, Day)` is `3 days ago`, and
/// `relative(t, 2, Hour)` is `in 2 hours`. Where the locale has a word for
/// the offset, it is used, so `-1` days is `yesterday` and `0` is `today`.
pub fn relative(translator: Translator, amount: Int, unit: Unit) -> String {
  let data = i18n.data(translator)
  let name = case unit {
    Second -> "second"
    Minute -> "minute"
    Hour -> "hour"
    Day -> "day"
    Week -> "week"
    Month -> "month"
    Quarter -> "quarter"
    Year -> "year"
  }
  let assert Ok(words) = list.key_find(data.relative, name)
    as "every locale has words for every unit"
  case list.key_find(words.named, amount) {
    Ok(word) -> word
    Error(Nil) -> {
      let forms = case amount < 0 {
        True -> words.past
        False -> words.future
      }
      let size = int.absolute_value(amount)
      let category = plural.to_string(plural.cardinal(data.tag, size))
      let pattern =
        list.key_find(forms, category)
        |> result.lazy_or(fn() { list.key_find(forms, "other") })
        |> result.unwrap("{0}")
      string.replace(pattern, "{0}", integer(translator, size))
    }
  }
}

// -- Lists -------------------------------------------------------------------

/// Items joined as a list of things that all apply: `a, b, and c`.
pub fn list(translator: Translator, items: List(String)) -> String {
  join(i18n.data(translator).lists.and, items)
}

/// Items joined as alternatives: `a, b, or c`.
pub fn or_list(translator: Translator, items: List(String)) -> String {
  join(i18n.data(translator).lists.or, items)
}

fn join(pattern: ListPattern, items: List(String)) -> String {
  let apply = fn(template, first, second) { join_pair(template, first, second) }
  case items {
    [] -> ""
    [only] -> only
    [first, second] -> apply(pattern.two, first, second)
    [first, ..rest] -> {
      let assert [last, before_last, ..middle] = list.reverse(rest)
      let tail = apply(pattern.end, before_last, last)
      let tail =
        list.fold(middle, tail, fn(tail, item) {
          apply(pattern.middle, item, tail)
        })
      apply(pattern.start, first, tail)
    }
  }
}

fn join_pair(pattern: String, first: String, second: String) -> String {
  case string.split_once(pattern, "{") {
    Error(Nil) -> pattern
    Ok(#(before, rest)) ->
      case string.split_once(rest, "}") {
        Error(Nil) -> pattern
        Ok(#(slot, after)) -> {
          let value = case slot {
            "0" -> first
            "1" -> second
            _ -> "{" <> slot <> "}"
          }
          before <> value <> join_pair(after, first, second)
        }
      }
  }
}
