//// Skeletons and spinners, for content that is on its way.
////
//// Both animate, gently, and slow down or stop for people who ask their
//// system for reduced motion.

import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// A placeholder in the shape of content that has not arrived. Size it
/// with a style or a class of your own:
///
/// ```gleam
/// loading.skeleton([attribute.style("height", "1rem"), attribute.style("width", "12rem")])
/// ```
pub fn skeleton(attributes: List(Attribute(msg))) -> Element(msg) {
  animations()
  html.div(
    [
      class(skeleton_class()),
      attribute.data("howdy-skeleton", ""),
      attribute.aria_hidden(True),
      ..attributes
    ],
    [],
  )
}

/// A spinning circle in the current text colour, sized to the text.
/// Screen readers announce `label`, such as "Loading" or "Saving".
pub fn spinner(
  label: String,
  attributes: List(Attribute(msg)),
) -> Element(msg) {
  animations()
  html.span(
    [
      class(spinner_class()),
      attribute.data("howdy-spinner", ""),
      attribute.role("status"),
      attribute.aria_label(label),
      ..attributes
    ],
    [
      html.svg(
        [
          attribute.attribute("viewBox", "0 0 24 24"),
          attribute.attribute("fill", "none"),
          attribute.attribute("stroke", "currentColor"),
          attribute.attribute("stroke-width", "2.5"),
          attribute.attribute("stroke-linecap", "round"),
          attribute.attribute("width", "100%"),
          attribute.attribute("height", "100%"),
        ],
        [svg.path([attribute.attribute("d", "M21 12a9 9 0 1 1-6.22-8.56")])],
      ),
    ],
  )
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [skeleton_class(), spinner_class()]
}

/// The CSS this module registers with `style.rule`, for `howdy/ui/export`.
pub fn rules() -> List(#(String, String)) {
  [#(animation_rule, animation_css)]
}

pub fn skeleton_class() -> Class {
  css.class([
    css.display("block"),
    css.property("min-height", "1rem"),
    css.background(tokens.muted),
    style.radius(tokens.radius_medium),
  ])
}

pub fn spinner_class() -> Class {
  css.class([
    css.display("inline-block"),
    css.property("width", "1em"),
    css.property("height", "1em"),
    css.flex_shrink(0.0),
    css.vertical_align("-0.125em"),
    css.font_size(rem(1.0)),
  ])
}

// Sketch classes cannot carry `@keyframes`, so the animations are
// registered as a rule when an element that uses them is drawn. The rule
// is emitted once per document, in a live view's shadow root when its view
// uses it, and in a published stylesheet through `rules`.
fn animations() -> Nil {
  style.rule(animation_rule, animation_css)
}

const animation_rule = "howdy-loading"

const animation_css = "@keyframes howdy-spin{to{transform:rotate(360deg)}}@keyframes howdy-pulse{50%{opacity:.5}}[data-howdy-spinner]>svg{animation:howdy-spin .8s linear infinite}[data-howdy-skeleton]{animation:howdy-pulse 2s ease-in-out infinite}@media (prefers-reduced-motion:reduce){[data-howdy-spinner]>svg{animation-duration:2.4s}[data-howdy-skeleton]{animation:none}}"
