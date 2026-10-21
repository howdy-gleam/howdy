//// Text inputs, text areas, selects and labels.
////
//// Controls follow their native state: `attribute.disabled(True)` dims
//// them, and `attribute.aria_invalid("true")` gives them the danger colour.
//// Pair an invalid control with a `howdy/ui/field` error through
//// `aria-describedby`.

import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{percent, rem}

pub fn input(attributes: List(Attribute(msg))) -> Element(msg) {
  html.input([class(input_class()), ..attributes])
}

/// A multiline text input. `attribute.rows` sets its initial height; the
/// user can make it taller.
pub fn textarea(
  attributes: List(Attribute(msg)),
  content: String,
) -> Element(msg) {
  html.textarea([class(textarea_class()), ..attributes], content)
}

/// The browser's own select, styled to match the other controls. On
/// phones it opens the system picker. For a list styled like the rest of
/// the page, see `howdy/ui/select`. Children
/// are `html.option` and `html.optgroup` elements. Attributes go on the
/// `<select>`.
pub fn native_select(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([class(select_wrapper_class())], [
    html.select([class(select_class()), ..attributes], children),
  ])
}

pub fn label(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.label([class(label_class()), ..attributes], children)
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    input_class(),
    textarea_class(),
    select_wrapper_class(),
    select_class(),
    label_class(),
  ]
}

pub fn input_class() -> Class {
  css.class(control())
}

pub fn textarea_class() -> Class {
  css.class([
    css.property("min-height", "5rem"),
    css.property("resize", "vertical"),
    css.line_height("1.5"),
    ..control()
  ])
}

pub fn select_wrapper_class() -> Class {
  css.class([
    css.position("relative"),
    // A chevron drawn with borders, so it takes the theme's colour.
    css.after([
      css.content("\"\""),
      css.position("absolute"),
      css.property("inset-inline-end", tokens.space_3),
      css.property("top", "50%"),
      css.property("width", "0.45rem"),
      css.property("height", "0.45rem"),
      css.property("border-right", "2px solid " <> tokens.text_muted),
      css.property("border-bottom", "2px solid " <> tokens.text_muted),
      css.transform_("translateY(-70%) rotate(45deg)"),
      css.property("pointer-events", "none"),
    ]),
  ])
}

pub fn select_class() -> Class {
  css.class([
    css.property("appearance", "none"),
    css.property("padding-inline-end", "2.25rem"),
    css.cursor("pointer"),
    ..control()
  ])
}

pub fn label_class() -> Class {
  css.class([
    css.display("block"),
    css.margin_("0 0 " <> tokens.space_1),
    css.font_size(rem(0.875)),
    css.font_weight("500"),
    css.color(tokens.text),
  ])
}

/// What every text control shares.
fn control() -> List(css.Style) {
  [
    css.display("block"),
    css.width(percent(100)),
    css.padding_(tokens.space_2 <> " " <> tokens.space_3),
    css.background(tokens.surface),
    css.color(tokens.text),
    style.bordered(),
    style.radius(tokens.radius_medium),
    css.font_family(tokens.font_body),
    css.font_size(rem(1.0)),
    css.placeholder([css.color(tokens.text_muted)]),
    style.focus_ring(),
    style.disabled_look(),
    css.selector("[aria-invalid=\"true\"]", [
      css.property("border-color", tokens.danger),
      css.focus_visible([css.property("outline-color", tokens.danger)]),
    ]),
  ]
}
