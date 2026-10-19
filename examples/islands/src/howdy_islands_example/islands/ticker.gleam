//// An island that counts on a timer. Its flags are the milliseconds
//// between ticks. The timer comes from `island.every`, so it stops when
//// the island is removed from the page, as when the live view at `/live`
//// swaps it for another.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import howdy/ui/island.{type Island}
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html

pub fn island() -> Island(Int, Int, Msg) {
  island.application(init:, update:, view:, flags: decode.int, encode: json.int)
}

pub type Msg {
  Tick
}

fn init(milliseconds: Int) -> #(Int, Effect(Msg)) {
  #(0, island.every(milliseconds, Tick))
}

fn update(ticks: Int, msg: Msg) -> #(Int, Effect(Msg)) {
  case msg {
    Tick -> #(ticks + 1, effect.none())
  }
}

fn view(ticks: Int) -> Element(Msg) {
  html.p([], [html.output([], [text(int.to_string(ticks))]), text(" ticks")])
}
