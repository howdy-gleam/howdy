//// JSON shapes the HTTP provider adapters share.

import gleam/json.{type Json}

/// A field for a list, left out of the object when the list is empty.
pub fn present(
  name: String,
  values: List(a),
  encode: fn(List(a)) -> Json,
) -> List(#(String, Json)) {
  case values {
    [] -> []
    values -> [#(name, encode(values))]
  }
}
