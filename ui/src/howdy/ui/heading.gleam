//// Headings.

import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}

pub fn h1(content: String) -> Element(msg) {
  html.h1([class(heading_class("2rem"))], [text(content)])
}

pub fn h2(content: String) -> Element(msg) {
  html.h2([class(heading_class("1.5rem"))], [text(content)])
}

pub fn h3(content: String) -> Element(msg) {
  html.h3([class(heading_class("1.25rem"))], [text(content)])
}

pub fn h4(content: String) -> Element(msg) {
  html.h4([class(heading_class("1.125rem"))], [text(content)])
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    heading_class("2rem"),
    heading_class("1.5rem"),
    heading_class("1.25rem"),
    heading_class("1.125rem"),
  ]
}

pub fn heading_class(size: String) -> Class {
  css.class([
    css.property("font-size", size),
    css.font_weight("600"),
    css.margin_("0 0 " <> tokens.space_2),
    css.color(tokens.text),
  ])
}
