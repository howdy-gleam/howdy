//// Switches: an on-off setting that takes effect straight away.
////
//// ```gleam
//// checkbox.choice(switch.switch([attribute.name("alerts"), attribute.checked(True)]), [
////   text("Email alerts"),
//// ])
//// ```
////
//// A switch is the browser's own checkbox with the `switch` role, drawn as a
//// track and a thumb, so Space toggles it and it submits with a form like
//// any checkbox. Label it with `howdy/ui/checkbox.choice` or a `<label>`.

import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

pub fn switch(attributes: List(Attribute(msg))) -> Element(msg) {
  html.input([
    class(switch_class()),
    attribute.type_("checkbox"),
    attribute.role("switch"),
    ..attributes
  ])
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [switch_class()]
}

pub fn switch_class() -> Class {
  css.class([
    css.property("appearance", "none"),
    css.position("relative"),
    css.flex_shrink(0.0),
    css.property("width", "2.25rem"),
    css.property("height", "1.25rem"),
    css.margin(rem(0.0)),
    style.pill(),
    css.background(tokens.border),
    css.cursor("pointer"),
    css.transition("background 150ms"),
    css.before([
      css.content("\"\""),
      css.position("absolute"),
      css.property("top", "0.125rem"),
      css.property("inset-inline-start", "0.125rem"),
      css.property("width", "1rem"),
      css.property("height", "1rem"),
      style.pill(),
      css.background(tokens.surface),
      css.box_shadow("0 1px 2px rgb(0 0 0 / 0.25)"),
      css.transition("inset-inline-start 150ms"),
    ]),
    css.checked([css.background(tokens.primary)]),
    css.selector(":checked::before", [
      css.property("inset-inline-start", "1.125rem"),
    ]),
    style.focus_ring(),
    style.disabled_look(),
  ])
}
