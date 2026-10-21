//// Items: rows of a list, each with an optional picture, a title and
//// description, and actions.
////
//// ```gleam
//// item.group([
////   item.item(
////     media: avatar.initials("AL"),
////     title: [text("Ada Lovelace")],
////     description: [text("ada@example.com")],
////     actions: [button.button(Outline, [], [text("Invite")])],
////   ),
//// ])
//// ```
////
//// `link` makes a whole row go somewhere when clicked.

import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// A list of items, with a line between each.
pub fn group(items: List(Element(msg))) -> Element(msg) {
  html.ul([class(group_class())], items)
}

/// A row. Pass `element.none()` for no media and `[]` for no actions.
pub fn item(
  media media: Element(msg),
  title title: List(Element(msg)),
  description description: List(Element(msg)),
  actions actions: List(Element(msg)),
) -> Element(msg) {
  html.li([class(item_class())], row(media, title, description, actions))
}

/// A row that is a link.
pub fn link(
  href: String,
  media media: Element(msg),
  title title: List(Element(msg)),
  description description: List(Element(msg)),
) -> Element(msg) {
  html.li([], [
    html.a(
      [class(item_class()), class(link_class()), attribute.href(href)],
      row(media, title, description, []),
    ),
  ])
}

fn row(
  media: Element(msg),
  title: List(Element(msg)),
  description: List(Element(msg)),
  actions: List(Element(msg)),
) -> List(Element(msg)) {
  [
    media,
    html.div([class(text_class())], [
      html.div([class(title_class())], title),
      case description {
        [] -> element.none()
        _ -> html.div([class(description_class())], description)
      },
    ]),
    case actions {
      [] -> element.none()
      _ -> html.div([class(actions_class())], actions)
    },
  ]
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    group_class(),
    item_class(),
    link_class(),
    text_class(),
    title_class(),
    description_class(),
    actions_class(),
  ]
}

pub fn group_class() -> Class {
  css.class([
    css.margin(rem(0.0)),
    css.padding(rem(0.0)),
    css.list_style("none"),
    style.bordered(),
    style.radius(tokens.radius_medium),
    css.selector(" > li + li", [
      style.bordered_side("top"),
    ]),
  ])
}

pub fn item_class() -> Class {
  css.class([
    css.display("flex"),
    css.align_items("center"),
    css.gap(rem(0.75)),
    css.padding_(tokens.space_3 <> " " <> tokens.space_4),
  ])
}

pub fn link_class() -> Class {
  css.class([
    css.color(tokens.text),
    css.text_decoration("none"),
    css.hover([css.background(tokens.muted)]),
    style.focus_ring_offset("-2px"),
  ])
}

pub fn text_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(0.125)),
    css.property("flex", "1"),
    css.property("min-width", "0"),
  ])
}

pub fn title_class() -> Class {
  css.class([
    css.font_size(rem(0.9375)),
    css.font_weight("500"),
    css.color(tokens.text),
  ])
}

pub fn description_class() -> Class {
  css.class([css.font_size(rem(0.875)), css.color(tokens.text_muted)])
}

pub fn actions_class() -> Class {
  css.class([css.display("flex"), css.gap(rem(0.5)), css.flex_shrink(0.0)])
}
