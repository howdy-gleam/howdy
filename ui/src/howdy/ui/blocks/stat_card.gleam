//// A stat card: a headline number, what it measures, and how it changed.
////
//// ```gleam
//// stat_card.stat_card(label: "Revenue", value: "$48,210", change: "+12% on last month")
//// ```

import howdy/ui/card
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

pub fn stat_card(
  label label: String,
  value value: String,
  change change: String,
) -> Element(msg) {
  card.card([], [
    html.div([class(label_class())], [text(label)]),
    html.div([class(value_class())], [text(value)]),
    html.div([class(change_class())], [text(change)]),
  ])
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [label_class(), value_class(), change_class()]
}

pub fn label_class() -> Class {
  css.class([css.font_size(rem(0.875)), css.color(tokens.text_muted)])
}

pub fn value_class() -> Class {
  css.class([
    css.margin_(tokens.space_1 <> " 0"),
    css.font_size(rem(2.0)),
    css.font_weight("600"),
    css.line_height("1.2"),
    css.color(tokens.text),
  ])
}

pub fn change_class() -> Class {
  css.class([css.font_size(rem(0.875)), css.color(tokens.text_muted)])
}
