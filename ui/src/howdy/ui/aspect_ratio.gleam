//// Aspect ratios: a box that keeps its shape as it grows and shrinks, for
//// images, video and maps.
////
//// ```gleam
//// aspect_ratio.aspect_ratio(16, 9, [], [html.img([attribute.src("/cover.jpg"), attribute.alt("")])])
//// ```
////
//// An image or video inside fills the box, cropped to fit.

import gleam/int
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{percent}

/// A box `width` by `height` in proportion.
pub fn aspect_ratio(
  width: Int,
  height: Int,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div(
    [
      class(ratio_class()),
      attribute.style(
        "aspect-ratio",
        int.to_string(width) <> " / " <> int.to_string(int.max(height, 1)),
      ),
      ..attributes
    ],
    children,
  )
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [ratio_class()]
}

pub fn ratio_class() -> Class {
  css.class([
    css.position("relative"),
    css.width(percent(100)),
    css.overflow("hidden"),
    style.radius(tokens.radius_medium),
    css.background(tokens.muted),
    css.selector(" > img", fill()),
    css.selector(" > video", fill()),
    css.selector(" > iframe", fill()),
  ])
}

fn fill() -> List(css.Style) {
  [
    css.position("absolute"),
    css.inset("0"),
    css.width(percent(100)),
    css.height(percent(100)),
    css.property("object-fit", "cover"),
    css.border("0"),
  ]
}
