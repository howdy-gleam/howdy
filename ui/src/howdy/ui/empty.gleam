//// Empty states: what to show where there is nothing yet, and what to do
//// about it.
////
//// ```gleam
//// empty.empty(
////   icon: text("📭"),
////   title: "No invoices yet",
////   description: "Invoices you send appear here.",
////   actions: [button.button(Primary, [], [text("New invoice")])],
//// )
//// ```

import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

pub fn empty(
  icon icon: Element(msg),
  title title: String,
  description description: String,
  actions actions: List(Element(msg)),
) -> Element(msg) {
  html.div([class(empty_class())], [
    html.div([class(icon_class()), attribute.aria_hidden(True)], [icon]),
    html.div([class(title_class())], [text(title)]),
    html.p([class(description_class())], [text(description)]),
    case actions {
      [] -> element.none()
      _ -> html.div([class(actions_class())], actions)
    },
  ])
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    empty_class(),
    icon_class(),
    title_class(),
    description_class(),
    actions_class(),
  ]
}

pub fn empty_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.align_items("center"),
    css.gap(rem(0.5)),
    css.padding_(tokens.space_8 <> " " <> tokens.space_6),
    css.text_align("center"),
    css.border("1px dashed " <> tokens.border),
    style.radius(tokens.radius_large),
  ])
}

pub fn icon_class() -> Class {
  css.class([
    css.display("inline-flex"),
    css.align_items("center"),
    css.justify_content("center"),
    css.property("width", "2.5rem"),
    css.property("height", "2.5rem"),
    css.margin_("0 0 " <> tokens.space_1),
    style.radius(tokens.radius_medium),
    css.background(tokens.muted),
    css.color(tokens.text_muted),
    css.font_size(rem(1.25)),
  ])
}

pub fn title_class() -> Class {
  css.class([css.font_weight("600"), css.color(tokens.text)])
}

pub fn description_class() -> Class {
  css.class([
    css.margin(rem(0.0)),
    css.property("max-width", "24rem"),
    css.font_size(rem(0.875)),
    css.color(tokens.text_muted),
  ])
}

pub fn actions_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_wrap("wrap"),
    css.justify_content("center"),
    css.gap(rem(0.5)),
    css.margin_(tokens.space_2 <> " 0 0"),
  ])
}
