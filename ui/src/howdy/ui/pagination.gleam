//// Pagination: links to the previous, next and nearby pages of a list.
////
//// ```gleam
//// pagination.pagination(words.english(), current: 4, total: 12, href: fn(page) {
////   "/orders?page=" <> int.to_string(page)
//// })
//// ```
////
//// The first and last pages and those next to the current one are always
//// shown; the gaps between are marked with an ellipsis. Pages are counted
//// from 1. Each link is an ordinary `<a>`, so it works without scripts; in
//// a live view use `live_pagination` to get attributes such as a click
//// handler or `live.navigate` instead of an `href`. `words` name the
//// links and write the page numbers; see `howdy/ui/words`.

import gleam/int
import gleam/list
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import howdy/ui/words.{type Words}
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// Links to pages `1` to `total`, with `current` marked as the current
/// page.
pub fn pagination(
  words words: Words,
  current current: Int,
  total total: Int,
  href href: fn(Int) -> String,
) -> Element(msg) {
  live_pagination(words:, current:, total:, attributes: fn(page) {
    [attribute.href(href(page))]
  })
}

/// Like `pagination`, with the attributes of each page's `<a>` chosen by
/// `attributes`.
pub fn live_pagination(
  words words: Words,
  current current: Int,
  total total: Int,
  attributes attributes: fn(Int) -> List(Attribute(msg)),
) -> Element(msg) {
  let current = int.clamp(current, 1, int.max(total, 1))
  let previous = case current > 1 {
    True ->
      html.a(
        [class(link_class()), attribute.rel("prev"), ..attributes(current - 1)],
        [
          html.span([attribute.aria_hidden(True)], [text("‹ ")]),
          text(words.previous_page),
        ],
      )
    False ->
      disabled([
        html.span([attribute.aria_hidden(True)], [text("‹")]),
        text(words.previous_page),
      ])
  }
  let next = case current < total {
    True ->
      html.a(
        [class(link_class()), attribute.rel("next"), ..attributes(current + 1)],
        [
          text(words.next_page),
          html.span([attribute.aria_hidden(True)], [text("›")]),
        ],
      )
    False ->
      disabled([
        text(words.next_page),
        html.span([attribute.aria_hidden(True)], [text("›")]),
      ])
  }
  let pages =
    pages(current, total)
    |> list.map(fn(page) {
      case page {
        Ellipsis ->
          html.li([], [
            html.span([class(ellipsis_class()), attribute.aria_hidden(True)], [
              text("…"),
            ]),
          ])
        Page(page) if page == current ->
          html.li([], [
            html.a(
              [
                class(link_class()),
                attribute.aria_current("page"),
                ..attributes(page)
              ],
              [text(words.number(page))],
            ),
          ])
        Page(page) ->
          html.li([], [
            html.a([class(link_class()), ..attributes(page)], [
              text(words.number(page)),
            ]),
          ])
      }
    })
  html.nav([class(nav_class()), attribute.aria_label(words.pagination)], [
    html.ul(
      [class(list_class())],
      list.flatten([
        [html.li([], [previous])],
        pages,
        [html.li([], [next])],
      ]),
    ),
  ])
}

fn disabled(children: List(Element(msg))) -> Element(msg) {
  html.span([class(link_class()), attribute.aria_disabled(True)], children)
}

type Slot {
  Page(Int)
  Ellipsis
}

/// The first, the last, and the current page with one either side. A gap
/// of one page is filled with that page rather than an ellipsis.
fn pages(current: Int, total: Int) -> List(Slot) {
  let wanted =
    [1, total, current - 1, current, current + 1]
    |> list.filter(fn(page) { page >= 1 && page <= total })
    |> list.unique
    |> list.sort(int.compare)
  let #(slots, _) =
    list.fold(wanted, #([], 0), fn(acc, page) {
      let #(slots, last) = acc
      let slots = case page - last {
        1 -> slots
        2 -> [Page(last + 1), ..slots]
        _ if last == 0 -> slots
        _ -> [Ellipsis, ..slots]
      }
      #([Page(page), ..slots], page)
    })
  list.reverse(slots)
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [nav_class(), list_class(), link_class(), ellipsis_class()]
}

pub fn nav_class() -> Class {
  css.class([css.display("flex"), css.justify_content("center")])
}

pub fn list_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_wrap("wrap"),
    css.align_items("center"),
    css.gap(rem(0.25)),
    css.margin(rem(0.0)),
    css.padding(rem(0.0)),
    css.list_style("none"),
  ])
}

pub fn link_class() -> Class {
  css.class([
    css.selector(":dir(rtl) > span[aria-hidden=\"true\"]", [
      css.display("inline-block"),
      css.transform_("scaleX(-1)"),
    ]),
    css.display("inline-flex"),
    css.align_items("center"),
    css.justify_content("center"),
    css.gap(rem(0.25)),
    css.property("min-width", "2.25rem"),
    css.padding_(tokens.space_2 <> " " <> tokens.space_3),
    css.border("1px solid transparent"),
    style.radius(tokens.radius_medium),
    css.color(tokens.text),
    css.font_size(rem(0.875)),
    css.font_weight("500"),
    css.line_height("1.25"),
    css.text_decoration("none"),
    css.white_space("nowrap"),
    css.cursor("pointer"),
    css.hover([css.background(tokens.muted)]),
    style.focus_ring(),
    css.selector("[aria-current=\"page\"]", [
      css.property("border-color", tokens.border),
      css.background(tokens.surface),
    ]),
    css.selector("[aria-disabled=\"true\"]", [
      css.property("opacity", "0.5"),
      css.cursor("default"),
      css.property("pointer-events", "none"),
    ]),
  ])
}

pub fn ellipsis_class() -> Class {
  css.class([
    css.display("inline-flex"),
    css.justify_content("center"),
    css.property("min-width", "2.25rem"),
    css.color(tokens.text_muted),
  ])
}
