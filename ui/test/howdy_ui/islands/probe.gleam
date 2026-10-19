//// An island in the place islands live, for island_test.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import howdy/ui/island.{type Island}
import lustre/element.{text}
import lustre/element/html

pub fn island() -> Island(Int, Int, Nil) {
  island.simple(
    init: fn(start) { start },
    update: fn(count, _) { count + 1 },
    view: fn(count) { html.output([], [text(int.to_string(count))]) },
    flags: decode.int,
    encode: json.int,
  )
}
