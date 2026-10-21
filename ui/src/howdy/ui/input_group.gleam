//// Input groups: a text input with text, icons or buttons inside its
//// border.
////
//// ```gleam
//// input_group.group([], [
////   input_group.addon([text("https://")]),
////   input_group.input([attribute.aria_label("Website"), attribute.placeholder("example.com")]),
////   input_group.addon([button.sized(Ghost, Small, [], [text("Check")])]),
//// ])
//// ```
////
//// The group draws the border and the focus ring, so the whole thing reads
//// as one field. Use `input` for the text field inside it: the plain
//// `howdy/ui/input` brings its own border.

import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{percent, rem}

pub fn group(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div(
    [class(group_class()), attribute.role("group"), ..attributes],
    children,
  )
}

/// The text field inside a group.
pub fn input(attributes: List(Attribute(msg))) -> Element(msg) {
  html.input([class(input_class()), ..attributes])
}

/// A multiline text field inside a group, such as a message composer.
pub fn textarea(
  attributes: List(Attribute(msg)),
  content: String,
) -> Element(msg) {
  html.textarea([class(textarea_class()), ..attributes], content)
}

/// Text, an icon or a button at either end of the field.
pub fn addon(children: List(Element(msg))) -> Element(msg) {
  html.div([class(addon_class())], children)
}

/// A row above the field, across its whole width, such as a label or a
/// toolbar.
pub fn block_start(children: List(Element(msg))) -> Element(msg) {
  html.div([class(block_class()), class(block_start_class())], children)
}

/// A row below the field, across its whole width, such as a character
/// count and a send button.
pub fn block_end(children: List(Element(msg))) -> Element(msg) {
  html.div([class(block_class()), class(block_end_class())], children)
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    group_class(),
    input_class(),
    textarea_class(),
    addon_class(),
    block_class(),
    block_start_class(),
    block_end_class(),
  ]
}

pub fn group_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_wrap("wrap"),
    css.align_items("center"),
    css.width(percent(100)),
    css.background(tokens.surface),
    style.bordered(),
    style.radius(tokens.radius_medium),
    css.focus_within([
      style.focus_outline(),
      css.property("outline-offset", "2px"),
    ]),
    css.selector(":has([aria-invalid=\"true\"])", [
      css.property("border-color", tokens.danger),
    ]),
  ])
}

pub fn input_class() -> Class {
  css.class([
    css.property("flex", "1"),
    css.property("min-width", "0"),
    css.padding_(tokens.space_2 <> " " <> tokens.space_3),
    css.border("0"),
    css.background("transparent"),
    css.color(tokens.text),
    css.font_family(tokens.font_body),
    css.font_size(rem(1.0)),
    css.outline("none"),
    css.placeholder([css.color(tokens.text_muted)]),
  ])
}

pub fn textarea_class() -> Class {
  css.class([
    css.property("flex", "1"),
    css.property("min-width", "0"),
    css.property("min-height", "4.5rem"),
    css.padding_(tokens.space_2 <> " " <> tokens.space_3),
    css.border("0"),
    css.background("transparent"),
    css.color(tokens.text),
    css.font_family(tokens.font_body),
    css.font_size(rem(1.0)),
    css.line_height("1.5"),
    css.property("resize", "vertical"),
    css.outline("none"),
    css.placeholder([css.color(tokens.text_muted)]),
  ])
}

pub fn block_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_wrap("wrap"),
    css.align_items("center"),
    css.gap(rem(0.5)),
    css.property("flex-basis", "100%"),
    css.padding_(tokens.space_2 <> " " <> tokens.space_3),
    css.color(tokens.text_muted),
    css.font_size(rem(0.875)),
  ])
}

pub fn block_start_class() -> Class {
  css.class([
    css.property("order", "-1"),
    css.property("padding-bottom", "0"),
  ])
}

pub fn block_end_class() -> Class {
  css.class([css.property("order", "1"), css.property("padding-top", "0")])
}

pub fn addon_class() -> Class {
  css.class([
    css.display("flex"),
    css.align_items("center"),
    css.gap(rem(0.25)),
    css.padding_("0 " <> tokens.space_2),
    css.color(tokens.text_muted),
    css.font_size(rem(0.875)),
    css.white_space("nowrap"),
  ])
}
