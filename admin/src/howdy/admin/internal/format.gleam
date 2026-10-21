//// Numbers and moments as the pages print them.

import gleam/float
import gleam/int
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}

/// `1 user`, `2 users`.
pub fn describe(count: Int, noun: String) -> String {
  int.to_string(count)
  <> " "
  <> case count {
    1 -> noun
    _ -> noun <> "s"
  }
}

/// A moment as RFC 3339 in UTC, such as `2026-09-25T14:03:07Z`.
pub fn at(time: Timestamp) -> String {
  timestamp.to_rfc3339(time, calendar.utc_offset)
}

/// Unix seconds as `at` prints them.
pub fn at_seconds(seconds: Int) -> String {
  at(timestamp.from_unix_seconds(seconds))
}

/// `2026-09-25 14:03:07`, in UTC.
pub fn date_time(time: Timestamp) -> String {
  at(time)
  |> string.slice(0, 19)
  |> string.replace("T", " ")
}

/// A duration in microseconds, in the unit that reads best.
pub fn duration(microseconds: Int) -> String {
  case microseconds {
    us if us < 1000 -> int.to_string(us) <> " µs"
    us if us < 10_000 ->
      float.to_string(float.to_precision(int.to_float(us) /. 1000.0, 1))
      <> " ms"
    us if us < 1_000_000 -> int.to_string(us / 1000) <> " ms"
    us ->
      float.to_string(float.to_precision(int.to_float(us) /. 1_000_000.0, 2))
      <> " s"
  }
}

/// The time of day of a moment in microseconds since the epoch, in UTC, to
/// the millisecond.
pub fn clock(microseconds: Int) -> String {
  let seconds =
    at_seconds(microseconds / 1_000_000)
    |> string.slice(11, 8)
  let milliseconds = { microseconds % 1_000_000 } / 1000
  seconds <> "." <> string.pad_start(int.to_string(milliseconds), 3, "0")
}
