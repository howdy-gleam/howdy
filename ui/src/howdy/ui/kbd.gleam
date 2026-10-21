//// Keys: how to write a key or a shortcut, such as ⌘ K.
////
//// ```gleam
//// kbd.shortcut(["⌘", "K"])
//// kbd.kbd("Esc")
//// ```

import gleam/list
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// One key.
pub fn kbd(key: String) -> Element(msg) {
  html.kbd([class(key_class())], [text(key)])
}

/// Keys pressed together.
pub fn shortcut(keys: List(String)) -> Element(msg) {
  html.kbd([class(shortcut_class())], list.map(keys, kbd))
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [key_class(), shortcut_class()]
}

pub fn key_class() -> Class {
  css.class([
    css.display("inline-flex"),
    css.align_items("center"),
    css.justify_content("center"),
    css.property("min-width", "1.25rem"),
    css.property("height", "1.25rem"),
    css.padding_("0 0.3rem"),
    css.background(tokens.muted),
    css.color(tokens.text_muted),
    style.bordered(),
    css.property("border-bottom-width", "2px"),
    style.radius(tokens.radius_small),
    css.font_family(tokens.font_body),
    css.font_size(rem(0.75)),
    css.font_weight("500"),
    css.line_height("1"),
  ])
}

pub fn shortcut_class() -> Class {
  css.class([css.display("inline-flex"), css.gap(rem(0.25))])
}
