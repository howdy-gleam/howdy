//// Badges: short labels such as a status or a count.

import gleam/list
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

pub type Variant {
  /// Filled with the primary colour.
  Primary
  /// Filled with the muted colour.
  Secondary
  /// Outlined.
  Outline
  /// Filled with the danger colour.
  Danger
}

pub fn badge(
  variant: Variant,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.span([class(badge_class(variant)), ..attributes], children)
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [Primary, Secondary, Outline, Danger] |> list.map(badge_class)
}

pub fn badge_class(variant: Variant) -> Class {
  let colours = case variant {
    Primary -> [css.background(tokens.primary), css.color(tokens.on_primary)]
    Secondary -> [css.background(tokens.muted), css.color(tokens.text)]
    Outline -> [
      css.background("transparent"),
      css.color(tokens.text),
      css.property("border-color", tokens.border),
    ]
    Danger -> [css.background(tokens.danger), css.color(tokens.on_danger)]
  }
  css.class([
    css.display("inline-flex"),
    css.align_items("center"),
    css.gap(rem(0.25)),
    css.padding_("0.125rem " <> tokens.space_2),
    css.border("1px solid transparent"),
    style.pill(),
    css.font_size(rem(0.75)),
    css.font_weight("500"),
    css.line_height("1.25"),
    css.white_space("nowrap"),
    css.vertical_align("middle"),
    ..colours
  ])
}
