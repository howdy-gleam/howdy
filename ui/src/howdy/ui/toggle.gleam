//// Toggles: buttons that stay pressed, alone or in a group.
////
//// ```gleam
//// toggle.toggle(False, [attribute.aria_label("Bold")], [text("B")])
////
//// toggle.group(toggle.Single, [attribute.aria_label("Alignment")], [
////   toggle.toggle(True, [attribute.aria_label("Left")], [text("⇤")]),
////   toggle.toggle(False, [attribute.aria_label("Centre")], [text("↔")]),
//// ])
//// ```
////
//// Clicking a toggle flips its `aria-pressed` in the browser. In a `Single`
//// group, pressing one releases the others; in a `Multiple` group each is
//// independent. A live view that keeps the state should update its model
//// from each toggle's click, so the server's idea never falls behind.

import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// How many toggles in a group may be pressed at once.
pub type Selection {
  Single
  Multiple
}

pub fn toggle(
  pressed: Bool,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.button(
    [
      class(toggle_class()),
      attribute.type_("button"),
      attribute.data("howdy-toggle", ""),
      attribute.aria_pressed(case pressed {
        True -> "true"
        False -> "false"
      }),
      ..attributes
    ],
    children,
  )
}

/// Toggles joined into one control. Label it with `aria-label`; pass
/// `attribute.aria_orientation("vertical")` to stack them, which also makes
/// up and down the keys that move between them. The group is one stop in
/// the tab order, and the arrow keys move within it.
pub fn group(
  selection: Selection,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  let selection = case selection {
    Single -> "single"
    Multiple -> "multiple"
  }
  html.div(
    [
      class(group_class()),
      attribute.role("group"),
      attribute.data("howdy-toggle-group", selection),
      ..attributes
    ],
    children,
  )
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [toggle_class(), group_class()]
}

pub fn toggle_class() -> Class {
  css.class([
    css.display("inline-flex"),
    css.align_items("center"),
    css.justify_content("center"),
    css.gap(rem(0.375)),
    css.property("min-width", "2.25rem"),
    css.property("height", "2.25rem"),
    css.padding_("0 " <> tokens.space_2),
    css.border("1px solid transparent"),
    style.radius(tokens.radius_medium),
    css.background("transparent"),
    css.color(tokens.text),
    css.font_family(tokens.font_body),
    css.font_size(rem(0.875)),
    css.font_weight("500"),
    css.cursor("pointer"),
    css.hover([css.background(tokens.muted)]),
    css.selector("[aria-pressed=\"true\"]", [
      css.background(tokens.muted),
      css.property("border-color", tokens.border),
    ]),
    style.focus_ring(),
    style.disabled_look_with(cursor: "default"),
  ])
}

pub fn group_class() -> Class {
  css.class([
    css.display("inline-flex"),
    css.selector("[aria-orientation=\"vertical\"]", [
      css.flex_direction("column"),
    ]),
    css.gap(rem(0.125)),
    css.padding(rem(0.125)),
    style.bordered(),
    style.radius(tokens.radius_medium),
  ])
}
