//// Buttons, and the theme toggle built on them.

import gleam/list
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// How prominent a button is.
pub type Variant {
  /// The main action: filled with the primary colour.
  Primary
  /// A supporting action: filled with the muted colour.
  Secondary
  /// A supporting action: outlined.
  Outline
  /// A quiet action, such as one in a toolbar: filled only when hovered.
  Ghost
  /// An action that looks like a link.
  Link
  /// A destructive action: filled with the danger colour.
  Danger
}

/// How big a button is.
pub type Size {
  ExtraSmall
  Small
  Medium
  Large
  /// A square button for a single icon, as tall as a medium button. Give
  /// it an `aria-label`.
  Icon
  /// A square icon button as tall as an extra-small one.
  IconExtraSmall
  /// A square icon button as tall as a small one.
  IconSmall
  /// A square icon button as tall as a large one.
  IconLarge
}

const variants = [Primary, Secondary, Outline, Ghost, Link, Danger]

const sizes = [
  ExtraSmall,
  Small,
  Medium,
  Large,
  Icon,
  IconExtraSmall,
  IconSmall,
  IconLarge,
]

/// A medium button.
pub fn button(
  variant: Variant,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  sized(variant, Medium, attributes, children)
}

/// A button of the given size.
///
/// These buttons do not submit a form; use `submit` for one that does.
/// Passing `attribute.type_("submit")` instead would give the button two
/// types, which a page and a live view resolve differently.
pub fn sized(
  variant: Variant,
  size: Size,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.button(
    [class(sized_class(variant, size)), attribute.type_("button"), ..attributes],
    children,
  )
}

/// A medium button that submits its form.
pub fn submit(
  variant: Variant,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  sized_submit(variant, Medium, attributes, children)
}

/// A button of the given size that submits its form.
pub fn sized_submit(
  variant: Variant,
  size: Size,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.button(
    [class(sized_class(variant, size)), attribute.type_("submit"), ..attributes],
    children,
  )
}

/// A button that switches the document between two named themes and
/// remembers the choice in a `theme` cookie, which the page can read back
/// with `howdy/cookie`. Works in server-rendered pages and live views. The
/// switch is made by `howdy/ui/behaviour`, and the theme names stay in
/// HTML-escaped data attributes, never executable code.
pub fn theme_toggle(
  children: List(Element(msg)),
  from a: String,
  to b: String,
) -> Element(msg) {
  button(
    Outline,
    [
      attribute.data("howdy-theme-toggle", ""),
      attribute.data("howdy-theme-from", a),
      attribute.data("howdy-theme-to", b),
    ],
    children,
  )
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  use variant <- list.flat_map(variants)
  use size <- list.map(sizes)
  sized_class(variant, size)
}

/// The class of a medium button, for styling your own markup, such as a
/// link, as a button.
pub fn button_class(variant: Variant) -> Class {
  sized_class(variant, Medium)
}

pub fn sized_class(variant: Variant, size: Size) -> Class {
  let colours = case variant {
    Primary -> [
      css.background(tokens.primary),
      css.color(tokens.on_primary),
      css.hover([css.background(tokens.primary_hover)]),
    ]
    Secondary -> [
      css.background(tokens.muted),
      css.color(tokens.text),
      css.hover([css.property("filter", "brightness(0.95)")]),
    ]
    Outline -> [
      css.background(tokens.surface),
      css.color(tokens.text),
      css.property("border-color", tokens.border),
      css.hover([css.property("border-color", tokens.primary)]),
    ]
    Ghost -> [
      css.background("transparent"),
      css.color(tokens.text),
      css.hover([css.background(tokens.muted)]),
    ]
    Link -> [
      css.background("transparent"),
      css.color(tokens.primary),
      css.hover([css.text_decoration("underline")]),
    ]
    Danger -> [
      css.background(tokens.danger),
      css.color(tokens.on_danger),
      css.hover([css.property("filter", "brightness(0.9)")]),
    ]
  }
  // Every size keeps the same line height and 1px border, so buttons of
  // one size line up whatever their variant.
  let square = fn(side: String) {
    [
      css.justify_content("center"),
      css.padding(rem(0.0)),
      css.property("width", "calc(" <> side <> " + 2px)"),
      css.property("height", "calc(" <> side <> " + 2px)"),
    ]
  }
  let dimensions = case size {
    ExtraSmall -> [
      css.padding_("0.125rem " <> tokens.space_2),
      css.font_size(rem(0.75)),
      css.gap(rem(0.25)),
    ]
    Small -> [
      css.padding_(tokens.space_1 <> " " <> tokens.space_3),
      css.font_size(rem(0.875)),
    ]
    Medium -> [
      css.padding_(tokens.space_2 <> " " <> tokens.space_4),
      css.font_size(rem(1.0)),
    ]
    Large -> [
      css.padding_(tokens.space_3 <> " " <> tokens.space_6),
      css.font_size(rem(1.0)),
    ]
    Icon -> [css.font_size(rem(1.0)), ..square("2.25rem")]
    IconExtraSmall -> [css.font_size(rem(0.75)), ..square("1.375rem")]
    IconSmall -> [css.font_size(rem(0.875)), ..square("1.75rem")]
    IconLarge -> [css.font_size(rem(1.125)), ..square("2.75rem")]
  }
  css.class(
    list.flatten([
      [
        css.display("inline-flex"),
        css.align_items("center"),
        css.gap(rem(0.5)),
        css.border("1px solid transparent"),
        style.radius(tokens.radius_medium),
        css.font_family(tokens.font_body),
        css.font_weight("500"),
        css.line_height("1.25"),
        css.white_space("nowrap"),
        css.cursor("pointer"),
        css.transition("background 120ms, border-color 120ms"),
        css.disabled([
          css.property("opacity", "0.5"),
          css.cursor("default"),
          css.property("pointer-events", "none"),
        ]),
        style.focus_ring(),
      ],
      dimensions,
      colours,
    ]),
  )
}
