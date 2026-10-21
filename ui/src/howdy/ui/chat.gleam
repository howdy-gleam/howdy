//// Chat: a conversation that keeps to its newest message, messages with an
//// avatar and a header, speech bubbles, reactions and notes.
////
//// ```gleam
//// chat.conversation(words.english(), [attribute.aria_label("Messages")], [
////   chat.note([text("Today")]),
////   chat.message(chat.Incoming, avatar: avatar.initials("GH"), header: [text("Grace · 09:41")], content: [
////     chat.bubble(chat.Incoming, [text("Did the deploy go out?")]),
////   ]),
////   chat.message(chat.Outgoing, avatar: element.none(), header: [], content: [
////     chat.bubble(chat.Outgoing, [text("Ten minutes ago.")]),
////     chat.reactions([chat.reaction("👍", 2, [])]),
////   ]),
//// ])
//// ```
////
//// A conversation stays at its newest message as messages arrive or a reply
//// streams in, and keeps its place when you scroll back to read. It needs no
//// script: it is laid out from the bottom, and the browser anchors the
//// scroll position. It is a `log` for screen readers, so they announce new
//// messages. Give each message an `id` to link to it.
////
//// Older history can be added above the first message, such as when
//// `on_older` asks for it, and the reader's place stays put. `remember`
//// brings a reader back to where they were after a reload, and
//// `start_at` opens the conversation at a message, such as the first
//// unread one.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import howdy/ui/words.{type Words}
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event
import sketch/css.{type Class}
import sketch/css/length.{percent, rem}

/// Who wrote a message: someone else, or the person reading.
pub type Side {
  Incoming
  Outgoing
}

/// A bubble's surface.
pub type Variant {
  /// The primary colour: the reader's own messages, by default.
  Filled
  /// The muted colour: everyone else's messages, by default.
  Muted
  Outline
  /// No surface, for long replies that read better as plain text.
  Ghost
  /// The danger colour, such as for a message that failed to send.
  Danger
}

/// How a note or status line stands out.
pub type Tone {
  Neutral
  /// The primary colour, such as for "New messages".
  Accent
  /// The danger colour, such as for "Deploy failed".
  Critical
}

/// The scrolling list of messages. Size it with a height or by placing it
/// in a flex column; label it with `aria-label`. When it is scrolled back
/// from the newest message, a button saying the words' `jump_to_newest`
/// appears.
pub fn conversation(
  words: Words,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([class(frame_class()), attribute.data("howdy-conversation", "")], [
    html.div([class(scroller_class()), attribute.tabindex(0), ..attributes], [
      html.div([class(log_class()), attribute.role("log")], children),
    ]),
    html.button(
      [
        class(latest_class()),
        attribute.type_("button"),
        attribute.data("howdy-latest", ""),
        attribute.hidden(True),
      ],
      [
        text(words.jump_to_newest),
        html.span([attribute.aria_hidden(True)], [text(" ↓")]),
      ],
    ),
  ])
}

/// Keep the reader's place in this conversation, named `key`, for the rest
/// of the browser session, and go back to it when the page is reloaded.
/// Put it in the conversation's attributes.
pub fn remember(key: String) -> Attribute(msg) {
  attribute.data("howdy-remember", key)
}

/// Open the conversation with the message with this id at the top, such as
/// the first unread one, instead of at the newest. A remembered place wins.
pub fn start_at(id: String) -> Attribute(msg) {
  attribute.data("howdy-start-at", id)
}

/// Hear when the reader has scrolled back near the oldest message shown,
/// to load older ones and add them above it. It is sent once until more
/// messages arrive. Put it in the conversation's attributes.
pub fn on_older(message: msg) -> Attribute(msg) {
  event.on("howdy-older", decode.success(message))
}

/// One message, or a run of messages from one person: an avatar beside a
/// header, the content and a footer. Several bubbles in the content join
/// into one group. Pass `element.none()` for no avatar, and `[]` for no
/// header or footer. Give it an `id` in `attributes` to link to it with
/// `jump`.
pub fn message(
  side: Side,
  attributes attributes: List(Attribute(msg)),
  avatar avatar: Element(msg),
  header header: List(Element(msg)),
  content content: List(Element(msg)),
  footer footer: List(Element(msg)),
) -> Element(msg) {
  let header = case header {
    [] -> element.none()
    _ -> html.div([class(header_class())], header)
  }
  let footer = case footer {
    [] -> element.none()
    _ -> html.div([class(footer_class())], footer)
  }
  html.article([class(message_class(side)), ..attributes], [
    avatar,
    html.div([class(body_class(side))], [
      header,
      ..list.append(content, [footer])
    ]),
  ])
}

/// A speech bubble: filled with the primary colour for your own messages,
/// the muted colour for everyone else's.
pub fn bubble(side: Side, children: List(Element(msg))) -> Element(msg) {
  let variant = case side {
    Incoming -> Muted
    Outgoing -> Filled
  }
  styled_bubble(side, variant, children)
}

/// A bubble with another surface. `side` still decides which corner points
/// at its sender.
pub fn styled_bubble(
  side: Side,
  variant: Variant,
  children: List(Element(msg)),
) -> Element(msg) {
  html.div(
    [class(bubble_class(side, variant)), attribute.data("bubble", "")],
    children,
  )
}

/// A row of reactions under a message.
pub fn reactions(children: List(Element(msg))) -> Element(msg) {
  html.div([class(reactions_class())], children)
}

/// A reaction and how many people chose it. Mark the reader's own with
/// `attribute.aria_pressed("true")`, and add a click handler to toggle it.
pub fn reaction(
  emoji: String,
  count: Int,
  attributes: List(Attribute(msg)),
) -> Element(msg) {
  html.button(
    [class(reaction_class()), attribute.type_("button"), ..attributes],
    [text(emoji <> " " <> int.to_string(count))],
  )
}

/// A line between messages, such as a date or "Grace joined".
pub fn note(children: List(Element(msg))) -> Element(msg) {
  tinted_note(Neutral, children)
}

/// A line between messages in a tone, such as "New messages" in the
/// accent colour.
pub fn tinted_note(tone: Tone, children: List(Element(msg))) -> Element(msg) {
  html.div([class(note_class(tone)), attribute.role("separator")], [
    html.span([], children),
  ])
}

/// A line of news from the system rather than a person, with an icon:
/// "Deploy finished", "Grace changed the topic".
pub fn status(
  tone: Tone,
  icon: Element(msg),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([class(status_class(tone))], [
    html.span([class(status_icon_class()), attribute.aria_hidden(True)], [icon]),
    html.span([], children),
  ])
}

/// A button that scrolls the conversation to the message with this id and
/// highlights it for a moment, such as a reply's quote of what it answers.
pub fn jump(id: String, children: List(Element(msg))) -> Element(msg) {
  html.button(
    [
      class(jump_class()),
      attribute.type_("button"),
      attribute.data("howdy-jump", id),
    ],
    children,
  )
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  let sides = [Incoming, Outgoing]
  let variants = [Filled, Muted, Outline, Ghost, Danger]
  let tones = [Neutral, Accent, Critical]
  list.flatten([
    [frame_class(), scroller_class(), log_class(), latest_class()],
    list.map(sides, message_class),
    list.map(sides, body_class),
    [header_class(), footer_class()],
    list.flat_map(sides, fn(side) {
      list.map(variants, fn(variant) { bubble_class(side, variant) })
    }),
    [reactions_class(), reaction_class(), jump_class(), status_icon_class()],
    list.map(tones, note_class),
    list.map(tones, status_class),
  ])
}

pub fn frame_class() -> Class {
  css.class([
    css.position("relative"),
    css.display("flex"),
    css.flex_direction("column"),
    css.property("min-height", "0"),
  ])
}

pub fn latest_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("bottom", tokens.space_3),
    css.property("inset-inline-start", "50%"),
    css.transform_("translateX(-50%)"),
    css.padding_(tokens.space_1 <> " " <> tokens.space_3),
    style.bordered(),
    style.pill(),
    css.background(tokens.surface),
    css.color(tokens.text),
    css.box_shadow("0 4px 12px -4px rgb(0 0 0 / 0.3)"),
    css.font_family(tokens.font_body),
    css.font_size(rem(0.8125)),
    css.cursor("pointer"),
    css.selector("[hidden]", [css.display("none")]),
    css.selector(":dir(rtl)", [css.transform_("translateX(50%)")]),
    style.focus_ring(),
  ])
}

pub fn scroller_class() -> Class {
  css.class([
    css.display("flex"),
    // Laid out from the bottom, so the newest message is in view and the
    // browser keeps it there as content grows.
    css.flex_direction("column-reverse"),
    css.overflow_y("auto"),
    css.property("overscroll-behavior", "contain"),
    style.focus_ring(),
  ])
}

pub fn log_class() -> Class {
  css.class([
    // Never squeezed: it is the content the scroller scrolls.
    css.flex_shrink(0.0),
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(0.75)),
    css.padding(rem(1.0)),
  ])
}

pub fn message_class(side: Side) -> Class {
  let direction = case side {
    Incoming -> "row"
    Outgoing -> "row-reverse"
  }
  css.class([
    css.display("flex"),
    css.flex_direction(direction),
    css.align_items("flex-end"),
    css.gap(rem(0.5)),
    css.property("scroll-margin", "1rem"),
    style.radius(tokens.radius_medium),
    css.transition("background 300ms"),
    // Picked out for a moment after a `jump` to it.
    css.selector("[data-flash]", [css.background(tokens.muted)]),
  ])
}

pub fn body_class(side: Side) -> Class {
  let #(align, joined) = case side {
    Incoming -> #("flex-start", "border-start-start-radius")
    Outgoing -> #("flex-end", "border-start-end-radius")
  }
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.align_items(align),
    css.gap(rem(0.125)),
    css.property("max-width", "min(36rem, 80%)"),
    // Bubbles in a run join: each after the first squares its corner on
    // the sender's side, below the one before.
    css.selector(" > [data-bubble] + [data-bubble]", [
      css.property(joined, tokens.radius_small),
    ]),
  ])
}

pub fn footer_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_wrap("wrap"),
    css.align_items("center"),
    css.gap(rem(0.5)),
    css.padding_("0.125rem " <> tokens.space_1 <> " 0"),
    css.font_size(rem(0.75)),
    css.color(tokens.text_muted),
  ])
}

pub fn header_class() -> Class {
  css.class([
    css.padding_("0 " <> tokens.space_1),
    css.font_size(rem(0.75)),
    css.color(tokens.text_muted),
  ])
}

pub fn bubble_class(side: Side, variant: Variant) -> Class {
  let corner = case side {
    Incoming -> "border-end-start-radius"
    Outgoing -> "border-end-end-radius"
  }
  let surface = case variant {
    Filled -> [css.background(tokens.primary), css.color(tokens.on_primary)]
    Muted -> [css.background(tokens.muted), css.color(tokens.text)]
    Outline -> [
      css.background(tokens.surface),
      css.color(tokens.text),
      style.bordered(),
    ]
    Ghost -> [
      css.background("transparent"),
      css.color(tokens.text),
      css.property("padding-inline", "0"),
    ]
    Danger -> [css.background(tokens.danger), css.color(tokens.on_danger)]
  }
  css.class([
    css.padding_(tokens.space_2 <> " " <> tokens.space_3),
    style.radius(tokens.radius_large),
    css.property(corner, tokens.radius_small),
    ..list.append(surface, [
      css.font_size(rem(0.9375)),
      css.line_height("1.45"),
      css.property("overflow-wrap", "anywhere"),
      css.white_space("pre-wrap"),
      css.max_width(percent(100)),
    ])
  ])
}

pub fn reactions_class() -> Class {
  css.class([css.display("flex"), css.flex_wrap("wrap"), css.gap(rem(0.25))])
}

pub fn reaction_class() -> Class {
  css.class([
    css.padding_("0.125rem " <> tokens.space_2),
    style.bordered(),
    style.pill(),
    css.background(tokens.surface),
    css.color(tokens.text),
    css.font_size(rem(0.75)),
    css.cursor("pointer"),
    css.hover([css.background(tokens.muted)]),
    style.focus_ring(),
    css.selector("[aria-pressed=\"true\"]", [
      css.property("border-color", tokens.primary),
      css.background(tokens.muted),
    ]),
  ])
}

fn tone_colour(tone: Tone) -> String {
  case tone {
    Neutral -> tokens.text_muted
    Accent -> tokens.primary
    Critical -> tokens.danger
  }
}

pub fn note_class(tone: Tone) -> Class {
  let line = case tone {
    Neutral -> tokens.border
    _ -> tone_colour(tone)
  }
  css.class([
    css.display("flex"),
    css.align_items("center"),
    css.gap(rem(0.75)),
    css.font_size(rem(0.75)),
    css.font_weight(case tone {
      Neutral -> "400"
      _ -> "500"
    }),
    css.color(tone_colour(tone)),
    css.before([
      css.content("\"\""),
      css.property("flex", "1"),
      css.property("border-top", "1px solid " <> line),
    ]),
    css.after([
      css.content("\"\""),
      css.property("flex", "1"),
      css.property("border-top", "1px solid " <> line),
    ]),
  ])
}

pub fn status_class(tone: Tone) -> Class {
  css.class([
    css.display("flex"),
    css.align_items("center"),
    css.justify_content("center"),
    css.gap(rem(0.5)),
    css.font_size(rem(0.8125)),
    css.color(case tone {
      Neutral -> tokens.text_muted
      _ -> tone_colour(tone)
    }),
  ])
}

pub fn status_icon_class() -> Class {
  css.class([
    css.display("inline-flex"),
    css.align_items("center"),
    css.justify_content("center"),
    css.property("width", "1.25rem"),
    css.property("height", "1.25rem"),
    style.pill(),
    css.background(tokens.muted),
    css.font_size(rem(0.75)),
  ])
}

pub fn jump_class() -> Class {
  css.class([
    css.display("block"),
    css.padding_(tokens.space_1 <> " " <> tokens.space_2),
    css.border("0"),
    css.property("border-inline-start", "3px solid " <> tokens.border),
    style.radius(tokens.radius_small),
    css.background(tokens.muted),
    css.color(tokens.text_muted),
    css.font_family(tokens.font_body),
    css.font_size(rem(0.8125)),
    css.text_align("start"),
    css.cursor("pointer"),
    css.hover([css.color(tokens.text)]),
    style.focus_ring(),
  ])
}
