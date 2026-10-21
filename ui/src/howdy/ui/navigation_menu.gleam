//// Navigation menus: a site's main links, some opening a panel of further
//// links.
////
//// ```gleam
//// navigation_menu.menu([attribute.aria_label("Main")], [
////   navigation_menu.link("/", active: True, children: [text("Home")]),
////   navigation_menu.panel("products", label: [text("Products")], links: [
////     navigation_menu.panel_link("/analytics", title: "Analytics", description: "See what your customers do."),
////     navigation_menu.panel_link("/billing", title: "Billing", description: "Invoices and payments."),
////   ]),
//// ])
//// ```
////
//// A panel opens from its button below the bar, and closes with Escape or
//// a click elsewhere; its links are ordinary links in the tab order.

import gleam/list
import howdy/ui/style.{anchor_name, class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

pub fn menu(
  attributes: List(Attribute(msg)),
  items: List(Element(msg)),
) -> Element(msg) {
  html.nav(attributes, [html.ul([class(list_class())], items)])
}

/// A link in the bar. `active` marks the page being shown.
pub fn link(
  href: String,
  active active: Bool,
  children children: List(Element(msg)),
) -> Element(msg) {
  let current = case active {
    True -> [attribute.aria_current("page")]
    False -> []
  }
  html.li([], [
    html.a([class(trigger_class()), attribute.href(href), ..current], children),
  ])
}

/// A button in the bar that opens a panel of links.
pub fn panel(
  id: String,
  label label: List(Element(msg)),
  links links: List(Element(msg)),
) -> Element(msg) {
  html.li([], [
    html.button(
      [
        class(trigger_class()),
        attribute.type_("button"),
        attribute.attribute("popovertarget", id),
        attribute.data("howdy-anchor", anchor_name(id)),
      ],
      list.append(label, [
        html.span([class(chevron_class()), attribute.aria_hidden(True)], []),
      ]),
    ),
    html.div(
      [
        class(panel_class()),
        attribute.id(id),
        attribute.popover("auto"),
        attribute.data("howdy-anchored", anchor_name(id)),
      ],
      [html.ul([class(panel_list_class())], links)],
    ),
  ])
}

/// A link in a panel, with a line saying where it goes.
pub fn panel_link(
  href: String,
  title title: String,
  description description: String,
) -> Element(msg) {
  html.li([], [
    html.a([class(panel_link_class()), attribute.href(href)], [
      html.span([class(panel_title_class())], [text(title)]),
      html.span([class(panel_description_class())], [text(description)]),
    ]),
  ])
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    list_class(),
    trigger_class(),
    chevron_class(),
    panel_class(),
    panel_list_class(),
    panel_link_class(),
    panel_title_class(),
    panel_description_class(),
  ]
}

pub fn list_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_wrap("wrap"),
    css.align_items("center"),
    css.gap(rem(0.25)),
    css.margin(rem(0.0)),
    css.padding(rem(0.0)),
    css.list_style("none"),
  ])
}

pub fn trigger_class() -> Class {
  css.class([
    css.display("inline-flex"),
    css.align_items("center"),
    css.gap(rem(0.375)),
    css.padding_(tokens.space_2 <> " " <> tokens.space_3),
    css.border("0"),
    style.radius(tokens.radius_medium),
    css.background("transparent"),
    css.color(tokens.text),
    css.font_family(tokens.font_body),
    css.font_size(rem(0.875)),
    css.font_weight("500"),
    css.text_decoration("none"),
    css.cursor("pointer"),
    css.hover([css.background(tokens.muted)]),
    css.selector("[aria-current=\"page\"]", [css.background(tokens.muted)]),
    style.focus_ring(),
  ])
}

pub fn chevron_class() -> Class {
  css.class([
    css.property("width", "0.4rem"),
    css.property("height", "0.4rem"),
    css.property("border-right", "2px solid " <> tokens.text_muted),
    css.property("border-bottom", "2px solid " <> tokens.text_muted),
    css.transform_("translateY(-25%) rotate(45deg)"),
  ])
}

pub fn panel_class() -> Class {
  css.class([
    css.inset("auto"),
    css.margin_("0.375rem 0"),
    css.property("position-area", "block-end span-inline-end"),
    css.property("position-try-fallbacks", "flip-inline"),
    css.property("width", "min(30rem, calc(100vw - 1rem))"),
    css.padding(rem(0.5)),
    css.background(tokens.surface),
    css.color(tokens.text),
    style.bordered(),
    style.radius(tokens.radius_medium),
    css.box_shadow("0 10px 30px -10px rgb(0 0 0 / 0.3)"),
  ])
}

pub fn panel_list_class() -> Class {
  css.class([
    css.display("grid"),
    css.grid_template_columns("repeat(auto-fill, minmax(13rem, 1fr))"),
    css.gap(rem(0.25)),
    css.margin(rem(0.0)),
    css.padding(rem(0.0)),
    css.list_style("none"),
  ])
}

pub fn panel_link_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(0.125)),
    css.padding(rem(0.75)),
    style.radius(tokens.radius_small),
    css.color(tokens.text),
    css.text_decoration("none"),
    css.hover([css.background(tokens.muted)]),
    style.focus_ring(),
  ])
}

pub fn panel_title_class() -> Class {
  css.class([css.font_size(rem(0.875)), css.font_weight("500")])
}

pub fn panel_description_class() -> Class {
  css.class([
    css.font_size(rem(0.8125)),
    css.color(tokens.text_muted),
    css.line_height("1.4"),
  ])
}
