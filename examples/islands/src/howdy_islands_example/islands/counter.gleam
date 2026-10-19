//// A counter island. Its flags are the starting count.

import gleam/dynamic/decode
import gleam/json
import howdy/ui/island.{type Island}
import howdy_islands_example/format
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event

pub fn island() -> Island(Int, Int, Msg) {
  island.simple(init:, update:, view:, flags: decode.int, encode: json.int)
}

pub type Msg {
  Increment
  Decrement
}

fn init(start: Int) -> Int {
  start
}

fn update(count: Int, msg: Msg) -> Int {
  case msg {
    Increment -> count + 1
    Decrement -> count - 1
  }
}

fn view(count: Int) -> Element(Msg) {
  html.div([attribute.class("counter")], [
    html.button([event.on_click(Decrement)], [text("-")]),
    html.output([], [text(format.count(count))]),
    html.button([event.on_click(Increment)], [text("+")]),
  ])
}
