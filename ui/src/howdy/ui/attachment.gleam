//// Attachments: a file shown as a card with its name, details, a picture
//// or its type, where its upload has got to, and actions such as remove
//// or download.
////
//// ```gleam
//// attachment.group([
////   attachment.attachment(
////     words: attachment.english(),
////     name: "report.pdf",
////     detail: "PDF · 2.4 MB",
////     status: attachment.Uploading(64),
////     media: None,
////     actions: [ui.sized_button(Ghost, IconSmall, [attribute.aria_label("Remove report.pdf")], [text("×")])],
////   ),
////   attachment.styled(attachment.english(), attachment.Tile, name: "photo.jpeg", detail: "820 KB",
////     status: attachment.Done,
////     media: Some(html.img([attribute.src(thumbnail), attribute.alt("")])),
////     actions: []),
//// ])
//// ```
////
//// Receiving and storing the file is the application's job; an attachment
//// shows the state it reports. A failure is announced to screen readers.
////
//// `words` say what an upload in progress is called; `howdy/ui/words`
//// holds them for a locale as its `attachment` field.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{percent, rem}

/// Where a file has got to.
pub type Status {
  /// Sending, with the percentage sent so far.
  Uploading(percent: Int)
  /// Sent, and being checked or converted.
  Processing
  /// It could not be sent or processed, and why.
  Failed(reason: String)
  /// In place.
  Done
}

/// What an attachment says about an upload in progress: `uploading` names
/// the progress bar of a file, given its name.
pub type Words {
  Words(uploading: fn(String) -> String, processing: String)
}

pub fn english() -> Words {
  Words(uploading: fn(name) { "Uploading " <> name }, processing: "Processing…")
}

/// How an attachment is laid out.
pub type Layout {
  /// A row: picture or type, then name and details, then actions.
  Row
  /// A smaller row, for a composer or a dense list.
  Compact
  /// A tile with the picture on top, for images.
  Tile
}

/// Attachments side by side, wrapping onto new lines.
pub fn group(attachments: List(Element(msg))) -> Element(msg) {
  html.ul(
    [class(group_class())],
    list.map(attachments, fn(attachment) { html.li([], [attachment]) }),
  )
}

/// An attachment as a row.
pub fn attachment(
  words words: Words,
  name name: String,
  detail detail: String,
  status status: Status,
  media media: Option(Element(msg)),
  actions actions: List(Element(msg)),
) -> Element(msg) {
  styled(words, Row, name:, detail:, status:, media:, actions:)
}

/// An attachment in another layout. `media`, such as a thumbnail `<img>`,
/// takes the place of the file type.
pub fn styled(
  words: Words,
  layout: Layout,
  name name: String,
  detail detail: String,
  status status: Status,
  media media: Option(Element(msg)),
  actions actions: List(Element(msg)),
) -> Element(msg) {
  let picture = case media {
    Some(media) ->
      html.span([class(media_class(layout)), attribute.aria_hidden(True)], [
        media,
      ])
    None ->
      html.span([class(icon_class(layout)), attribute.aria_hidden(True)], [
        text(extension(name)),
      ])
  }
  let failed = case status {
    Failed(_) -> [attribute.data("failed", "")]
    _ -> []
  }
  html.div([class(attachment_class(layout)), ..failed], [
    picture,
    html.div([class(text_class())], [
      html.div([class(name_class())], [text(name)]),
      html.div([class(detail_class())], [text(detail)]),
      progress(words, name, status),
    ]),
    case actions {
      [] -> element.none()
      _ -> html.div([class(actions_class(layout))], actions)
    },
  ])
}

fn progress(words: Words, name: String, status: Status) -> Element(msg) {
  case status {
    Uploading(done) -> {
      let done = int.clamp(done, 0, 100)
      html.div(
        [
          class(track_class()),
          attribute.role("progressbar"),
          attribute.aria_label(words.uploading(name)),
          attribute.attribute("aria-valuemin", "0"),
          attribute.attribute("aria-valuemax", "100"),
          attribute.attribute("aria-valuenow", int.to_string(done)),
        ],
        [
          html.div(
            [
              class(bar_class()),
              attribute.style("width", int.to_string(done) <> "%"),
            ],
            [],
          ),
        ],
      )
    }
    Processing ->
      html.div([class(state_class()), attribute.role("status")], [
        text(words.processing),
      ])
    Failed(reason) ->
      html.div([class(failed_class()), attribute.role("alert")], [text(reason)])
    Done -> element.none()
  }
}

/// Up to four letters of the file's extension, for its icon.
@internal
pub fn extension(name: String) -> String {
  case string.split(name, ".") {
    [_, _, ..] as parts ->
      case list.last(parts) {
        Ok(ext) -> string.uppercase(string.slice(ext, 0, 4))
        Error(Nil) -> "FILE"
      }
    _ -> "FILE"
  }
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  let layouts = [Row, Compact, Tile]
  list.flatten([
    [group_class()],
    list.map(layouts, attachment_class),
    list.map(layouts, icon_class),
    list.map(layouts, media_class),
    list.map(layouts, actions_class),
    [
      text_class(),
      name_class(),
      detail_class(),
      track_class(),
      bar_class(),
      state_class(),
      failed_class(),
    ],
  ])
}

pub fn group_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_wrap("wrap"),
    css.gap(rem(0.5)),
    css.margin(rem(0.0)),
    css.padding(rem(0.0)),
    css.list_style("none"),
  ])
}

pub fn attachment_class(layout: Layout) -> Class {
  let shape = case layout {
    Row -> [
      css.gap(rem(0.75)),
      css.padding(rem(0.5)),
      css.property("width", "min(22rem, 100%)"),
    ]
    Compact -> [
      css.gap(rem(0.5)),
      css.padding(rem(0.25)),
      css.property("padding-inline-end", tokens.space_2),
      css.property("width", "min(16rem, 100%)"),
    ]
    Tile -> [
      css.position("relative"),
      css.flex_direction("column"),
      css.align_items("stretch"),
      css.gap(rem(0.5)),
      css.padding(rem(0.5)),
      css.property("width", "10rem"),
    ]
  }
  css.class(list.append(
    [
      css.display("flex"),
      css.align_items("center"),
      css.background(tokens.surface),
      style.bordered(),
      style.radius(tokens.radius_medium),
      css.selector("[data-failed]", [
        css.property("border-color", tokens.danger),
      ]),
    ],
    shape,
  ))
}

fn box(layout: Layout) -> List(css.Style) {
  case layout {
    Row -> [css.property("width", "2.5rem"), css.property("height", "2.5rem")]
    Compact -> [css.property("width", "2rem"), css.property("height", "2rem")]
    Tile -> [css.width(percent(100)), css.property("aspect-ratio", "4 / 3")]
  }
}

pub fn icon_class(layout: Layout) -> Class {
  css.class(
    list.append(box(layout), [
      css.display("inline-flex"),
      css.align_items("center"),
      css.justify_content("center"),
      css.flex_shrink(0.0),
      style.radius(tokens.radius_small),
      css.background(tokens.muted),
      css.color(tokens.text_muted),
      css.font_size_("0.625rem"),
      css.font_weight("700"),
      css.letter_spacing("0.03em"),
    ]),
  )
}

pub fn media_class(layout: Layout) -> Class {
  css.class(
    list.append(box(layout), [
      css.display("block"),
      css.flex_shrink(0.0),
      css.overflow("hidden"),
      style.radius(tokens.radius_small),
      css.background(tokens.muted),
      css.selector(" > img", [
        css.display("block"),
        css.width(percent(100)),
        css.height(percent(100)),
        css.property("object-fit", "cover"),
      ]),
    ]),
  )
}

pub fn text_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(0.25)),
    css.property("flex", "1"),
    css.property("min-width", "0"),
  ])
}

pub fn name_class() -> Class {
  css.class([
    css.font_size(rem(0.875)),
    css.font_weight("500"),
    css.color(tokens.text),
    css.overflow("hidden"),
    css.property("text-overflow", "ellipsis"),
    css.white_space("nowrap"),
  ])
}

pub fn detail_class() -> Class {
  css.class([css.font_size(rem(0.75)), css.color(tokens.text_muted)])
}

pub fn track_class() -> Class {
  css.class([
    css.width(percent(100)),
    css.property("height", "0.25rem"),
    css.overflow("hidden"),
    style.pill(),
    css.background(tokens.muted),
  ])
}

pub fn bar_class() -> Class {
  css.class([
    css.height(percent(100)),
    css.background(tokens.primary),
    css.transition("width 200ms"),
  ])
}

pub fn state_class() -> Class {
  css.class([css.font_size(rem(0.75)), css.color(tokens.text_muted)])
}

pub fn failed_class() -> Class {
  css.class([css.font_size(rem(0.75)), css.color(tokens.danger)])
}

pub fn actions_class(layout: Layout) -> Class {
  case layout {
    // On a tile the actions sit over the picture's corner.
    Tile ->
      css.class([
        css.position("absolute"),
        css.property("top", tokens.space_3),
        css.property("inset-inline-end", tokens.space_3),
        css.display("flex"),
        css.gap(rem(0.25)),
        style.radius(tokens.radius_small),
        css.background(tokens.surface),
      ])
    _ -> css.class([css.display("flex"), css.gap(rem(0.25))])
  }
}
