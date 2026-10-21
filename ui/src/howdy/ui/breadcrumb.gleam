//// Breadcrumbs: the trail of pages above the current one.
////
//// ```gleam
//// breadcrumb.breadcrumb(words.english(), [], [
////   breadcrumb.link("/", [text("Home")]),
////   breadcrumb.ellipsis(),
////   breadcrumb.link("/orders", [text("Orders")]),
////   breadcrumb.page([text("#1042")]),
//// ])
//// ```

import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import howdy/ui/words.{type Words}
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// The trail, named for screen readers by the words' `breadcrumb`.
pub fn breadcrumb(
  words: Words,
  attributes: List(Attribute(msg)),
  items: List(Element(msg)),
) -> Element(msg) {
  html.nav([attribute.aria_label(words.breadcrumb), ..attributes], [
    html.ol([class(list_class())], items),
  ])
}

pub fn link(href: String, children: List(Element(msg))) -> Element(msg) {
  html.li([class(item_class())], [
    html.a([class(link_class()), attribute.href(href)], children),
  ])
}

/// The page being shown, last in the trail.
pub fn page(children: List(Element(msg))) -> Element(msg) {
  html.li([class(item_class())], [
    html.span([class(page_class()), attribute.aria_current("page")], children),
  ])
}

/// Pages left out of a long trail.
pub fn ellipsis() -> Element(msg) {
  html.li([class(item_class()), attribute.aria_hidden(True)], [text("…")])
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [list_class(), item_class(), link_class(), page_class()]
}

pub fn list_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_wrap("wrap"),
    css.align_items("center"),
    css.gap(rem(0.375)),
    css.margin(rem(0.0)),
    css.padding(rem(0.0)),
    css.list_style("none"),
    css.font_size(rem(0.875)),
    css.color(tokens.text_muted),
  ])
}

pub fn item_class() -> Class {
  css.class([
    css.display("inline-flex"),
    css.align_items("center"),
    css.gap(rem(0.375)),
    css.selector(":not(:first-child)::before", [
      css.content("\"›\""),
      css.color(tokens.text_muted),
    ]),
    css.selector(":dir(rtl):not(:first-child)::before", [css.content("\"‹\"")]),
  ])
}

pub fn link_class() -> Class {
  css.class([
    css.color(tokens.text_muted),
    css.text_decoration("none"),
    css.hover([css.color(tokens.text)]),
    css.focus_visible([
      style.focus_outline(),
      css.property("outline-offset", "2px"),
      style.radius(tokens.radius_small),
    ]),
  ])
}

pub fn page_class() -> Class {
  css.class([css.color(tokens.text), css.font_weight("500")])
}
