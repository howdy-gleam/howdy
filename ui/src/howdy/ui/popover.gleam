//// Popovers: a panel anchored to the button that opens it.
////
//// ```gleam
//// ui.button(Outline, popover.trigger("filters"), [text("Filters")]),
//// popover.popover("filters", [], [filter_form]),
//// ```
////
//// A popover opens below its trigger, or above when there is no room. The
//// browser closes it on Escape or a click outside, and it sits above
//// everything else on the page. The trigger and the popover are tied by
//// id, so both must be in the page or both in one live view. A live view
//// hears one open or close with `event.on("toggle", ...)`.

import howdy/ui/style.{anchor_name, class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// Attributes for the button that opens and closes the popover with this
/// id.
pub fn trigger(id: String) -> List(Attribute(msg)) {
  [
    attribute.attribute("popovertarget", id),
    attribute.data("howdy-anchor", anchor_name(id)),
  ]
}

/// Attributes for a button inside the popover that closes it.
pub fn close(id: String) -> List(Attribute(msg)) {
  [
    attribute.attribute("popovertarget", id),
    attribute.attribute("popovertargetaction", "hide"),
  ]
}

pub fn popover(
  id: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div(
    [
      class(popover_class()),
      attribute.id(id),
      attribute.popover("auto"),
      attribute.data("howdy-anchored", anchor_name(id)),
      ..attributes
    ],
    children,
  )
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [popover_class()]
}

pub fn popover_class() -> Class {
  css.class([
    css.inset("auto"),
    css.margin_("0.375rem 0"),
    css.property("position-area", "block-end span-inline-end"),
    css.property("position-try-fallbacks", "flip-block, flip-inline"),
    css.property("max-width", "calc(100vw - 1rem)"),
    css.padding(rem(1.0)),
    css.background(tokens.surface),
    css.color(tokens.text),
    style.bordered(),
    style.radius(tokens.radius_medium),
    css.box_shadow("0 10px 30px -10px rgb(0 0 0 / 0.3)"),
  ])
}
