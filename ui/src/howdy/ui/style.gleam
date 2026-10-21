//// Attach Sketch classes to elements, and the styles the components share:
//// the focus ring, the hairline border, corner radii and the look of a
//// disabled control. Use them to style your own markup to match.

import gleam/list
import gleam/string
import howdy/ui/internal/stylesheet
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class, type Style}

/// Register a Sketch class and use it on an element. The CSS is included
/// by `howdy/ui/page` and `howdy/ui/live`, or by `styles`.
pub fn class(class: Class) -> Attribute(msg) {
  attribute.class(stylesheet.class_name(class))
}

/// Register CSS a Sketch class cannot carry, such as `@keyframes` and the
/// rules that apply them, under a stable name. Call it while rendering the
/// element that needs it: the block is included once per document by
/// `howdy/ui/page`, `howdy/ui/live` and `styles`, however many elements
/// register it. A published stylesheet includes the built-in rules; add
/// your own with `export.rules`.
pub fn rule(name: String, css: String) -> Nil {
  stylesheet.rule(name, css)
}

/// A `<style>` element holding the CSS for every class used so far. Build
/// it after the elements it styles. Pages and live views include this for
/// you.
pub fn styles() -> Element(msg) {
  html.style([], stylesheet.css())
}

/// A CSS anchor name derived from an element id, for tying a floating
/// element such as a popover to the element that opens it. Characters that
/// cannot appear in a CSS identifier become `_`. Put it in `data-howdy-anchor`
/// on the opener and `data-howdy-anchored` on the floating element:
/// `howdy/ui/behaviour` applies the names when the element opens, since a
/// strict Content Security Policy forbids inline styles.
pub fn anchor_name(id: String) -> String {
  "--howdy-anchor-"
  <> {
    id
    |> string.to_graphemes
    |> list.map(fn(char) {
      case string.contains(identifier_chars, char) {
        True -> char
        False -> "_"
      }
    })
    |> string.concat
  }
}

const identifier_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"

// -- Shared styles -----------------------------------------------------------

/// The focus ring, shown when a control is focused from the keyboard:
/// `focus_outline` offset by 2px.
pub fn focus_ring() -> Style {
  focus_ring_offset("2px")
}

/// The focus ring with an outline offset of your own, such as `"-2px"` to
/// draw it inside an element that fills its container.
pub fn focus_ring_offset(offset: String) -> Style {
  css.focus_visible([focus_outline(), css.property("outline-offset", offset)])
}

/// The outline of the focus ring alone, for showing it under a selector of
/// your own, such as `:focus-within`.
pub fn focus_outline() -> Style {
  css.outline("2px solid " <> tokens.focus)
}

/// A hairline border on every side, in the theme's border colour.
pub fn bordered() -> Style {
  css.border(border_line())
}

/// A hairline border on one side: `"top"`, `"bottom"`, `"inline-start"` or
/// `"inline-end"`.
pub fn bordered_side(side: String) -> Style {
  css.property("border-" <> side, border_line())
}

/// The hairline border as a `border` value, for shorthands of your own.
pub fn border_line() -> String {
  "1px solid " <> tokens.border
}

/// Rounded corners, usually one of the theme's radius tokens.
pub fn radius(value: String) -> Style {
  css.property("border-radius", value)
}

/// Fully rounded ends, for badges and other pills.
pub fn pill() -> Style {
  radius("999px")
}

/// A disabled control: faded, with a `not-allowed` cursor.
pub fn disabled_look() -> Style {
  disabled_look_with(cursor: "not-allowed")
}

/// A disabled control, faded, with a cursor of your own, such as `"default"`
/// for a control that is not a form field.
pub fn disabled_look_with(cursor cursor: String) -> Style {
  css.disabled([css.property("opacity", "0.5"), css.cursor(cursor)])
}
