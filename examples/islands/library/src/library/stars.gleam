//// How a rating reads, shared by the island and anything else.

import gleam/int

pub fn describe(rating: Int, out_of: Int) -> String {
  int.to_string(rating) <> " out of " <> int.to_string(out_of)
}
