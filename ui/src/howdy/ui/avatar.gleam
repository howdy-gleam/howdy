//// Avatars: a small round picture of a person, with initials when there is
//// no picture or it fails to load.
////
//// ```gleam
//// avatar.avatar(src: user.photo_url, alt: "", initials: "AL")
//// avatar.initials("AL")
//// ```
////
//// Give the image an `alt` describing the person, or `""` when their name
//// is already written beside it.

import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

pub fn avatar(
  src src: String,
  alt alt: String,
  initials initials: String,
) -> Element(msg) {
  html.span([class(avatar_class())], [
    html.span([attribute.aria_hidden(True)], [text(initials)]),
    html.img([
      class(image_class()),
      attribute.src(src),
      attribute.alt(alt),
      attribute.attribute("loading", "lazy"),
      // A broken image steps aside for the initials behind it, removed by
      // `howdy/ui/behaviour`.
      attribute.data("howdy-on-error", "remove"),
    ]),
  ])
}

/// An avatar of initials alone.
pub fn initials(initials: String) -> Element(msg) {
  html.span([class(avatar_class())], [text(initials)])
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [avatar_class(), image_class()]
}

pub fn avatar_class() -> Class {
  css.class([
    css.position("relative"),
    css.display("inline-flex"),
    css.align_items("center"),
    css.justify_content("center"),
    css.flex_shrink(0.0),
    css.property("width", "2rem"),
    css.property("height", "2rem"),
    css.overflow("hidden"),
    style.pill(),
    css.background(tokens.muted),
    css.color(tokens.text_muted),
    css.font_size(rem(0.75)),
    css.font_weight("600"),
    css.property("user-select", "none"),
  ])
}

pub fn image_class() -> Class {
  css.class([
    css.position("absolute"),
    css.inset("0"),
    css.width(length.percent(100)),
    css.height(length.percent(100)),
    css.property("object-fit", "cover"),
  ])
}
