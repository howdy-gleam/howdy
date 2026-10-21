//// Cards: a raised surface, with optional parts for a header, content and
//// footer.
////
//// ```gleam
//// card.card([], [
////   card.header([], [
////     card.title([text("Invoices")]),
////     card.description([text("Paid in the last 30 days.")]),
////     card.action([], [button.button(Ghost, [], [text("Export")])]),
////   ]),
////   card.content([], [table]),
////   card.footer([], [button.button(Primary, [], [text("New invoice")])]),
//// ])
//// ```
////
//// The parts are optional: a card can hold any children.

import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// How much room a card leaves around and between its parts.
pub type Size {
  Default
  /// Tighter padding and spacing, for dense layouts and lists of cards.
  Compact
}

/// A raised surface with a border and padding.
pub fn card(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  sized(Default, attributes, children)
}

/// A card of the given size. Its header and footer space themselves to
/// match.
pub fn sized(
  size: Size,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  let size_class = case size {
    Default -> card_class()
    Compact -> compact_class()
  }
  html.div([class(size_class), ..attributes], children)
}

/// The top of a card: a title, a description and an action beside them.
pub fn header(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([class(header_class()), ..attributes], children)
}

/// The card's title. Pass `html.h2` or similar inside it when it should be a
/// heading in the document outline.
pub fn title(children: List(Element(msg))) -> Element(msg) {
  html.div([class(title_class())], children)
}

pub fn description(children: List(Element(msg))) -> Element(msg) {
  html.p([class(description_class())], children)
}

/// Placed at the top right of the header, beside the title and description.
pub fn action(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([class(action_class()), ..attributes], children)
}

pub fn content(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div(attributes, children)
}

/// A row of actions at the bottom of the card.
pub fn footer(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([class(footer_class()), ..attributes], children)
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    card_class(),
    compact_class(),
    header_class(),
    title_class(),
    description_class(),
    action_class(),
    footer_class(),
  ]
}

pub fn card_class() -> Class {
  css.class([
    css.background(tokens.surface),
    style.bordered(),
    style.radius(tokens.radius_large),
    css.padding(rem(1.5)),
    css.property("--howdy-card-gap", tokens.space_4),
  ])
}

pub fn compact_class() -> Class {
  css.class([
    css.background(tokens.surface),
    style.bordered(),
    style.radius(tokens.radius_medium),
    css.padding(rem(1.0)),
    css.property("--howdy-card-gap", tokens.space_3),
  ])
}

pub fn header_class() -> Class {
  css.class([
    css.display("grid"),
    css.grid_template_columns("1fr auto"),
    css.property("grid-auto-rows", "min-content"),
    css.row_gap(rem(0.25)),
    css.column_gap(rem(1.0)),
    css.margin_("0 0 var(--howdy-card-gap, " <> tokens.space_4 <> ")"),
  ])
}

pub fn title_class() -> Class {
  css.class([
    css.grid_column("1"),
    css.font_family(tokens.font_heading),
    css.font_size(rem(1.125)),
    css.font_weight("600"),
    css.line_height("1.25"),
    css.color(tokens.text),
  ])
}

pub fn description_class() -> Class {
  css.class([
    css.grid_column("1"),
    css.margin(rem(0.0)),
    css.font_size(rem(0.875)),
    css.color(tokens.text_muted),
  ])
}

pub fn action_class() -> Class {
  css.class([
    css.grid_column("2"),
    css.grid_row("1 / span 2"),
    css.align_self("start"),
    css.justify_self("end"),
  ])
}

pub fn footer_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_wrap("wrap"),
    css.align_items("center"),
    css.gap(rem(0.75)),
    css.margin_("var(--howdy-card-gap, " <> tokens.space_4 <> ") 0 0"),
  ])
}
