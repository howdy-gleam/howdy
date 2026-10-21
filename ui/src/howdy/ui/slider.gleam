//// Sliders: pick a number from a range by dragging or with the arrow keys.
////
//// ```gleam
//// slider.slider([attribute.name("volume"), attribute.min("0"), attribute.max("100"), attribute.value("40")])
//// ```
////
//// A slider is the browser's own range input in the theme's primary
//// colour, so it works with a keyboard, a pointer and a form as usual.
//// Label it, and show the value beside it when it matters.

import gleam/int
import gleam/list
import gleam/pair
import gleam/result
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import howdy/ui/words.{type Words}
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{percent, rem}

pub fn slider(attributes: List(Attribute(msg))) -> Element(msg) {
  html.input([class(slider_class()), attribute.type_("range"), ..attributes])
}

pub type Orientation {
  Horizontal
  /// Upright, with the lowest value at the bottom. Ten rems tall unless
  /// given a height.
  Vertical
}

/// Stand a single slider upright, lowest value at the bottom. Put it in
/// the slider's attributes.
pub fn vertical() -> Attribute(msg) {
  attribute.data("orientation", "vertical")
}

/// A range with two thumbs, for a lower and an upper value, such as a
/// price between £20 and £80. Each thumb is its own range input, named
/// `low_name` and `high_name`, so both submit with a form and each can be
/// moved with the keyboard; the thumbs cannot pass each other. `label`
/// names the pair, and each thumb is announced as its minimum or maximum,
/// in the words' language.
pub fn range(
  words words: Words,
  label label: String,
  min min: Int,
  max max: Int,
  low low: Int,
  high high: Int,
  low_name low_name: String,
  high_name high_name: String,
  attributes attributes: List(Attribute(msg)),
) -> Element(msg) {
  thumbs(
    words:,
    label:,
    min:,
    max:,
    orientation: Horizontal,
    values: [#(low_name, low), #(high_name, high)],
    attributes:,
  )
}

/// A range with a thumb for each of `values`, given as `#(name, value)`
/// in order, such as three thumbs splitting a day into four parts. Each is
/// a range input submitted under its name, and none can pass its
/// neighbours. The track is filled from the first thumb to the last. Two
/// thumbs are announced as the minimum and maximum; more as "2 of 3".
pub fn thumbs(
  words words: Words,
  label label: String,
  min min: Int,
  max max: Int,
  orientation orientation: Orientation,
  values values: List(#(String, Int)),
  attributes attributes: List(Attribute(msg)),
) -> Element(msg) {
  let span = int.max(max - min, 1)
  let count = list.length(values)
  // Each value at least the one before it, all within the range.
  let values =
    values
    |> list.map_fold(min, fn(floor, pair) {
      let value = int.clamp(pair.1, floor, max)
      #(value, #(pair.0, value))
    })
    |> pair.second
  let percent_of = fn(value) {
    int.to_string({ value - min } * 100 / span) <> "%"
  }
  let first =
    list.first(values) |> result.map(pair.second) |> result.unwrap(min)
  let last = list.last(values) |> result.map(pair.second) |> result.unwrap(max)
  let which = fn(index) {
    case count, index {
      2, 0 -> words.minimum
      2, _ -> words.maximum
      _, _ -> words.position(index + 1, count)
    }
  }
  html.div(
    [
      class(range_class(orientation)),
      attribute.role("group"),
      attribute.aria_label(label),
      attribute.data("howdy-range", ""),
      attribute.style("--low", percent_of(first)),
      attribute.style("--high", percent_of(last)),
      ..attributes
    ],
    [
      html.div([class(track_class(orientation)), attribute.aria_hidden(True)], [
        html.div([class(fill_class(orientation))], []),
      ]),
      ..list.index_map(values, fn(pair, index) {
        html.input([
          class(thumb_class(orientation)),
          attribute.type_("range"),
          attribute.name(pair.0),
          attribute.min(int.to_string(min)),
          attribute.max(int.to_string(max)),
          attribute.value(int.to_string(pair.1)),
          attribute.aria_label(label <> ", " <> which(index)),
          attribute.aria_orientation(case orientation {
            Horizontal -> "horizontal"
            Vertical -> "vertical"
          }),
        ])
      })
    ],
  )
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  list.flatten([
    [slider_class()],
    list.flat_map([Horizontal, Vertical], fn(orientation) {
      [
        range_class(orientation),
        track_class(orientation),
        fill_class(orientation),
        thumb_class(orientation),
      ]
    }),
  ])
}

pub fn range_class(orientation: Orientation) -> Class {
  case orientation {
    Horizontal ->
      css.class([
        css.position("relative"),
        css.width(percent(100)),
        css.property("height", "1.25rem"),
      ])
    Vertical ->
      css.class([
        css.position("relative"),
        css.property("width", "1.25rem"),
        css.property("height", "10rem"),
      ])
  }
}

pub fn track_class(orientation: Orientation) -> Class {
  let axis = case orientation {
    Horizontal -> [
      css.property("inset-inline", "0"),
      css.property("top", "50%"),
      css.property("height", "0.375rem"),
      css.transform_("translateY(-50%)"),
    ]
    Vertical -> [
      css.property("top", "0"),
      css.property("bottom", "0"),
      css.property("left", "50%"),
      css.property("width", "0.375rem"),
      css.transform_("translateX(-50%)"),
    ]
  }
  css.class([
    css.position("absolute"),
    style.pill(),
    css.background(tokens.muted),
    ..axis
  ])
}

pub fn fill_class(orientation: Orientation) -> Class {
  let axis = case orientation {
    Horizontal -> [
      css.property("inset-block", "0"),
      css.property("inset-inline-start", "var(--low)"),
      css.property("inset-inline-end", "calc(100% - var(--high))"),
    ]
    // The lowest value is at the bottom.
    Vertical -> [
      css.property("left", "0"),
      css.property("right", "0"),
      css.property("bottom", "var(--low)"),
      css.property("top", "calc(100% - var(--high))"),
    ]
  }
  css.class([
    css.position("absolute"),
    style.pill(),
    css.background(tokens.primary),
    ..axis
  ])
}

// Both inputs cover the track; only their thumbs take the pointer, so
// either can be dragged wherever they sit.
fn thumb_styles() -> List(css.Style) {
  [
    css.property("appearance", "none"),
    css.property("pointer-events", "auto"),
    css.property("width", "1.125rem"),
    css.property("height", "1.125rem"),
    style.pill(),
    css.background(tokens.surface),
    css.border("2px solid " <> tokens.primary),
    css.box_shadow("0 1px 3px rgb(0 0 0 / 0.25)"),
    css.cursor("grab"),
  ]
}

pub fn thumb_class(orientation: Orientation) -> Class {
  let axis = case orientation {
    Horizontal -> [css.width(percent(100))]
    Vertical -> [
      css.width(percent(100)),
      css.height(percent(100)),
      css.property("writing-mode", "vertical-lr"),
      css.property("direction", "rtl"),
    ]
  }
  css.class([
    css.position("absolute"),
    css.inset("0"),
    css.margin(rem(0.0)),
    css.property("appearance", "none"),
    css.background("transparent"),
    css.property("pointer-events", "none"),
    css.selector("::-webkit-slider-thumb", thumb_styles()),
    css.selector("::-moz-range-thumb", thumb_styles()),
    css.selector("::-webkit-slider-runnable-track", [
      css.background("transparent"),
    ]),
    css.selector("::-moz-range-track", [css.background("transparent")]),
    css.selector(":focus-visible::-webkit-slider-thumb", [
      css.property("outline", "2px solid " <> tokens.focus),
      css.property("outline-offset", "2px"),
    ]),
    css.selector(":focus-visible::-moz-range-thumb", [
      css.property("outline", "2px solid " <> tokens.focus),
      css.property("outline-offset", "2px"),
    ]),
    css.outline("none"),
    ..axis
  ])
}

pub fn slider_class() -> Class {
  css.class([
    css.display("block"),
    css.width(percent(100)),
    css.margin(rem(0.0)),
    css.property("accent-color", tokens.primary),
    css.cursor("pointer"),
    style.focus_ring_offset("4px"),
    style.disabled_look(),
    css.selector("[data-orientation=\"vertical\"]", [
      css.property("writing-mode", "vertical-lr"),
      css.property("direction", "rtl"),
      css.width_("auto"),
      css.property("height", "10rem"),
    ]),
  ])
}
