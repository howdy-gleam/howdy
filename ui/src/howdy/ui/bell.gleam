//// A notification bell: a button showing how many notifications are
//// unread, which opens a panel listing the newest.
////
//// ```gleam
//// bell.new(id: "inbox", source: "/notifications")
//// |> bell.unread(count)
//// |> bell.inbox("/inbox")
//// |> bell.view
//// ```
////
//// `source` is where `howdy_notifications` serves the inbox, with
//// `notifications.routes`. The bell keeps up with it as things happen: it
//// follows the server-sent events at `source/events`, so its count
//// changes as notifications arrive or are read in any tab, and each new
//// notification is shown as a toast. Opening the panel reads the newest
//// from `source`, and clicking one marks it read on the way to its link.
//// Any other inbox that answers the same JSON works too.
////
//// Give it the unread count when drawing the page, so it is right before
//// the events connect. Put it in the page itself, such as in the header,
//// rather than in a live view, so the connection lasts as long as the
//// page. The listening is done by `howdy/ui/behaviour`, which every page
//// includes. Without JavaScript the panel still opens and links to
//// `inbox`.
////
//// Toasts go in the page's toast region, `toast.region`, or one the bell
//// adds when the page has none.
////
//// A browser keeps one connection open for each tab with a bell. Over
//// HTTP/1.1 browsers allow six connections to a site at once, so serve
//// the app over HTTP/2, as `howdy` does with TLS, if people keep many
//// tabs open.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import howdy/ui/button.{Ghost, IconSmall, Small}
import howdy/ui/popover
import howdy/ui/style.{anchor_name, class}
import howdy/ui/theme/tokens
import howdy/ui/toast
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/element/svg
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// What the bell says. `unread` may contain `{count}`.
pub type Words {
  Words(
    title: String,
    unread: String,
    mark_all_read: String,
    mark_read: String,
    mark_unread: String,
    empty: String,
    see_all: String,
    failed: String,
    push_on: String,
    push_off: String,
    push_blocked: String,
  )
}

pub fn english() -> Words {
  Words(
    title: "Notifications",
    unread: "{count} unread",
    mark_all_read: "Mark all as read",
    mark_read: "Mark as read",
    mark_unread: "Mark as unread",
    empty: "You're all caught up.",
    see_all: "See all notifications",
    failed: "Notifications could not be loaded.",
    push_on: "Turn on browser notifications",
    push_off: "Turn off browser notifications",
    push_blocked: "Browser notifications are blocked in this browser's settings.",
  )
}

/// A bell under construction.
pub opaque type Bell {
  Bell(
    id: String,
    source: String,
    unread: Int,
    inbox: Option(String),
    push: Option(String),
    toasts: Bool,
    words: Words,
  )
}

/// A bell whose panel has this id, for the inbox served at `source`.
pub fn new(id id: String, source source: String) -> Bell {
  Bell(
    id:,
    source:,
    unread: 0,
    inbox: None,
    push: None,
    toasts: True,
    words: english(),
  )
}

/// How many notifications are unread as the page is drawn.
pub fn unread(bell: Bell, count: Int) -> Bell {
  Bell(..bell, unread: int.max(count, 0))
}

/// A page listing every notification, linked at the foot of the panel.
pub fn inbox(bell: Bell, href: String) -> Bell {
  Bell(..bell, inbox: Some(href))
}

/// Offer to turn on the browser's own notifications, which arrive even
/// when the app is not open, using the routes `web_push.routes` serves at
/// `path`. The panel shows a button for it in browsers that support push.
pub fn push(bell: Bell, at path: String) -> Bell {
  Bell(..bell, push: Some(path))
}

/// Do not show new notifications as toasts.
pub fn without_toasts(bell: Bell) -> Bell {
  Bell(..bell, toasts: False)
}

/// Say things in other words, or another language.
pub fn words(bell: Bell, words: Words) -> Bell {
  Bell(..bell, words:)
}

/// The words for this many unread notifications.
pub fn unread_label(words: Words, count: Int) -> String {
  case count {
    0 -> words.title
    _ -> words.title <> ", " <> replace_count(words.unread, count)
  }
}

pub fn view(bell: Bell) -> Element(msg) {
  let words = bell.words
  let push = case bell.push {
    Some(path) -> [
      html.div([class(push_class())], [
        html.button(
          [
            class(button.sized_class(button.Outline, Small)),
            attribute.type_("button"),
            attribute.data("howdy-bell-push", path),
            attribute.hidden(True),
          ],
          [text(words.push_on)],
        ),
        html.p(
          [
            class(empty_class()),
            attribute.data("howdy-bell-push-blocked", ""),
            attribute.hidden(True),
          ],
          [text(words.push_blocked)],
        ),
      ]),
    ]
    None -> []
  }
  let footer = case bell.inbox {
    Some(href) -> [
      html.a([class(footer_class()), attribute.href(href)], [
        text(words.see_all),
      ]),
    ]
    None -> []
  }
  html.div(
    [
      class(bell_class()),
      attribute.data("howdy-bell", ""),
      attribute.data("source", bell.source),
      attribute.data("unread", int.to_string(bell.unread)),
      attribute.data("toasts", case bell.toasts {
        True -> "true"
        False -> "false"
      }),
      attribute.data("text-title", words.title),
      attribute.data("text-unread", words.unread),
      attribute.data("text-failed", words.failed),
      attribute.data("text-empty", words.empty),
      attribute.data("text-mark-read", words.mark_read),
      attribute.data("text-mark-unread", words.mark_unread),
      attribute.data("text-push-on", words.push_on),
      attribute.data("text-push-off", words.push_off),
    ],
    [
      html.button(
        [
          class(button.sized_class(Ghost, button.Icon)),
          class(button_class()),
          attribute.type_("button"),
          attribute.aria_label(unread_label(words, bell.unread)),
          attribute.aria_haspopup("dialog"),
          attribute.data("howdy-bell-button", ""),
          ..popover.trigger(bell.id)
        ],
        [
          bell_icon(),
          html.span(
            [
              class(count_class()),
              attribute.data("howdy-bell-count", ""),
              attribute.aria_hidden(True),
              ..case bell.unread {
                0 -> [attribute.hidden(True)]
                _ -> []
              }
            ],
            [text(count_text(bell.unread))],
          ),
        ],
      ),
      html.div(
        [
          class(popover.popover_class()),
          class(panel_class()),
          attribute.id(bell.id),
          attribute.popover("auto"),
          attribute.data("howdy-anchored", anchor_name(bell.id)),
          attribute.role("dialog"),
          attribute.aria_label(words.title),
          attribute.data("howdy-bell-panel", ""),
        ],
        [
          html.div([class(header_class())], [
            html.span([class(heading_class())], [text(words.title)]),
            html.button(
              [
                class(button.sized_class(Ghost, Small)),
                attribute.type_("button"),
                attribute.data("howdy-bell-read-all", ""),
              ],
              [text(words.mark_all_read)],
            ),
          ]),
          html.ul(
            [
              class(list_class()),
              attribute.data("howdy-bell-list", ""),
              attribute.aria_label(words.title),
            ],
            [],
          ),
          html.p(
            [
              class(empty_class()),
              attribute.data("howdy-bell-empty", ""),
              attribute.hidden(True),
            ],
            [text(words.empty)],
          ),
          ..list.append(push, footer)
        ],
      ),
      // Markup the script copies, so what it adds is styled like the rest.
      html.template([attribute.data("howdy-bell-item", "")], [item(words)]),
      html.template([attribute.data("howdy-bell-toast", "")], [
        toast.toast(toast.Info, [], [
          toast.title([attribute.data("howdy-bell-toast-title", "")] |> span),
          toast.description(
            [attribute.data("howdy-bell-toast-body", "")] |> span,
          ),
          toast.close([attribute.aria_label("Dismiss")]),
        ]),
      ]),
      html.template([attribute.data("howdy-bell-region", "")], [
        toast.region([], []),
      ]),
    ],
  )
}

fn span(attributes: List(Attribute(msg))) -> List(Element(msg)) {
  [html.span(attributes, [])]
}

fn item(words: Words) -> Element(msg) {
  html.li([class(item_class()), attribute.data("howdy-bell-entry", "")], [
    html.a([class(link_class()), attribute.data("howdy-bell-link", "")], [
      html.span(
        [class(title_class()), attribute.data("howdy-bell-title", "")],
        [],
      ),
      html.span(
        [class(body_class()), attribute.data("howdy-bell-body", "")],
        [],
      ),
      html.time(
        [class(time_class()), attribute.data("howdy-bell-time", "")],
        [],
      ),
    ]),
    html.button(
      [
        class(button.sized_class(Ghost, IconSmall)),
        class(mark_class()),
        attribute.type_("button"),
        attribute.aria_label(words.mark_read),
        attribute.data("howdy-bell-mark", ""),
      ],
      [
        html.span(
          [
            class(dot_class()),
            attribute.data("howdy-bell-dot", ""),
            attribute.aria_hidden(True),
          ],
          [],
        ),
      ],
    ),
  ])
}

fn bell_icon() -> Element(msg) {
  html.svg(
    [
      attribute.attribute("viewBox", "0 0 24 24"),
      attribute.attribute("fill", "none"),
      attribute.attribute("stroke", "currentColor"),
      attribute.attribute("stroke-width", "2"),
      attribute.attribute("stroke-linecap", "round"),
      attribute.attribute("stroke-linejoin", "round"),
      attribute.attribute("width", "1.25rem"),
      attribute.attribute("height", "1.25rem"),
      attribute.aria_hidden(True),
    ],
    [
      svg.path([
        attribute.attribute("d", "M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"),
      ]),
      svg.path([attribute.attribute("d", "M10.3 21a1.94 1.94 0 0 0 3.4 0")]),
    ],
  )
}

fn count_text(count: Int) -> String {
  case count > 99 {
    True -> "99+"
    False -> int.to_string(count)
  }
}

fn replace_count(template: String, count: Int) -> String {
  string.replace(template, "{count}", int.to_string(count))
}

// -- Styles ------------------------------------------------------------------

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    bell_class(),
    button_class(),
    count_class(),
    panel_class(),
    header_class(),
    heading_class(),
    list_class(),
    item_class(),
    link_class(),
    title_class(),
    body_class(),
    time_class(),
    mark_class(),
    dot_class(),
    empty_class(),
    push_class(),
    footer_class(),
  ]
}

pub fn bell_class() -> Class {
  css.class([css.display("inline-block"), css.position("relative")])
}

pub fn button_class() -> Class {
  css.class([css.position("relative")])
}

pub fn count_class() -> Class {
  css.class([
    css.position("absolute"),
    css.top(rem(0.0)),
    css.property("inset-inline-end", "0"),
    css.property("min-width", "1.125rem"),
    css.height(rem(1.125)),
    css.padding_("0 0.25rem"),
    css.display("inline-flex"),
    css.align_items("center"),
    css.justify_content("center"),
    style.pill(),
    css.background(tokens.danger),
    css.color(tokens.on_danger),
    css.font_size(rem(0.6875)),
    css.font_weight("600"),
    css.line_height("1"),
    css.property("translate", "25% -25%"),
    css.selector("[hidden]", [css.display("none")]),
  ])
}

pub fn panel_class() -> Class {
  css.class([
    css.padding(rem(0.0)),
    css.property("width", "min(24rem, calc(100vw - 2rem))"),
    css.property("max-height", "min(32rem, 80vh)"),
    css.property("overflow", "auto"),
  ])
}

pub fn header_class() -> Class {
  css.class([
    css.display("flex"),
    css.align_items("center"),
    css.justify_content("space-between"),
    css.gap(rem(0.5)),
    css.padding_(tokens.space_2 <> " " <> tokens.space_3),
    style.bordered_side("bottom"),
  ])
}

pub fn heading_class() -> Class {
  css.class([css.font_weight("600"), css.font_size(rem(0.875))])
}

pub fn list_class() -> Class {
  css.class([
    css.list_style("none"),
    css.margin(rem(0.0)),
    css.padding(rem(0.0)),
    css.selector(":empty", [css.display("none")]),
  ])
}

pub fn item_class() -> Class {
  css.class([
    css.display("flex"),
    css.align_items("flex-start"),
    css.gap(rem(0.25)),
    css.padding_(tokens.space_2 <> " " <> tokens.space_2),
    css.selector(":not(:last-child)", [style.bordered_side("bottom")]),
    // An unread notification has a bold title and a filled dot.
    css.selector("[data-unread] [data-howdy-bell-title]", [
      css.font_weight("600"),
    ]),
    css.selector("[data-unread] [data-howdy-bell-dot]", [
      css.background(tokens.primary),
    ]),
  ])
}

pub fn link_class() -> Class {
  css.class([
    css.flex("1"),
    css.display("grid"),
    css.gap(rem(0.125)),
    css.padding(rem(0.25)),
    style.radius(tokens.radius_small),
    css.color(tokens.text),
    css.text_decoration("none"),
    css.property("min-width", "0"),
    css.selector("[href]:hover", [css.background(tokens.muted)]),
    css.focus_visible([style.focus_ring()]),
  ])
}

pub fn title_class() -> Class {
  css.class([css.font_size(rem(0.875))])
}

pub fn body_class() -> Class {
  css.class([
    css.font_size(rem(0.8125)),
    css.color(tokens.text_muted),
    css.selector(":empty", [css.display("none")]),
  ])
}

pub fn time_class() -> Class {
  css.class([css.font_size(rem(0.75)), css.color(tokens.text_muted)])
}

pub fn mark_class() -> Class {
  css.class([css.flex_shrink(0.0)])
}

/// Filled for an unread notification, hollow for a read one.
pub fn dot_class() -> Class {
  css.class([
    css.width(rem(0.5)),
    css.height(rem(0.5)),
    style.pill(),
    css.border("1.5px solid " <> tokens.primary),
  ])
}

pub fn empty_class() -> Class {
  css.class([
    css.margin(rem(0.0)),
    css.padding(rem(1.0)),
    css.text_align("center"),
    css.font_size(rem(0.875)),
    css.color(tokens.text_muted),
  ])
}

pub fn push_class() -> Class {
  css.class([
    css.display("grid"),
    css.justify_items("center"),
    css.padding_(tokens.space_2 <> " " <> tokens.space_3),
    style.bordered_side("top"),
    css.selector(":not(:has(> :not([hidden])))", [css.display("none")]),
  ])
}

pub fn footer_class() -> Class {
  css.class([
    css.display("block"),
    css.padding_(tokens.space_2 <> " " <> tokens.space_3),
    style.bordered_side("top"),
    css.text_align("center"),
    css.font_size(rem(0.875)),
    css.color(tokens.primary),
    css.text_decoration("none"),
    css.hover([css.text_decoration("underline")]),
  ])
}
