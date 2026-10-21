//// Tables for rows of data.
////
//// ```gleam
//// table.table([], [
////   table.caption([], [text("Recent invoices")]),
////   table.header([], [
////     table.row([], [table.head([], [text("Invoice")]), table.head([], [text("Amount")])]),
////   ]),
////   table.body([], list.map(invoices, fn(invoice) {
////     table.row([], [table.cell([], [text(invoice.id)]), table.cell([], [text(invoice.amount)])])
////   })),
//// ])
//// ```
////
//// A table wider than its container scrolls sideways instead of
//// overflowing the page.

import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{percent, rem}

/// The table, in a container that scrolls sideways when it is too wide.
/// Attributes go on the `<table>`.
pub fn table(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([class(scroll_class())], [
    html.table([class(table_class()), ..attributes], children),
  ])
}

pub fn caption(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.caption([class(caption_class()), ..attributes], children)
}

/// The `<thead>`.
pub fn header(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.thead(attributes, children)
}

/// The `<tbody>`.
pub fn body(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.tbody(attributes, children)
}

/// The `<tfoot>`, for totals.
pub fn footer(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.tfoot([class(footer_class()), ..attributes], children)
}

/// A row. Set `aria-selected` to highlight it.
pub fn row(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.tr([class(row_class()), ..attributes], children)
}

/// A header cell.
pub fn head(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.th([class(head_class()), ..attributes], children)
}

pub fn cell(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.td([class(cell_class()), ..attributes], children)
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    scroll_class(),
    table_class(),
    caption_class(),
    footer_class(),
    row_class(),
    head_class(),
    cell_class(),
  ]
}

pub fn scroll_class() -> Class {
  css.class([css.width(percent(100)), css.overflow_x("auto")])
}

pub fn table_class() -> Class {
  css.class([
    css.width(percent(100)),
    css.border_collapse("collapse"),
    css.font_size(rem(0.875)),
    css.color(tokens.text),
  ])
}

pub fn caption_class() -> Class {
  css.class([
    css.property("caption-side", "bottom"),
    css.margin_(tokens.space_4 <> " 0 0"),
    css.color(tokens.text_muted),
  ])
}

pub fn footer_class() -> Class {
  css.class([css.background(tokens.muted), css.font_weight("500")])
}

pub fn row_class() -> Class {
  css.class([
    style.bordered_side("bottom"),
    css.transition("background 120ms"),
    css.hover([css.background(tokens.muted)]),
    css.selector("[aria-selected=\"true\"]", [css.background(tokens.muted)]),
  ])
}

pub fn head_class() -> Class {
  css.class([
    css.padding_(tokens.space_2 <> " " <> tokens.space_3),
    css.text_align("start"),
    css.vertical_align("middle"),
    css.font_weight("500"),
    css.white_space("nowrap"),
    css.color(tokens.text),
  ])
}

pub fn cell_class() -> Class {
  css.class([
    css.padding_(tokens.space_2 <> " " <> tokens.space_3),
    css.vertical_align("middle"),
  ])
}
