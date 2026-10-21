//// Scroll areas: a region that scrolls on its own, with thin scrollbars in
//// the theme's colours.
////
//// ```gleam
//// scroll_area.scroll_area("Release notes", [attribute.style("height", "12rem")], notes)
//// ```
////
//// The region can be focused and scrolled with the keyboard, and is named
//// for screen readers by `label`.

import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}

pub fn scroll_area(
  label: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div(
    [
      class(area_class()),
      attribute.role("region"),
      attribute.aria_label(label),
      attribute.tabindex(0),
      ..attributes
    ],
    children,
  )
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [area_class()]
}

pub fn area_class() -> Class {
  css.class([
    css.overflow("auto"),
    css.property("overscroll-behavior", "contain"),
    css.property("scrollbar-width", "thin"),
    css.property("scrollbar-color", tokens.border <> " transparent"),
    style.radius(tokens.radius_medium),
    style.focus_ring(),
  ])
}
