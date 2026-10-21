//// Hover cards: a preview that appears beside a link while the pointer
//// rests on it or it has focus, such as a profile behind a name.
////
//// ```gleam
//// html.a([attribute.href("/people/ada"), ..hover_card.trigger("ada-card")], [text("@ada")]),
//// hover_card.card("ada-card", [], [profile_summary]),
//// ```
////
//// A hover card adds to its link without replacing it: the link still
//// goes where it says, so nothing depends on the card, which touch screens
//// never show. It opens after half a second and stays open while the
//// pointer is over it, so it can hold links of its own. Escape hides it.

import howdy/ui/style.{anchor_name, class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// Attributes for the link the card with this id previews.
pub fn trigger(id: String) -> List(Attribute(msg)) {
  [
    attribute.data("howdy-hover-card", id),
    attribute.data("howdy-anchor", anchor_name(id)),
  ]
}

pub fn card(
  id: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div(
    [
      class(card_class()),
      attribute.id(id),
      attribute.popover("manual"),
      attribute.data("howdy-anchored", anchor_name(id)),
      ..attributes
    ],
    children,
  )
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [card_class()]
}

pub fn card_class() -> Class {
  css.class([
    css.inset("auto"),
    css.margin_("0.375rem 0"),
    css.property("position-area", "block-end span-inline-end"),
    css.property("position-try-fallbacks", "flip-block, flip-inline"),
    css.property("width", "min(20rem, calc(100vw - 1rem))"),
    css.padding(rem(1.0)),
    css.background(tokens.surface),
    css.color(tokens.text),
    style.bordered(),
    style.radius(tokens.radius_medium),
    css.box_shadow("0 10px 30px -10px rgb(0 0 0 / 0.3)"),
  ])
}
