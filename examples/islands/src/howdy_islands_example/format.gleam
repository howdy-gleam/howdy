//// Shared by the server and the islands, so it must run in both.

import gleam/int

pub fn count(n: Int) -> String {
  "Count: " <> int.to_string(n)
}
