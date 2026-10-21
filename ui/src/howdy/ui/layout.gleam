//// Containers, stacks, rows and separators.

import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{percent, px, rem}

/// A centred column with a maximum width and page padding.
pub fn container(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([class(container_class()), ..attributes], children)
}

/// Children stacked vertically with a gap.
pub fn stack(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([class(stack_class()), ..attributes], children)
}

/// Children in a row with a gap, wrapping when they run out of room.
pub fn row(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([class(row_class()), ..attributes], children)
}

/// Which way a separator runs.
pub type Orientation {
  Horizontal
  Vertical
}

/// A line between sections. A vertical one divides the items of a `row`.
pub fn separator(
  orientation: Orientation,
  attributes: List(Attribute(msg)),
) -> Element(msg) {
  case orientation {
    Horizontal -> html.hr([class(separator_class(Horizontal)), ..attributes])
    Vertical ->
      html.div(
        [
          class(separator_class(Vertical)),
          attribute.role("separator"),
          attribute.aria_orientation("vertical"),
          ..attributes
        ],
        [],
      )
  }
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    container_class(),
    stack_class(),
    row_class(),
    separator_class(Horizontal),
    separator_class(Vertical),
  ]
}

pub fn container_class() -> Class {
  css.class([
    css.max_width(px(960)),
    css.margin_("0 auto"),
    css.padding(rem(1.5)),
  ])
}

pub fn stack_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(1.0)),
  ])
}

pub fn row_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_wrap("wrap"),
    css.align_items("center"),
    css.gap(rem(0.75)),
  ])
}

pub fn separator_class(orientation: Orientation) -> Class {
  let shape = case orientation {
    Horizontal -> [
      css.height(px(1)),
      css.width(percent(100)),
      css.margin(rem(0.0)),
    ]
    Vertical -> [
      css.width(px(1)),
      css.align_self("stretch"),
      css.property("min-height", "1em"),
    ]
  }
  css.class([
    css.flex_shrink(0.0),
    css.border("0"),
    css.background(tokens.border),
    ..shape
  ])
}
