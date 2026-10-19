//// When a scheduled job runs, in cron's five fields: minute, hour, day of
//// the month, month and day of the week, all in UTC.
////
//// ```gleam
//// let assert Ok(nightly) = cron.parse("0 3 * * *")
//// let assert Ok(weekdays) = cron.parse("*/15 9-17 * * mon-fri")
//// ```
////
//// Each field takes `*`, a number, a range such as `9-17`, a step such as
//// `*/15` or `0-30/10`, or a list of those separated by commas. Months may
//// be written `jan` to `dec` and days of the week `sun` to `sat`, where `0`
//// and `7` are both Sunday. `@hourly`, `@daily` (or `@midnight`),
//// `@weekly`, `@monthly` and `@yearly` (or `@annually`) stand for the usual
//// schedules.
////
//// As in most crons, when both the day of the month and the day of the week
//// are restricted, a day matching either one counts: `0 0 1 * mon` runs on
//// the first of each month and on every Monday.

import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// A parsed schedule.
pub opaque type Cron {
  Cron(
    source: String,
    minutes: Int,
    hours: Int,
    days: Int,
    months: Int,
    weekdays: Int,
    either_day: Bool,
  )
}

/// Read a schedule, or say what is wrong with it.
pub fn parse(text: String) -> Result(Cron, String) {
  let source = string.trim(text)
  let expanded = case string.lowercase(source) {
    "@yearly" | "@annually" -> "0 0 1 1 *"
    "@monthly" -> "0 0 1 * *"
    "@weekly" -> "0 0 * * 0"
    "@daily" | "@midnight" -> "0 0 * * *"
    "@hourly" -> "0 * * * *"
    other -> other
  }
  let fields =
    expanded
    |> string.replace("\t", " ")
    |> string.split(" ")
    |> list.filter(fn(field) { field != "" })
  case fields {
    [minute, hour, day, month, weekday] -> {
      use minutes <- result.try(field(minute, "minute", 0, 59, []))
      use hours <- result.try(field(hour, "hour", 0, 23, []))
      use days <- result.try(field(day, "day of the month", 1, 31, []))
      use months <- result.try(field(month, "month", 1, 12, month_names))
      use weekdays <- result.try(field(
        weekday,
        "day of the week",
        0,
        7,
        weekday_names,
      ))
      // 7 is another way of writing Sunday.
      let weekdays = case bit(weekdays, 7) {
        True -> int.bitwise_or(weekdays, 1)
        False -> weekdays
      }
      let either_day =
        !string.starts_with(day, "*") && !string.starts_with(weekday, "*")
      let cron =
        Cron(source:, minutes:, hours:, days:, months:, weekdays:, either_day:)
      // A schedule such as `0 0 30 2 *` is well formed but never comes.
      case next(cron, 0) {
        Ok(_) -> Ok(cron)
        Error(Nil) -> Error("the schedule never comes round: " <> source)
      }
    }
    _ ->
      Error(
        "a schedule needs five fields (minute hour day month weekday): "
        <> source,
      )
  }
}

/// The schedule as it was written.
pub fn to_string(cron: Cron) -> String {
  cron.source
}

/// The first minute the schedule matches strictly after `after`, both in
/// unix milliseconds. An `Error` only for a schedule that never comes
/// round, which `parse` refuses.
pub fn next(cron: Cron, after milliseconds: Int) -> Result(Int, Nil) {
  let minute = int.floor_divide(milliseconds, 60_000) |> result.unwrap(0)
  search(cron, minute + 1, 0)
  |> result.map(fn(minute) { minute * 60_000 })
}

/// Enough jumps to cross every month, day and hour of several years.
const give_up_after = 200_000

fn search(cron: Cron, minute: Int, tried: Int) -> Result(Int, Nil) {
  use <- guard(tried > give_up_after)
  let days = minute / 1440
  let in_day = minute % 1440
  let hour = in_day / 60
  let #(year, month, day) = civil(days)
  case bit(cron.months, month) {
    False -> {
      let #(year, month) = case month {
        12 -> #(year + 1, 1)
        _ -> #(year, month + 1)
      }
      search(cron, days_from_civil(year, month, 1) * 1440, tried + 1)
    }
    True ->
      case day_matches(cron, day, weekday(days)) {
        False -> search(cron, { days + 1 } * 1440, tried + 1)
        True ->
          case bit(cron.hours, hour) {
            False -> search(cron, days * 1440 + { hour + 1 } * 60, tried + 1)
            True ->
              case bit(cron.minutes, in_day % 60) {
                False -> search(cron, minute + 1, tried + 1)
                True -> Ok(minute)
              }
          }
      }
  }
}

fn guard(stop: Bool, otherwise: fn() -> Result(a, Nil)) -> Result(a, Nil) {
  case stop {
    True -> Error(Nil)
    False -> otherwise()
  }
}

fn day_matches(cron: Cron, day: Int, weekday: Int) -> Bool {
  let by_date = bit(cron.days, day)
  let by_weekday = bit(cron.weekdays, weekday)
  case cron.either_day {
    True -> by_date || by_weekday
    False -> by_date && by_weekday
  }
}

fn bit(mask: Int, n: Int) -> Bool {
  int.bitwise_and(mask, int.bitwise_shift_left(1, n)) != 0
}

// -- Fields -------------------------------------------------------------------

const month_names = [
  #("jan", 1),
  #("feb", 2),
  #("mar", 3),
  #("apr", 4),
  #("may", 5),
  #("jun", 6),
  #("jul", 7),
  #("aug", 8),
  #("sep", 9),
  #("oct", 10),
  #("nov", 11),
  #("dec", 12),
]

const weekday_names = [
  #("sun", 0),
  #("mon", 1),
  #("tue", 2),
  #("wed", 3),
  #("thu", 4),
  #("fri", 5),
  #("sat", 6),
]

/// A field as a mask with bit `n` set for each value `n` it allows.
fn field(
  text: String,
  name: String,
  low: Int,
  high: Int,
  names: List(#(String, Int)),
) -> Result(Int, String) {
  let invalid = fn() { Error("the " <> name <> " field is invalid: " <> text) }
  text
  |> string.split(",")
  |> list.try_fold(0, fn(mask, part) {
    let #(range, step) = case string.split_once(part, "/") {
      Ok(#(range, step)) -> #(range, int.parse(step))
      Error(Nil) -> #(part, Ok(1))
    }
    let bounds = case range, step {
      "*", _ -> Ok(#(low, high))
      _, _ ->
        case string.split_once(range, "-") {
          Ok(#(from, to)) -> {
            use from <- result.try(value(from, names))
            use to <- result.map(value(to, names))
            #(from, to)
          }
          Error(Nil) -> {
            use from <- result.map(value(range, names))
            // `5/15` runs from 5 to the end in steps of 15.
            case part == range {
              True -> #(from, from)
              False -> #(from, high)
            }
          }
        }
    }
    case bounds, step {
      Ok(#(from, to)), Ok(step)
        if from >= low && to <= high && from <= to && step > 0
      -> Ok(fill(mask, from, to, step))
      _, _ -> invalid()
    }
  })
}

fn value(text: String, names: List(#(String, Int))) -> Result(Int, Nil) {
  case int.parse(text) {
    Ok(n) -> Ok(n)
    Error(Nil) -> list.key_find(names, text)
  }
}

fn fill(mask: Int, from: Int, to: Int, step: Int) -> Int {
  case from > to {
    True -> mask
    False ->
      fill(
        int.bitwise_or(mask, int.bitwise_shift_left(1, from)),
        from + step,
        to,
        step,
      )
  }
}

// -- Calendar -----------------------------------------------------------------
// Howard Hinnant's algorithms between days since 1970-01-01 and the
// proleptic Gregorian calendar.

fn civil(days: Int) -> #(Int, Int, Int) {
  let z = days + 719_468
  let era = z / 146_097
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
  case month <= 2 {
    True -> #(year + 1, month, day)
    False -> #(year, month, day)
  }
}

fn days_from_civil(year: Int, month: Int, day: Int) -> Int {
  let year = case month <= 2 {
    True -> year - 1
    False -> year
  }
  let era = year / 400
  let yoe = year - era * 400
  let mp = case month > 2 {
    True -> month - 3
    False -> month + 9
  }
  let doy = { 153 * mp + 2 } / 5 + day - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146_097 + doe - 719_468
}

/// Sunday is 0. 1970-01-01 was a Thursday.
fn weekday(days: Int) -> Int {
  { days + 4 } % 7
}
