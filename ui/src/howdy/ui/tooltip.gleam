//// Tooltips: a short hint shown above an element while it is hovered or
//// focused.
////
//// ```gleam
//// ui.sized_button(
////   Ghost,
////   Icon,
////   [attribute.aria_label("Archive"), ..tooltip.trigger("archive-tip")],
////   [archive_icon],
//// ),
//// tooltip.tooltip("archive-tip", [text("Archive this thread")]),
//// ```
////
//// The hint describes the trigger to screen readers too. It is hidden with
//// Escape and stays open while the pointer is over it. Keep it to a few
//// words, since touch screens never show it; do not put anything that has
//// to be clicked inside. The trigger and the tooltip are tied by id, so
//// both must be in the page or both in one live view.

import howdy/ui/style.{anchor_name, class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// Attributes for the element the tooltip with this id describes. It must
/// be focusable, such as a button or a link.
pub fn trigger(id: String) -> List(Attribute(msg)) {
  [
    attribute.data("howdy-tooltip", id),
    attribute.aria_describedby(id),
    attribute.data("howdy-anchor", anchor_name(id)),
  ]
}

pub fn tooltip(id: String, children: List(Element(msg))) -> Element(msg) {
  html.div(
    [
      class(tooltip_class()),
      attribute.id(id),
      attribute.popover("manual"),
      attribute.role("tooltip"),
      attribute.data("howdy-side", "top"),
      attribute.data("howdy-anchored", anchor_name(id)),
    ],
    children,
  )
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [tooltip_class()]
}

pub fn tooltip_class() -> Class {
  css.class([
    css.inset("auto"),
    css.margin_("0.375rem 0"),
    css.property("position-area", "block-start"),
    css.property("position-try-fallbacks", "flip-block"),
    css.property("max-width", "min(20rem, calc(100vw - 1rem))"),
    css.padding_(tokens.space_1 <> " " <> tokens.space_2),
    css.background(tokens.text),
    css.color(tokens.background),
    css.border("0"),
    style.radius(tokens.radius_small),
    css.font_size(rem(0.75)),
    css.line_height("1.4"),
  ])
}
