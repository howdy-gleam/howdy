//// Paragraphs, secondary text, links, and prose: long-form text such as
//// an article or rendered Markdown.

import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{percent, rem}

/// A paragraph.
pub fn p(children: List(Element(msg))) -> Element(msg) {
  html.p([class(paragraph_class())], children)
}

/// Secondary text such as a caption or hint.
pub fn muted(content: String) -> Element(msg) {
  html.span([class(muted_class())], [text(content)])
}

/// A link.
pub fn link(href: String, children: List(Element(msg))) -> Element(msg) {
  html.a([class(link_class()), attribute.href(href)], children)
}

/// How large prose is set.
pub type Size {
  Small
  Base
  Large
}

/// Long-form text: headings, paragraphs, lists, quotes, code, tables,
/// rules and images inside it are all spaced and styled as one piece, in a
/// comfortable measure. Wrap rendered Markdown or an article in it; the
/// elements inside need no classes of their own.
pub fn prose(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  sized_prose(Base, attributes, children)
}

pub fn sized_prose(
  size: Size,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([class(prose_class(size)), ..attributes], children)
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    paragraph_class(),
    muted_class(),
    link_class(),
    prose_class(Small),
    prose_class(Base),
    prose_class(Large),
  ]
}

/// Sizes are in `em` of the container's size, so the whole scale follows
/// it.
pub fn prose_class(size: Size) -> Class {
  let base = case size {
    Small -> "0.875rem"
    Base -> "1rem"
    Large -> "1.125rem"
  }
  let block = fn(margin) { [css.margin_(margin <> " 0 0")] }
  css.class([
    css.font_size_(base),
    css.line_height("1.7"),
    css.color(tokens.text),
    css.property("max-width", "68ch"),
    css.selector(" > :first-child", [css.property("margin-top", "0")]),
    css.selector(" h1", heading("2.25em", "0")),
    css.selector(" h2", heading("1.5em", "2em")),
    css.selector(" h3", heading("1.25em", "1.6em")),
    css.selector(" h4", heading("1em", "1.5em")),
    css.selector(" p", block("1.25em")),
    css.selector(" ul", list_styles("disc")),
    css.selector(" ol", list_styles("decimal")),
    css.selector(" li", [css.margin_("0.5em 0 0")]),
    css.selector(" li::marker", [css.color(tokens.text_muted)]),
    css.selector(" blockquote", [
      css.margin_("1.6em 0 0"),
      css.property("padding-inline-start", "1em"),
      css.property("border-inline-start", "3px solid " <> tokens.border),
      css.color(tokens.text_muted),
      css.font_style("italic"),
    ]),
    css.selector(" a", [
      css.color(tokens.primary),
      css.text_decoration("underline"),
      css.property("text-underline-offset", "0.2em"),
    ]),
    css.selector(" strong", [css.font_weight("600")]),
    css.selector(" code", [
      css.padding_("0.15em 0.35em"),
      style.radius(tokens.radius_small),
      css.background(tokens.muted),
      css.font_family(tokens.font_mono),
      css.font_size_("0.875em"),
    ]),
    css.selector(" pre", [
      css.margin_("1.6em 0 0"),
      css.padding(rem(1.0)),
      css.overflow_x("auto"),
      style.radius(tokens.radius_medium),
      css.background(tokens.muted),
      css.font_size_("0.875em"),
      css.line_height("1.6"),
    ]),
    css.selector(" pre code", [
      css.padding(rem(0.0)),
      css.background("transparent"),
      css.font_size_("inherit"),
    ]),
    css.selector(" hr", [
      css.margin_("2.5em 0"),
      css.border("0"),
      style.bordered_side("top"),
    ]),
    css.selector(" img", [
      css.margin_("1.6em 0 0"),
      css.property("max-width", "100%"),
      style.radius(tokens.radius_medium),
    ]),
    css.selector(" table", [
      css.margin_("1.6em 0 0"),
      css.width(percent(100)),
      css.border_collapse("collapse"),
      css.font_size_("0.875em"),
    ]),
    css.selector(" th", [
      css.padding_("0.5em 0.75em"),
      css.text_align("start"),
      css.font_weight("600"),
      style.bordered_side("bottom"),
    ]),
    css.selector(" td", [
      css.padding_("0.5em 0.75em"),
      style.bordered_side("bottom"),
    ]),
  ])
}

fn heading(size: String, space: String) -> List(css.Style) {
  [
    css.margin_(space <> " 0 0"),
    css.font_family(tokens.font_heading),
    css.font_size_(size),
    css.font_weight("600"),
    css.line_height("1.25"),
    css.color(tokens.text),
  ]
}

fn list_styles(marker: String) -> List(css.Style) {
  [
    css.margin_("1.25em 0 0"),
    css.property("padding-inline-start", "1.5em"),
    css.list_style(marker),
  ]
}

pub fn paragraph_class() -> Class {
  css.class([css.margin_("0 0 " <> tokens.space_4), css.color(tokens.text)])
}

pub fn muted_class() -> Class {
  css.class([css.color(tokens.text_muted), css.font_size(rem(0.875))])
}

pub fn link_class() -> Class {
  css.class([
    css.color(tokens.primary),
    css.text_decoration("none"),
    css.hover([css.text_decoration("underline")]),
    style.focus_ring(),
  ])
}
