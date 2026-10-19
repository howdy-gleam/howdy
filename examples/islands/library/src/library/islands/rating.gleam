//// A star rating, shipped by a package. An app mounts it like its own
//// islands: `island.mount(rating.island, with: 3)`.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import howdy/ui/button
import howdy/ui/island.{type Island}
import library/stars
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event

const out_of = 5

pub fn island() -> Island(Int, Int, Int) {
  island.simple(
    init: fn(rating) { int.clamp(rating, 0, out_of) },
    update: fn(_, rating) { rating },
    view:,
    flags: decode.int,
    encode: json.int,
  )
}

fn view(rating: Int) -> Element(Int) {
  html.div([attribute.role("group"), attribute.aria_label("Rating")], [
    html.span(
      [],
      list.map([1, 2, 3, 4, 5], fn(star) {
        button.sized(
          button.Ghost,
          button.Icon,
          [
            event.on_click(star),
            attribute.aria_label("Rate " <> int.to_string(star)),
            attribute.aria_pressed(case star <= rating {
              True -> "true"
              False -> "false"
            }),
          ],
          [
            text(case star <= rating {
              True -> "★"
              False -> "☆"
            }),
          ],
        )
      }),
    ),
    html.output([], [text(stars.describe(rating, out_of))]),
  ])
}
