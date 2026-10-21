//// Alerts: a message that stands out from the content around it.
////
//// ```gleam
//// alert.alert(alert.Danger, [], [
////   alert.title([text("Payment failed")]),
////   alert.description([text("Your card was declined.")]),
//// ])
//// ```
////
//// An `svg` icon placed first sits to the left of the title and
//// description.
////
//// When an alert appears in response to something the user did, such as
//// a live view reporting an error, pass `attribute.role("alert")` so a
//// screen reader announces it. A message that is part of the page from the
//// start needs no role.

import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

pub type Variant {
  /// Information, in the text colour.
  Info
  /// A problem, in the danger colour.
  Danger
}

pub fn alert(
  variant: Variant,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([class(alert_class(variant)), ..attributes], children)
}

pub fn title(children: List(Element(msg))) -> Element(msg) {
  html.div([class(title_class())], children)
}

pub fn description(children: List(Element(msg))) -> Element(msg) {
  html.div([class(description_class())], children)
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [alert_class(Info), alert_class(Danger), title_class(), description_class()]
}

pub fn alert_class(variant: Variant) -> Class {
  let colour = case variant {
    Info -> tokens.text
    Danger -> tokens.danger
  }
  css.class([
    css.display("grid"),
    css.grid_template_columns("1fr"),
    css.row_gap(rem(0.125)),
    css.align_items("start"),
    css.padding_(tokens.space_3 <> " " <> tokens.space_4),
    css.background(tokens.surface),
    css.color(colour),
    style.bordered(),
    style.radius(tokens.radius_large),
    css.font_size(rem(0.875)),
    css.selector(":has(> svg)", [
      css.grid_template_columns("1rem 1fr"),
      css.column_gap(rem(0.75)),
    ]),
    css.selector(" > svg", [
      css.grid_row("span 2"),
      css.property("width", "1rem"),
      css.property("height", "1rem"),
      css.property("translate", "0 0.125rem"),
      css.color("currentColor"),
    ]),
  ])
}

pub fn title_class() -> Class {
  css.class([css.font_weight("500"), css.line_height("1.5")])
}

pub fn description_class() -> Class {
  css.class([css.color(tokens.text_muted), css.line_height("1.5")])
}
