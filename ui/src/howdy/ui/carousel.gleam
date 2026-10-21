//// Carousels: slides side by side, one in view at a time, with previous
//// and next buttons.
////
//// ```gleam
//// carousel.carousel(words.english(), "tour", label: "Product tour", attributes: [], slides: [
////   carousel.slide([ui.card([], [text("One")])]),
////   carousel.slide([ui.card([], [text("Two")])]),
//// ])
//// ```
////
//// The slides scroll natively, snapping to each one, so swiping, a
//// trackpad and the keyboard all work; the buttons scroll by one slide.
//// Each slide is announced as "slide 2 of 5". Nothing moves on its own.
////
//// `styled` stacks the slides vertically, or loops from the last slide
//// back to the first. When the slide in view changes, the carousel fires a
//// `howdy-slide` event with the slide's index; a live view hears it with
//// `on_change`.
////
//// With `autoplay` in its attributes, a carousel moves on by itself,
//// wrapping round at the end. It waits while the pointer is over it or
//// focus is in it and while the page is hidden, and it has a pause
//// button. For people who ask for reduced motion it starts paused.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import howdy/ui/words.{type Words}
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event
import lustre/server_component
import sketch/css.{type Class}
import sketch/css/length.{rem}

pub opaque type Slide(msg) {
  Slide(children: List(Element(msg)))
}

pub fn slide(children: List(Element(msg))) -> Slide(msg) {
  Slide(children)
}

pub type Orientation {
  Horizontal
  /// Slides stacked, scrolling up and down. Give the carousel a height.
  Vertical
}

pub fn carousel(
  words: Words,
  id: String,
  label label: String,
  attributes attributes: List(Attribute(msg)),
  slides slides: List(Slide(msg)),
) -> Element(msg) {
  styled(
    words,
    id,
    label:,
    orientation: Horizontal,
    looping: False,
    attributes:,
    slides:,
  )
}

/// A carousel laid out another way. With `looping`, the next button on the
/// last slide goes back to the first, and previous on the first to the
/// last.
pub fn styled(
  words: Words,
  id: String,
  label label: String,
  orientation orientation: Orientation,
  looping looping: Bool,
  attributes attributes: List(Attribute(msg)),
  slides slides: List(Slide(msg)),
) -> Element(msg) {
  let count = list.length(slides)
  let viewport = id <> "-slides"
  let looping = case looping {
    True -> [attribute.data("loop", "")]
    False -> []
  }
  let orientation_name = case orientation {
    Horizontal -> "horizontal"
    Vertical -> "vertical"
  }
  html.section(
    [
      class(carousel_class(orientation)),
      attribute.data("orientation", orientation_name),
      attribute.data("index", "0"),
      attribute.id(id),
      attribute.aria_label(label),
      attribute.attribute("aria-roledescription", words.carousel),
      attribute.data("howdy-carousel", ""),
      ..list.append(looping, attributes)
    ],
    [
      html.div(
        [
          class(viewport_class(orientation)),
          attribute.id(viewport),
          attribute.tabindex(0),
        ],
        list.index_map(slides, fn(slide, index) {
          html.div(
            [
              class(slide_class()),
              attribute.role("group"),
              attribute.attribute("aria-roledescription", words.slide),
              attribute.aria_label(words.position(index + 1, count)),
            ],
            slide.children,
          )
        }),
      ),
      html.div([class(controls_class())], [
        // Shown only when the carousel plays by itself.
        html.button(
          [
            class(play_class()),
            attribute.type_("button"),
            attribute.aria_label(words.pause_slides),
            attribute.aria_controls(viewport),
            attribute.data("howdy-carousel-play", ""),
            attribute.data("text-pause", words.pause_slides),
            attribute.data("text-play", words.play_slides),
          ],
          // Drawn by the stylesheet: two bars, or a triangle once paused.
          [html.span([attribute.aria_hidden(True)], [])],
        ),
        control("previous", words.previous_slide, "‹", viewport),
        control("next", words.next_slide, "›", viewport),
      ]),
    ],
  )
}

fn control(
  which: String,
  label: String,
  symbol: String,
  viewport: String,
) -> Element(msg) {
  html.button(
    [
      class(control_class()),
      attribute.type_("button"),
      attribute.aria_label(label),
      attribute.aria_controls(viewport),
      attribute.data("howdy-carousel-" <> which, ""),
    ],
    [html.span([attribute.aria_hidden(True)], [text(symbol)])],
  )
}

/// Move to the next slide every `milliseconds`. Put it in the carousel's
/// attributes.
pub fn autoplay(milliseconds: Int) -> Attribute(msg) {
  attribute.data("autoplay", int.to_string(int.max(milliseconds, 1000)))
}

/// Hear which slide is in view, counting from 0, in a live view.
pub fn on_change(message: fn(Int) -> msg) -> Attribute(msg) {
  event.on("howdy-slide", {
    use index <- decode.subfield(["detail", "index"], decode.int)
    decode.success(message(index))
  })
  |> server_component.include(["detail.index"])
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    carousel_class(Horizontal),
    carousel_class(Vertical),
    viewport_class(Horizontal),
    viewport_class(Vertical),
    slide_class(),
    controls_class(),
    control_class(),
    play_class(),
  ]
}

pub fn carousel_class(orientation: Orientation) -> Class {
  let arrows = case orientation {
    Horizontal -> []
    // The buttons' arrows turn to point up and down.
    Vertical -> [
      css.selector(" [data-howdy-carousel-previous] > span", [
        css.display("inline-block"),
        css.transform_("rotate(90deg)"),
      ]),
      css.selector(" [data-howdy-carousel-next] > span", [
        css.display("inline-block"),
        css.transform_("rotate(90deg)"),
      ]),
    ]
  }
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(0.75)),
    css.selector(" [data-howdy-carousel-play] > span", [
      css.display("block"),
      css.property("width", "0.625rem"),
      css.property("height", "0.75rem"),
      css.property("border-inline", "3px solid currentColor"),
    ]),
    css.selector("[data-paused] [data-howdy-carousel-play] > span", [
      css.property("width", "0"),
      css.property("height", "0"),
      css.property("border-inline", "0"),
      css.property("border-top", "0.375rem solid transparent"),
      css.property("border-bottom", "0.375rem solid transparent"),
      css.property("border-left", "0.625rem solid currentColor"),
      css.property("margin-left", "0.125rem"),
    ]),
    ..arrows
  ])
}

pub fn viewport_class(orientation: Orientation) -> Class {
  let axis = case orientation {
    Horizontal -> [
      css.flex_direction("row"),
      css.overflow_x("auto"),
      css.property("scroll-snap-type", "x mandatory"),
      css.property("overscroll-behavior-x", "contain"),
    ]
    Vertical -> [
      css.flex_direction("column"),
      css.property("flex", "1"),
      css.property("min-height", "0"),
      css.overflow_y("auto"),
      css.property("scroll-snap-type", "y mandatory"),
      css.property("overscroll-behavior-y", "contain"),
    ]
  }
  css.class(list.append(
    [
      css.display("flex"),
      css.gap(rem(1.0)),
      css.property("scrollbar-width", "none"),
      style.radius(tokens.radius_medium),
      style.focus_ring(),
    ],
    axis,
  ))
}

pub fn slide_class() -> Class {
  css.class([
    css.property("flex", "0 0 100%"),
    css.property("scroll-snap-stop", "always"),
    css.property("scroll-snap-align", "start"),
    css.property("min-width", "0"),
  ])
}

pub fn controls_class() -> Class {
  css.class([
    css.display("flex"),
    css.justify_content("flex-end"),
    css.gap(rem(0.5)),
  ])
}

pub fn control_class() -> Class {
  css.class([
    // Arrows point the way the text runs.
    css.selector(":dir(rtl) > span", [
      css.display("inline-block"),
      css.transform_("scaleX(-1)"),
    ]),
    css.display("inline-flex"),
    css.align_items("center"),
    css.justify_content("center"),
    css.property("width", "2.25rem"),
    css.property("height", "2.25rem"),
    css.padding(rem(0.0)),
    style.bordered(),
    style.pill(),
    css.background(tokens.surface),
    css.color(tokens.text),
    css.font_size(rem(1.25)),
    css.line_height("1"),
    css.cursor("pointer"),
    css.hover([css.background(tokens.muted)]),
    style.focus_ring(),
  ])
}

pub fn play_class() -> Class {
  css.class([
    css.display("inline-flex"),
    css.align_items("center"),
    css.justify_content("center"),
    css.property("width", "2.25rem"),
    css.property("height", "2.25rem"),
    css.property("margin-inline-end", "auto"),
    css.padding(rem(0.0)),
    style.bordered(),
    style.pill(),
    css.background(tokens.surface),
    css.color(tokens.text),
    css.font_size(rem(0.75)),
    css.line_height("1"),
    css.cursor("pointer"),
    css.hover([css.background(tokens.muted)]),
    style.focus_ring(),
    css.selector(":not([data-howdy-carousel][data-autoplay] *)", [
      css.display("none"),
    ]),
  ])
}
