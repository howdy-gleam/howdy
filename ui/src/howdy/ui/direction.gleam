//// Direction: which way text runs, for a whole page or part of one.
////
//// ```gleam
//// page.new("طلبات")
//// |> page.lang("ar")
//// |> page.direction(direction.Rtl)
////
//// direction.provider(direction.Rtl, [], [hebrew_quote])
//// ```
////
//// Components lay themselves out from the start of the line to its end,
//// so in right-to-left text the sidebar sits on the right, a menu's tick
//// on the right, and so on. The arrow keys follow what the reader sees:
//// right moves to the tab on the right, whichever way the text runs, and
//// arrows such as a carousel's point the way the text goes. Charts and
//// one-time codes keep reading left to right, as they usually do.
////
//// Set the direction once, on the page; use `provider` for a passage in
//// another direction. Both set the HTML `dir` attribute, so the browser
//// does the rest. `of` gives the direction of a locale, so a page in the
//// reader's language can follow it:
////
//// ```gleam
//// let l = locale.detect(ctx, locales)
//// page.new(title)
//// |> page.lang(locale.to_string(l))
//// |> page.direction(direction.of(l))
//// ```

import howdy/locale.{type Locale}
import howdy/ui/style.{class}
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}

pub type Direction {
  /// Left to right, as in English.
  Ltr
  /// Right to left, as in Arabic and Hebrew.
  Rtl
  /// Whichever the text itself starts with, for content from users.
  Auto
}

/// The direction text in a locale runs: `Rtl` for Arabic, Hebrew, Persian
/// and others written right to left, `Ltr` for the rest.
pub fn of(language: Locale) -> Direction {
  case locale.right_to_left(language) {
    True -> Rtl
    False -> Ltr
  }
}

/// The direction of a BCP 47 tag, such as a translator's locale. A tag
/// that cannot be read is left to right.
pub fn of_tag(tag: String) -> Direction {
  case locale.parse(tag) {
    Ok(parsed) -> of(parsed)
    Error(Nil) -> Ltr
  }
}

/// The `dir` attribute for a direction, for any element.
pub fn dir(direction: Direction) -> Attribute(msg) {
  attribute.attribute("dir", case direction {
    Ltr -> "ltr"
    Rtl -> "rtl"
    Auto -> "auto"
  })
}

/// A part of the page in another direction.
pub fn provider(
  direction: Direction,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([class(provider_class()), dir(direction), ..attributes], children)
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [provider_class()]
}

pub fn provider_class() -> Class {
  css.class([css.display("contents")])
}
