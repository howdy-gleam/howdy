//// Resizable panels: panels side by side, or stacked, with handles that
//// can be dragged to share the space differently.
////
//// ```gleam
//// resizable.group(resizable.Horizontal, [attribute.style("height", "20rem")], [
////   resizable.panel(30, [], [folders]),
////   resizable.handle("Resize folders"),
////   resizable.panel(70, [], [messages]),
//// ])
//// ```
////
//// Sizes are shares of the group: give the panels sizes that add up to
//// 100. A handle can be dragged, or focused and moved with the arrow keys,
//// Home and End; screen readers hear the size of the panel before it.
////
//// No panel shrinks below a tenth of the group, or the share given with
//// `minimum`. A `collapsible` panel folds away, and back, when the handle
//// after it is double-clicked or focused and Enter pressed. With
//// `remember`, sizes are kept in a cookie called `resizable-<id>`: read it
//// with `sizes_from_cookie` and pass the sizes back to render the panels
//// as they were left.

import gleam/int
import gleam/list
import gleam/string
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{px}

pub type Direction {
  /// Panels side by side.
  Horizontal
  /// Panels one above the other.
  Vertical
}

pub fn group(
  direction: Direction,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  let name = case direction {
    Horizontal -> "horizontal"
    Vertical -> "vertical"
  }
  html.div(
    [
      class(group_class(direction)),
      attribute.data("howdy-resizable", name),
      ..attributes
    ],
    children,
  )
}

/// A panel taking `size` shares of the group.
pub fn panel(
  size: Int,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div(
    [
      class(panel_class()),
      attribute.style("flex-grow", int.to_string(size)),
      ..attributes
    ],
    children,
  )
}

/// The smallest share a panel can shrink to, out of 100.
pub fn minimum(share: Int) -> Attribute(msg) {
  attribute.data("min", int.to_string(share))
}

/// Let a panel fold away with the handle after it.
pub fn collapsible() -> Attribute(msg) {
  attribute.data("collapsible", "")
}

/// Keep the group's sizes in a `resizable-<id>` cookie as they change.
pub fn remember(id: String) -> Attribute(msg) {
  attribute.data("howdy-remember", id)
}

/// Read sizes kept by `remember`, such as `30_70`. Returns `default` when
/// the cookie is missing or does not have one size per panel.
pub fn sizes_from_cookie(
  value: String,
  default default: List(Int),
) -> List(Int) {
  let sizes =
    value
    |> string.split("_")
    |> list.filter_map(int.parse)
  case list.length(sizes) == list.length(default) {
    True -> sizes
    False -> default
  }
}

/// A handle between two panels. `label` names what it resizes.
pub fn handle(label: String) -> Element(msg) {
  html.div(
    [
      class(handle_class()),
      attribute.role("separator"),
      attribute.tabindex(0),
      attribute.aria_label(label),
      attribute.attribute("aria-valuemin", "10"),
      attribute.attribute("aria-valuemax", "90"),
    ],
    [],
  )
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    group_class(Horizontal),
    group_class(Vertical),
    panel_class(),
    handle_class(),
  ]
}

pub fn group_class(direction: Direction) -> Class {
  let #(flex, cursor, handle_size) = case direction {
    Horizontal -> #("row", "col-resize", [css.width(px(1))])
    Vertical -> #("column", "row-resize", [css.height(px(1))])
  }
  css.class([
    css.display("flex"),
    css.flex_direction(flex),
    css.overflow("hidden"),
    style.bordered(),
    style.radius(tokens.radius_medium),
    css.selector(" > [role=\"separator\"]", [css.cursor(cursor), ..handle_size]),
  ])
}

pub fn panel_class() -> Class {
  css.class([
    css.property("flex-basis", "0"),
    css.property("flex-shrink", "1"),
    css.property("min-width", "0"),
    css.property("min-height", "0"),
    css.overflow("auto"),
  ])
}

pub fn handle_class() -> Class {
  css.class([
    css.position("relative"),
    css.flex_shrink(0.0),
    css.background(tokens.border),
    css.property("touch-action", "none"),
    css.outline("none"),
    // A wider invisible grip than the line it draws.
    css.after([
      css.content("\"\""),
      css.position("absolute"),
      css.inset("-4px"),
    ]),
    css.hover([css.background(tokens.primary)]),
    css.focus_visible([
      css.background(tokens.focus),
      css.box_shadow("0 0 0 2px " <> tokens.focus),
    ]),
  ])
}
