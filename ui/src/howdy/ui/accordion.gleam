//// Accordions and collapsibles: sections that open and close.
////
//// ```gleam
//// accordion.accordion([], [
////   accordion.item("faq", open: True, summary: [text("Is it accessible?")], content: [
////     text("Yes. Each section is a native details element."),
////   ]),
////   accordion.item("faq", open: False, summary: [text("Is it styled?")], content: [
////     text("Yes, from the theme."),
////   ]),
//// ])
//// ```
////
//// Each section is a `<details>` element, so it works without scripts and
//// the browser's find-in-page opens the section it matches. Items that
//// share a group name are exclusive: opening one closes the others. Give
//// each item its own name, or `""`, to let several stay open. A live view
//// hears a section open or close with `event.on("toggle", ...)`.

import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// A list of items with a line between each.
pub fn accordion(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([class(accordion_class()), ..attributes], children)
}

/// One section of an accordion.
pub fn item(
  group: String,
  open open: Bool,
  summary summary: List(Element(msg)),
  content content: List(Element(msg)),
) -> Element(msg) {
  let name = case group {
    "" -> []
    _ -> [attribute.name(group)]
  }
  html.details([class(item_class()), attribute.open(open), ..name], [
    html.summary([], summary),
    html.div([class(content_class())], content),
  ])
}

/// A single section that opens and closes, without the accordion's lines.
pub fn collapsible(
  attributes: List(Attribute(msg)),
  open open: Bool,
  summary summary: List(Element(msg)),
  content content: List(Element(msg)),
) -> Element(msg) {
  html.details(
    [class(collapsible_class()), attribute.open(open), ..attributes],
    [html.summary([], summary), html.div([], content)],
  )
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [accordion_class(), item_class(), content_class(), collapsible_class()]
}

pub fn accordion_class() -> Class {
  css.class([css.display("flex"), css.flex_direction("column")])
}

pub fn item_class() -> Class {
  css.class([style.bordered_side("bottom"), ..summary(tokens.space_4 <> " 0")])
}

pub fn content_class() -> Class {
  css.class([
    css.padding_("0 0 " <> tokens.space_4),
    css.font_size(rem(0.875)),
  ])
}

pub fn collapsible_class() -> Class {
  css.class(summary(tokens.space_2 <> " 0"))
}

/// The row that opens and closes a section, with a chevron that turns.
fn summary(padding: String) -> List(css.Style) {
  [
    css.selector(" > summary", [
      css.display("flex"),
      css.align_items("center"),
      css.justify_content("space-between"),
      css.gap(rem(1.0)),
      css.padding_(padding),
      css.font_weight("500"),
      css.cursor("pointer"),
      css.list_style("none"),
      style.radius(tokens.radius_small),
    ]),
    css.selector(" > summary::-webkit-details-marker", [css.display("none")]),
    css.selector(" > summary:hover", [css.text_decoration("underline")]),
    css.selector(" > summary:focus-visible", [
      style.focus_outline(),
      css.property("outline-offset", "2px"),
    ]),
    css.selector(" > summary::after", [
      css.content("\"\""),
      css.flex_shrink(0.0),
      css.property("width", "0.45rem"),
      css.property("height", "0.45rem"),
      css.property("border-right", "2px solid " <> tokens.text_muted),
      css.property("border-bottom", "2px solid " <> tokens.text_muted),
      css.transform_("translateY(-25%) rotate(45deg)"),
      css.transition("transform 150ms"),
    ]),
    css.selector("[open] > summary::after", [
      css.transform_("translateY(25%) rotate(-135deg)"),
    ]),
  ]
}
