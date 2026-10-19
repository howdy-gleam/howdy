//// The shape of the CLDR data for one locale. Values are filled in by the
//// modules under `internal/cldr`, which scripts/cldr.mjs generates.

pub type Data {
  Data(
    tag: String,
    /// The locale's name in its own language, such as "Deutsch".
    name: String,
    /// The first day of the week, from 1 for Monday to 7 for Sunday.
    first_day: Int,
    numbers: Numbers,
    dates: Dates,
    /// Relative time words for each unit, such as "day".
    relative: List(#(String, Relative)),
    lists: Lists,
    /// Currency symbols by ISO 4217 code.
    currencies: List(#(String, String)),
  )
}

pub type Numbers {
  Numbers(
    decimal: String,
    group: String,
    currency_decimal: String,
    currency_group: String,
    minus: String,
    percent: String,
    /// The ten digits to write numbers with, or "" for 0 to 9.
    digits: String,
    decimal_pattern: String,
    percent_pattern: String,
    currency_pattern: String,
    /// Group digits only when there are at least this many before the
    /// first separator, so Spanish writes 1234 but 12 345.
    minimum_grouping: Int,
  )
}

pub type Dates {
  Dates(
    /// January first, as used in dates.
    months: List(String),
    months_short: List(String),
    /// January first, as used on their own, as in a calendar's heading.
    months_standalone: List(String),
    months_narrow: List(String),
    /// Monday first.
    weekdays: List(String),
    weekdays_short: List(String),
    weekdays_narrow: List(String),
    am: String,
    pm: String,
    eras: #(String, String),
    date: Styles,
    time: Styles,
    /// How a date `{1}` and a time `{0}` combine.
    date_time: Styles,
    month_year: String,
    month_day: String,
  )
}

pub type Styles {
  Styles(full: String, long: String, medium: String, short: String)
}

pub type Relative {
  Relative(
    /// Patterns by plural category, with `{0}` for the number.
    future: List(#(String, String)),
    past: List(#(String, String)),
    /// Words for particular offsets, such as -1 for "yesterday".
    named: List(#(Int, String)),
  )
}

pub type Lists {
  Lists(and: ListPattern, or: ListPattern)
}

pub type ListPattern {
  ListPattern(two: String, start: String, middle: String, end: String)
}
