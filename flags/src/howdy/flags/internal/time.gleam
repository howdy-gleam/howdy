//// Moments and durations as the package keeps them: unix seconds.

import gleam/int
import gleam/time/timestamp

/// The current time in unix seconds, the unit stores keep and ramps
/// schedule in.
pub fn now() -> Int {
  let #(seconds, _) =
    timestamp.to_unix_seconds_and_nanoseconds(timestamp.system_time())
  seconds
}

/// Seconds as `2d`, `1h`, `30m` or `90s`: the largest unit that divides
/// them.
pub fn duration(seconds: Int) -> String {
  case seconds {
    _ if seconds % 86_400 == 0 -> int.to_string(seconds / 86_400) <> "d"
    _ if seconds % 3600 == 0 -> int.to_string(seconds / 3600) <> "h"
    _ if seconds % 60 == 0 -> int.to_string(seconds / 60) <> "m"
    _ -> int.to_string(seconds) <> "s"
  }
}
