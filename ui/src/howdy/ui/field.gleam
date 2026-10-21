//// Form fields: a label, a control, and the text that explains or corrects
//// it.
////
//// ```gleam
//// field.field([], [
////   input.label([attribute.for("email")], [text("Email")]),
////   input.input([
////     attribute.id("email"),
////     attribute.type_("email"),
////     attribute.aria_invalid("true"),
////     attribute.aria_describedby("email-hint email-error"),
////   ]),
////   field.description([attribute.id("email-hint")], [text("We never share it.")]),
////   field.error([attribute.id("email-error")], [text("Enter an email address.")]),
//// ])
//// ```
////
//// The ids tie the text to the control, so a screen reader reads the hint
//// and the error along with the label. Group related fields, such as the
//// parts of an address or a set of radio buttons, in a `fieldset`.

import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// One field: its label, control, description and error, in that order.
pub fn field(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([class(field_class()), ..attributes], children)
}

/// Help text under a control. Give it an id and point the control's
/// `aria-describedby` at it.
pub fn description(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.p([class(description_class()), ..attributes], children)
}

/// What is wrong with a control's value. Give it an id, point the control's
/// `aria-describedby` at it and set `aria-invalid` on the control.
pub fn error(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.p([class(error_class()), ..attributes], children)
}

/// Related fields under a shared legend.
pub fn fieldset(
  attributes: List(Attribute(msg)),
  legend legend: List(Element(msg)),
  children children: List(Element(msg)),
) -> Element(msg) {
  html.fieldset([class(fieldset_class()), ..attributes], [
    html.legend([class(legend_class())], legend),
    ..children
  ])
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    field_class(),
    description_class(),
    error_class(),
    fieldset_class(),
    legend_class(),
  ]
}

pub fn field_class() -> Class {
  css.class([css.display("block"), css.margin_("0 0 " <> tokens.space_4)])
}

pub fn description_class() -> Class {
  css.class([
    css.margin_(tokens.space_1 <> " 0 0"),
    css.font_size(rem(0.875)),
    css.color(tokens.text_muted),
  ])
}

pub fn error_class() -> Class {
  css.class([
    css.margin_(tokens.space_1 <> " 0 0"),
    css.font_size(rem(0.875)),
    css.color(tokens.danger),
  ])
}

pub fn fieldset_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(0.75)),
    css.margin_("0 0 " <> tokens.space_4),
    css.padding(rem(0.0)),
    css.border("0"),
    css.property("min-width", "0"),
  ])
}

pub fn legend_class() -> Class {
  css.class([
    css.padding(rem(0.0)),
    css.margin_("0 0 " <> tokens.space_1),
    css.font_weight("600"),
    css.color(tokens.text),
  ])
}
