//// A rich text document: what `howdy/ui/rich_text` edits, as Gleam values.
////
//// The editor posts its document as JSON. Decoding that JSON is also the
//// safety check: anything that is not a paragraph, heading, quote, list,
//// code block, divider, mention or attachment, or a link that is not
//// `http`, `https`, `mailto`, `tel` or a path on your site, is refused.
//// Store the document with `to_string`, and show it with `view`, which
//// renders through Lustre, so its text is always escaped.
////
//// ```gleam
//// use body <- result.try(document.decode(form.value(fields, "body")))
//// use person <- list.each(document.mentions(body))
//// // Check `person.id` is someone this user may mention, then tell them.
//// save(document.to_string(body))
////
//// // Later, drawing mentions from what is true now, not when it was saved:
//// document.view_with(
////   body,
////   mention: fn(mention) {
////     document.mention_view(mention, href: Some("/people/" <> mention.id))
////   },
////   attachment: fn(file) {
////     document.attachment_view(file, url: Some(files.url(file.key)))
////   },
//// )
//// ```
////
//// Mentions and attachments keep a label, a name and a size from the moment
//// they were added. Like Rails' Action Text, render them from your own
//// records when you show the document, so a renamed person or a deleted
//// file shows as it is now.

import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import howdy/ui/attachment as card
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import howdy/ui/typography
import howdy/ui/uploader
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// A whole document: its blocks, in order.
pub type Document {
  Document(blocks: List(Block))
}

pub type Block {
  Paragraph(content: List(Inline))
  /// A heading from 1, the largest, to 6.
  Heading(level: Int, content: List(Inline))
  Quote(blocks: List(Block))
  /// A list of items, each made of blocks. An item starts with a
  /// paragraph and may hold more lists.
  BulletList(items: List(List(Block)))
  NumberedList(start: Int, items: List(List(Block)))
  CodeBlock(code: String)
  /// A horizontal rule.
  Divider
  /// A file, such as an image, sent to storage as the document was written.
  Attached(attachment: Attachment)
}

pub type Inline {
  Text(text: String, marks: List(Mark))
  Mentioned(mention: Mention)
  /// A line break within a paragraph, from Shift+Enter.
  LineBreak
}

pub type Mark {
  Bold
  Italic
  Strike
  Code
  Link(href: String)
}

/// Someone or something mentioned, such as `@Ada Lovelace` or `#42`.
/// `kind` and `id` are what your search endpoint gave the editor; `label`
/// is the text it showed then.
pub type Mention {
  Mention(trigger: String, kind: String, id: String, label: String)
}

/// A file stored under `key`, as your upload endpoint named it. The name,
/// type and size are what the browser said when it was added.
pub type Attachment {
  Attachment(key: String, name: String, content_type: String, size: Int)
}

/// A document with nothing in it.
pub fn empty() -> Document {
  Document([Paragraph([])])
}

/// A document from plain text: a paragraph for each run of lines separated
/// by a blank line, keeping single line breaks. For bringing existing text
/// columns into rich text.
pub fn from_text(text: String) -> Document {
  let paragraphs =
    text
    |> string.replace("\r\n", "\n")
    |> string.split("\n\n")
    |> list.map(string.trim)
    |> list.filter(fn(paragraph) { paragraph != "" })
    |> list.map(fn(paragraph) {
      paragraph
      |> string.split("\n")
      |> list.map(fn(line) { [Text(line, [])] })
      |> list.intersperse([LineBreak])
      |> list.flatten
      |> list.filter(fn(inline) { inline != Text("", []) })
      |> Paragraph
    })
  case paragraphs {
    [] -> empty()
    _ -> Document(paragraphs)
  }
}

/// Whether a document has nothing worth keeping: no text but spaces, no
/// mentions, attachments or dividers. A required editor refuses to submit
/// such a document; check with this on the server too.
pub fn is_empty(document: Document) -> Bool {
  list.all(document.blocks, block_is_empty)
}

fn block_is_empty(block: Block) -> Bool {
  case block {
    Paragraph(content) | Heading(content:, ..) ->
      list.all(content, fn(inline) {
        case inline {
          Text(text, _) -> string.trim(text) == ""
          LineBreak -> True
          Mentioned(_) -> False
        }
      })
    Quote(blocks) -> list.all(blocks, block_is_empty)
    BulletList(items) | NumberedList(items:, ..) ->
      list.all(items, list.all(_, block_is_empty))
    CodeBlock(code) -> string.trim(code) == ""
    Divider | Attached(_) -> False
  }
}

/// Everyone and everything mentioned, in the order they first appear, each
/// once. Check each against your own records before acting on it: the
/// document came from a browser.
pub fn mentions(document: Document) -> List(Mention) {
  document.blocks
  |> list.flat_map(block_inlines)
  |> list.filter_map(fn(inline) {
    case inline {
      Mentioned(mention) -> Ok(mention)
      _ -> Error(Nil)
    }
  })
  |> list.fold([], fn(seen, mention) {
    case
      list.any(seen, fn(other: Mention) {
        other.kind == mention.kind && other.id == mention.id
      })
    {
      True -> seen
      False -> [mention, ..seen]
    }
  })
  |> list.reverse
}

/// Every attached file, in order. Check each key is one your app handed to
/// this user before you keep it.
pub fn attachments(document: Document) -> List(Attachment) {
  list.flat_map(document.blocks, block_attachments)
}

fn block_attachments(block: Block) -> List(Attachment) {
  case block {
    Attached(attachment) -> [attachment]
    Quote(blocks) -> list.flat_map(blocks, block_attachments)
    BulletList(items) | NumberedList(items:, ..) ->
      list.flat_map(items, list.flat_map(_, block_attachments))
    _ -> []
  }
}

fn block_inlines(block: Block) -> List(Inline) {
  case block {
    Paragraph(content) | Heading(content:, ..) -> content
    Quote(blocks) -> list.flat_map(blocks, block_inlines)
    BulletList(items) | NumberedList(items:, ..) ->
      list.flat_map(items, list.flat_map(_, block_inlines))
    CodeBlock(_) | Divider | Attached(_) -> []
  }
}

/// The text of a document, for search, previews, notifications and email:
/// paragraphs separated by blank lines, list items marked `-` or `1.`,
/// quotes with `>`, mentions as `@Ada Lovelace` and attachments as their
/// names in brackets.
pub fn to_plain_text(document: Document) -> String {
  document.blocks
  |> list.map(block_text)
  |> string.join("\n\n")
}

fn block_text(block: Block) -> String {
  case block {
    Paragraph(content) | Heading(content:, ..) -> inline_text(content)
    Quote(blocks) ->
      blocks
      |> list.map(block_text)
      |> string.join("\n\n")
      |> prefix_lines("> ", "> ")
    BulletList(items) ->
      items
      |> list.map(fn(item) { item_text(item, "- ") })
      |> string.join("\n")
    NumberedList(start, items) ->
      items
      |> list.index_map(fn(item, index) {
        item_text(item, int.to_string(start + index) <> ". ")
      })
      |> string.join("\n")
    CodeBlock(code) -> code
    Divider -> "---"
    Attached(attachment) -> "[" <> attachment.name <> "]"
  }
}

fn item_text(blocks: List(Block), marker: String) -> String {
  blocks
  |> list.map(block_text)
  |> string.join("\n")
  |> prefix_lines(marker, string.repeat(" ", string.length(marker)))
}

fn prefix_lines(text: String, first: String, rest: String) -> String {
  case string.split(text, "\n") {
    [] -> first
    [line, ..lines] ->
      [first <> line, ..list.map(lines, fn(line) { trim_end(rest <> line) })]
      |> string.join("\n")
  }
}

fn trim_end(line: String) -> String {
  case string.trim(line) {
    "" -> ""
    _ -> line
  }
}

fn inline_text(content: List(Inline)) -> String {
  content
  |> list.map(fn(inline) {
    case inline {
      Text(text, _) -> text
      Mentioned(mention) -> mention.trigger <> mention.label
      LineBreak -> "\n"
    }
  })
  |> string.concat
}

// -- Links -------------------------------------------------------------------

/// Whether a link may go in a document: an `http`, `https`, `mailto` or
/// `tel` address, or a path, query or fragment on the same site. Anything
/// else, such as `javascript:`, is refused, as are spaces and control
/// characters, which browsers strip from a scheme before reading it.
pub fn is_safe_link(href: String) -> Bool {
  let length = string.length(href)
  length > 0
  && length <= 2048
  && !has_space_or_control(href)
  && case scheme(href) {
    Ok(scheme) ->
      list.contains(
        ["http", "https", "mailto", "tel"],
        string.lowercase(scheme),
      )
    Error(Nil) -> True
  }
}

fn has_space_or_control(href: String) -> Bool {
  string.to_utf_codepoints(href)
  |> list.any(fn(point) {
    let code = string.utf_codepoint_to_int(point)
    code <= 32 || code == 127
  })
}

// The scheme is whatever comes before a colon that is before any `/`, `?`
// or `#`; without one, the link is relative.
fn scheme(href: String) -> Result(String, Nil) {
  case string.split_once(href, ":") {
    Ok(#(before, _)) ->
      case
        string.contains(before, "/")
        || string.contains(before, "?")
        || string.contains(before, "#")
      {
        True -> Error(Nil)
        False -> Ok(before)
      }
    Error(Nil) -> Error(Nil)
  }
}

// -- JSON --------------------------------------------------------------------

// Lists and quotes nest no deeper than this.
const max_depth = 20

/// Read a document from the JSON the editor posts, refusing anything it
/// would not have made. The error says what was wrong, for logs; it is not
/// for people.
pub fn decode(json_text: String) -> Result(Document, String) {
  case json.parse(json_text, decoder()) {
    Ok(document) -> Ok(document)
    Error(json.UnableToDecode(errors)) ->
      Error(
        "not a rich text document: "
        <> string.join(
          list.map(errors, fn(error) {
            "expected "
            <> error.expected
            <> " at "
            <> string.join(error.path, ".")
          }),
          "; ",
        ),
      )
    Error(_) -> Error("not a rich text document: not JSON")
  }
}

/// The decoder `decode` uses, for a document inside other JSON.
pub fn decoder() -> Decoder(Document) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "doc" -> {
      use blocks <- decode.optional_field(
        "content",
        [],
        decode.list(block_decoder(1)),
      )
      decode.success(Document(blocks))
    }
    _ -> decode.failure(empty(), "a document")
  }
}

fn block_decoder(depth: Int) -> Decoder(Block) {
  use <- lazy
  use kind <- decode.field("type", decode.string)
  case depth > max_depth {
    True -> decode.failure(Divider, "no more than 20 levels of nesting")
    False -> block_of_kind(kind, depth)
  }
}

fn block_of_kind(kind: String, depth: Int) -> Decoder(Block) {
  let blocks = decode.list(block_decoder(depth + 1))
  case kind {
    "paragraph" -> {
      use content <- inline_content
      decode.success(Paragraph(content))
    }
    "heading" -> {
      use level <- decode.subfield(["attrs", "level"], decode.int)
      use content <- inline_content
      case level >= 1 && level <= 6 {
        True -> decode.success(Heading(level, content))
        False -> decode.failure(Divider, "a heading level from 1 to 6")
      }
    }
    "blockquote" -> {
      use blocks <- decode.optional_field("content", [], blocks)
      decode.success(Quote(blocks))
    }
    "bullet_list" -> {
      use items <- decode.optional_field(
        "content",
        [],
        decode.list(item_decoder(depth)),
      )
      decode.success(BulletList(items))
    }
    "ordered_list" -> {
      use start <- decode.optional_field(
        "attrs",
        1,
        decode.optional_field("order", 1, decode.int, decode.success),
      )
      use items <- decode.optional_field(
        "content",
        [],
        decode.list(item_decoder(depth)),
      )
      decode.success(NumberedList(int.max(start, 0), items))
    }
    "code_block" -> {
      use parts <- decode.optional_field(
        "content",
        [],
        decode.list({
          use kind <- decode.field("type", decode.string)
          use text <- decode.field("text", decode.string)
          case kind {
            "text" -> decode.success(text)
            _ -> decode.failure("", "text in a code block")
          }
        }),
      )
      decode.success(CodeBlock(string.concat(parts)))
    }
    "horizontal_rule" -> decode.success(Divider)
    "attachment" -> {
      use attachment <- decode.field("attrs", attachment_decoder())
      decode.success(Attached(attachment))
    }
    _ -> decode.failure(Divider, "a known kind of block")
  }
}

fn item_decoder(depth: Int) -> Decoder(List(Block)) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "list_item" ->
      decode.optional_field(
        "content",
        [],
        decode.list(block_decoder(depth + 1)),
        decode.success,
      )
    _ -> decode.failure([], "a list item")
  }
}

fn attachment_decoder() -> Decoder(Attachment) {
  use key <- decode.field("key", decode.string)
  use name <- decode.field("name", decode.string)
  use content_type <- decode.field("content_type", decode.string)
  use size <- decode.field("size", decode.int)
  let attachment = Attachment(key:, name:, content_type:, size:)
  case key != "" && size >= 0 {
    True -> decode.success(attachment)
    False -> decode.failure(attachment, "an uploaded file")
  }
}

fn inline_content(next: fn(List(Inline)) -> Decoder(a)) -> Decoder(a) {
  use content <- decode.optional_field(
    "content",
    [],
    decode.list(inline_decoder()),
  )
  // Empty text is allowed in, but the editor cannot load it, so drop it.
  next(list.filter(content, fn(inline) { inline != Text("", []) }))
}

fn inline_decoder() -> Decoder(Inline) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "text" -> {
      use text <- decode.field("text", decode.string)
      use marks <- decode.optional_field(
        "marks",
        [],
        decode.list(mark_decoder()),
      )
      case text {
        "" -> decode.success(Text("", []))
        _ -> decode.success(Text(text, list.unique(marks)))
      }
    }
    "mention" -> {
      use mention <- decode.field("attrs", {
        use trigger <- decode.field("trigger", decode.string)
        use kind <- decode.field("kind", decode.string)
        use id <- decode.field("id", decode.string)
        use label <- decode.field("label", decode.string)
        decode.success(Mention(trigger:, kind:, id:, label:))
      })
      case
        string.length(mention.trigger) == 1
        && mention.kind != ""
        && mention.id != ""
        && mention.label != ""
      {
        True -> decode.success(Mentioned(mention))
        False -> decode.failure(LineBreak, "a mention")
      }
    }
    "hard_break" -> decode.success(LineBreak)
    _ -> decode.failure(LineBreak, "text, a mention or a line break")
  }
}

fn mark_decoder() -> Decoder(Mark) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "bold" -> decode.success(Bold)
    "italic" -> decode.success(Italic)
    "strike" -> decode.success(Strike)
    "code" -> decode.success(Code)
    "link" -> {
      use href <- decode.subfield(["attrs", "href"], decode.string)
      case is_safe_link(href) {
        True -> decode.success(Link(href))
        False -> decode.failure(Bold, "a safe link")
      }
    }
    _ -> decode.failure(Bold, "bold, italic, strike, code or a link")
  }
}

fn lazy(decoder: fn() -> Decoder(a)) -> Decoder(a) {
  decode.recursive(decoder)
}

/// A document as JSON, in the shape the editor reads and posts.
pub fn to_json(document: Document) -> Json {
  to_json_with(document, fn(_) { None })
}

/// A document as a JSON string, for storing.
pub fn to_string(document: Document) -> String {
  json.to_string(to_json(document))
}

/// The JSON, with each attachment's `url` for the editor to show it by.
@internal
pub fn to_json_with(
  document: Document,
  url: fn(Attachment) -> Option(String),
) -> Json {
  json.object([
    #("type", json.string("doc")),
    #("content", blocks_json(document.blocks, url)),
  ])
}

// The editor needs at least one block wherever blocks go, and an item that
// starts with a paragraph, so a document built by hand is filled out.
fn blocks_json(
  blocks: List(Block),
  url: fn(Attachment) -> Option(String),
) -> Json {
  case blocks {
    [] -> [Paragraph([])]
    _ -> blocks
  }
  |> json.array(block_json(_, url))
}

fn block_json(block: Block, url: fn(Attachment) -> Option(String)) -> Json {
  case block {
    Paragraph(content) -> node("paragraph", [], inlines_json(content))
    Heading(level, content) ->
      node(
        "heading",
        [#("level", json.int(int.clamp(level, 1, 6)))],
        inlines_json(content),
      )
    Quote(blocks) -> node("blockquote", [], [blocks_json(blocks, url)])
    BulletList(items) -> node("bullet_list", [], [items_json(items, url)])
    NumberedList(start, items) ->
      node("ordered_list", [#("order", json.int(int.max(start, 0)))], [
        items_json(items, url),
      ])
    CodeBlock("") -> node("code_block", [], [])
    CodeBlock(code) ->
      node("code_block", [], [
        json.preprocessed_array([
          json.object([
            #("type", json.string("text")),
            #("text", json.string(code)),
          ]),
        ]),
      ])
    Divider -> node("horizontal_rule", [], [])
    Attached(attachment) -> {
      let link = case url(attachment) {
        Some(url) -> [#("url", json.string(url))]
        None -> []
      }
      node(
        "attachment",
        [
          #("key", json.string(attachment.key)),
          #("name", json.string(attachment.name)),
          #("content_type", json.string(attachment.content_type)),
          #("size", json.int(attachment.size)),
          ..link
        ],
        [],
      )
    }
  }
}

fn items_json(
  items: List(List(Block)),
  url: fn(Attachment) -> Option(String),
) -> Json {
  case items {
    [] -> [[]]
    _ -> items
  }
  |> json.array(fn(item) {
    let item = case item {
      [Paragraph(_), ..] -> item
      _ -> [Paragraph([]), ..item]
    }
    node("list_item", [], [blocks_json(item, url)])
  })
}

fn inlines_json(content: List(Inline)) -> List(Json) {
  case list.filter_map(content, inline_json) {
    [] -> []
    parts -> [json.preprocessed_array(parts)]
  }
}

fn inline_json(inline: Inline) -> Result(Json, Nil) {
  case inline {
    Text("", _) -> Error(Nil)
    Text(text, marks) -> {
      let marks = case list.filter(marks, mark_is_safe) {
        [] -> []
        marks -> [#("marks", json.array(marks, mark_json))]
      }
      Ok(
        json.object([
          #("type", json.string("text")),
          #("text", json.string(text)),
          ..marks
        ]),
      )
    }
    Mentioned(mention) ->
      Ok(
        node(
          "mention",
          [
            #("trigger", json.string(mention.trigger)),
            #("kind", json.string(mention.kind)),
            #("id", json.string(mention.id)),
            #("label", json.string(mention.label)),
          ],
          [],
        ),
      )
    LineBreak -> Ok(node("hard_break", [], []))
  }
}

fn mark_json(mark: Mark) -> Json {
  case mark {
    Bold -> json.object([#("type", json.string("bold"))])
    Italic -> json.object([#("type", json.string("italic"))])
    Strike -> json.object([#("type", json.string("strike"))])
    Code -> json.object([#("type", json.string("code"))])
    Link(href) ->
      json.object([
        #("type", json.string("link")),
        #("attrs", json.object([#("href", json.string(href))])),
      ])
  }
}

fn mark_is_safe(mark: Mark) -> Bool {
  case mark {
    Link(href) -> is_safe_link(href)
    _ -> True
  }
}

// A node with its attributes, if any, and its content: either nothing or
// one array.
fn node(
  kind: String,
  attrs: List(#(String, Json)),
  content: List(Json),
) -> Json {
  let attrs = case attrs {
    [] -> []
    _ -> [#("attrs", json.object(attrs))]
  }
  let content = case content {
    [array] -> [#("content", array)]
    _ -> []
  }
  json.object([#("type", json.string(kind)), ..list.append(attrs, content)])
}

// -- Rendering ---------------------------------------------------------------

/// A document as prose, with mentions as chips and attachments as cards
/// without links. Use `view_with` to link them to your own pages and files.
pub fn view(document: Document) -> Element(msg) {
  view_with(
    document,
    mention: mention_view(_, href: None),
    attachment: fn(file) { attachment_view(file, url: None) },
  )
}

/// A document as prose, drawing each mention and attachment with the
/// functions given, such as from your current records.
pub fn view_with(
  document: Document,
  mention mention: fn(Mention) -> Element(msg),
  attachment attachment: fn(Attachment) -> Element(msg),
) -> Element(msg) {
  html.div(
    [class(typography.prose_class(typography.Base)), class(document_class())],
    elements(document, mention:, attachment:),
  )
}

/// A document's elements, without the prose around them, for a container
/// of your own.
pub fn elements(
  document: Document,
  mention mention: fn(Mention) -> Element(msg),
  attachment attachment: fn(Attachment) -> Element(msg),
) -> List(Element(msg)) {
  let draw = Draw(mention:, attachment:)
  list.map(document.blocks, block_view(_, draw))
}

type Draw(msg) {
  Draw(
    mention: fn(Mention) -> Element(msg),
    attachment: fn(Attachment) -> Element(msg),
  )
}

fn block_view(block: Block, draw: Draw(msg)) -> Element(msg) {
  case block {
    Paragraph(content) -> html.p([], inlines_view(content, draw))
    Heading(level, content) -> {
      let content = inlines_view(content, draw)
      case int.clamp(level, 1, 6) {
        1 -> html.h1([], content)
        2 -> html.h2([], content)
        3 -> html.h3([], content)
        4 -> html.h4([], content)
        5 -> html.h5([], content)
        _ -> html.h6([], content)
      }
    }
    Quote(blocks) -> html.blockquote([], list.map(blocks, block_view(_, draw)))
    BulletList(items) -> html.ul([], items_view(items, draw))
    NumberedList(start, items) -> {
      let start = case start {
        1 -> []
        _ -> [attribute.attribute("start", int.to_string(start))]
      }
      html.ol(start, items_view(items, draw))
    }
    CodeBlock(code) -> html.pre([], [html.code([], [text(code)])])
    Divider -> html.hr([])
    Attached(attachment) -> draw.attachment(attachment)
  }
}

fn items_view(items: List(List(Block)), draw: Draw(msg)) -> List(Element(msg)) {
  list.map(items, fn(item) { html.li([], list.map(item, block_view(_, draw))) })
}

// An empty paragraph keeps its line, as it did in the editor.
fn inlines_view(content: List(Inline), draw: Draw(msg)) -> List(Element(msg)) {
  case list.filter(content, fn(inline) { inline != Text("", []) }) {
    [] -> [html.br([])]
    content -> list.map(content, inline_view(_, draw))
  }
}

fn inline_view(inline: Inline, draw: Draw(msg)) -> Element(msg) {
  case inline {
    Text(content, marks) ->
      marks
      |> list.unique
      |> list.sort(fn(a, b) { int.compare(mark_rank(b), mark_rank(a)) })
      |> list.fold(text(content), fn(inner, mark) { mark_view(mark, inner) })
    Mentioned(mention) -> draw.mention(mention)
    LineBreak -> html.br([])
  }
}

// Links go outermost and code innermost, as the editor draws them.
fn mark_rank(mark: Mark) -> Int {
  case mark {
    Link(_) -> 0
    Bold -> 1
    Italic -> 2
    Strike -> 3
    Code -> 4
  }
}

fn mark_view(mark: Mark, inner: Element(msg)) -> Element(msg) {
  case mark {
    Bold -> html.strong([], [inner])
    Italic -> html.em([], [inner])
    Strike -> html.s([], [inner])
    Code -> html.code([], [inner])
    Link(href) ->
      case is_safe_link(href) {
        True ->
          html.a(
            [
              attribute.href(href),
              attribute.rel("noopener noreferrer nofollow"),
            ],
            [inner],
          )
        False -> inner
      }
  }
}

/// A mention as a chip, such as `@Ada Lovelace`, linking to `href` if
/// given.
pub fn mention_view(
  mention: Mention,
  href href: Option(String),
) -> Element(msg) {
  let attributes = [
    class(mention_class()),
    attribute.data("mention", mention.kind),
    attribute.data("id", mention.id),
  ]
  let content = [text(mention.trigger <> mention.label)]
  case href {
    Some(href) -> html.a([attribute.href(href), ..attributes], content)
    None -> html.span(attributes, content)
  }
}

/// An attachment as a picture, for an image with a `url`, or otherwise as
/// a card with its name and size, which links to the file if there is a
/// `url`.
pub fn attachment_view(
  attachment: Attachment,
  url url: Option(String),
) -> Element(msg) {
  case url, is_image(attachment.content_type) {
    Some(url), True ->
      html.figure([class(figure_class())], [
        html.img([
          attribute.src(url),
          attribute.alt(attachment.name),
          attribute.attribute("loading", "lazy"),
        ]),
      ])
    _, _ -> {
      let file =
        card.attachment(
          // A finished attachment says nothing about uploading.
          words: card.english(),
          name: attachment.name,
          detail: uploader.describe(attachment.name, attachment.size),
          status: card.Done,
          media: None,
          actions: [],
        )
      let content = case url {
        Some(url) ->
          html.a([class(file_link_class()), attribute.href(url)], [file])
        None -> file
      }
      html.figure([class(figure_class())], [content])
    }
  }
}

/// Whether a content type is shown as a picture.
@internal
pub fn is_image(content_type: String) -> Bool {
  list.contains(
    [
      "image/png", "image/jpeg", "image/gif", "image/webp", "image/avif",
      "image/svg+xml",
    ],
    string.lowercase(content_type),
  )
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [document_class(), mention_class(), figure_class(), file_link_class()]
}

/// What a document adds to prose.
pub fn document_class() -> Class {
  css.class([
    css.property("overflow-wrap", "anywhere"),
    css.selector(" s", [css.color(tokens.text_muted)]),
  ])
}

pub fn mention_class() -> Class {
  css.class([
    css.display("inline"),
    css.padding_("0 0.2em"),
    style.radius(tokens.radius_small),
    css.background(tokens.muted),
    css.color(tokens.primary),
    css.font_weight("500"),
    css.text_decoration("none"),
    css.white_space("nowrap"),
    css.property("box-decoration-break", "clone"),
    css.selector("[href]:hover", [css.text_decoration("underline")]),
  ])
}

pub fn figure_class() -> Class {
  css.class([
    css.margin_("1.25em 0 0"),
    css.selector(" img", [
      css.display("block"),
      css.margin(rem(0.0)),
      css.property("max-width", "100%"),
      css.property("height", "auto"),
    ]),
  ])
}

pub fn file_link_class() -> Class {
  css.class([
    css.display("inline-block"),
    css.color("inherit"),
    css.text_decoration("none"),
    style.radius(tokens.radius_medium),
    style.focus_ring(),
  ])
}
