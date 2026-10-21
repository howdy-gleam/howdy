//// Checkboxes and radio buttons.
////
//// Both are the browser's own controls in the theme's primary colour, so
//// keyboard use, form submission and `indeterminate` work as usual. Wrap
//// one in `choice` to give it a label you can click:
////
//// ```gleam
//// checkbox.choice(checkbox.checkbox([attribute.name("terms")]), [
////   text("I accept the terms"),
//// ])
////
//// checkbox.radio_group([attribute.aria_label("Plan")], [
////   checkbox.choice(checkbox.radio([attribute.name("plan"), attribute.value("free")]), [text("Free")]),
////   checkbox.choice(checkbox.radio([attribute.name("plan"), attribute.value("pro")]), [text("Pro")]),
//// ])
//// ```
////
//// Radio buttons with the same `name` form one group: the arrow keys move
//// between them.

import gleam/json
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

pub fn checkbox(attributes: List(Attribute(msg))) -> Element(msg) {
  html.input([class(control_class()), attribute.type_("checkbox"), ..attributes])
}

/// Show a checkbox as partly checked, such as "select all" when some rows
/// are selected. The browser draws it; checking it clears the state.
pub fn indeterminate() -> Attribute(msg) {
  // A property, which a live view sets directly; the attribute lets the
  // behaviour script set it on a page rendered once.
  attribute.property("indeterminate", json.bool(True))
}

/// The same, for a page rendered once: `howdy/ui/behaviour` sets the
/// property when the page loads.
pub fn indeterminate_on_load() -> Attribute(msg) {
  attribute.data("howdy-indeterminate", "")
}

pub fn radio(attributes: List(Attribute(msg))) -> Element(msg) {
  html.input([class(control_class()), attribute.type_("radio"), ..attributes])
}

/// A control with its label beside it. Clicking the label toggles the
/// control.
pub fn choice(
  control: Element(msg),
  children: List(Element(msg)),
) -> Element(msg) {
  html.label([class(choice_class())], [control, html.span([], children)])
}

/// Radio buttons, one per line. Label the group with `aria-label`, or put
/// it in a `howdy/ui/field.fieldset`.
pub fn radio_group(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div(
    [class(radio_group_class()), attribute.role("radiogroup"), ..attributes],
    children,
  )
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [control_class(), choice_class(), radio_group_class()]
}

pub fn control_class() -> Class {
  css.class([
    css.property("width", "1rem"),
    css.property("height", "1rem"),
    css.margin(rem(0.0)),
    css.flex_shrink(0.0),
    css.property("accent-color", tokens.primary),
    css.cursor("pointer"),
    style.focus_ring(),
    style.disabled_look(),
  ])
}

pub fn choice_class() -> Class {
  css.class([
    css.display("flex"),
    css.align_items("center"),
    css.gap(rem(0.5)),
    css.font_size(rem(0.875)),
    css.color(tokens.text),
    css.cursor("pointer"),
    css.selector(":has(:disabled)", [
      css.property("opacity", "0.5"),
      css.cursor("not-allowed"),
    ]),
  ])
}

pub fn radio_group_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(0.75)),
  ])
}
