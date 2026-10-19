//// A rich text editor: bold, italic, links, headings, quotes, lists and
//// code, with mentions of people or anything else, and files sent
//// straight to storage, posted as a document your server can trust.
////
//// ```gleam
//// html.form([attribute.method("post"), attribute.action("/posts")], [
////   rich_text.new(name: "body")
////   |> rich_text.value(post.body)
////   |> rich_text.placeholder("Write something…")
////   |> rich_text.mentions(trigger: "@", kind: "person", search: "/people/search")
////   |> rich_text.attachments(start: "/posts/uploads", url: fn(file) {
////     Some(files.url(file.key))
////   })
////   |> rich_text.required
////   |> rich_text.view,
////   ui.submit_button(Primary, [], [text("Post")]),
//// ])
//// ```
////
//// The form posts the document as JSON under `name`. Read it with `field`
//// in a form validator, or `document.decode`, which refuses anything the
//// editor could not have made: decoding is the safety check, and
//// `document.view` draws the result through Lustre, so its text is always
//// escaped. Store it with `document.to_string`.
////
//// Typing a mention's trigger, such as `@`, asks your `search` endpoint
//// for suggestions as the person types: `GET /people/search?q=ad` answers
//// with JSON made by `suggestions_to_json`:
////
//// ```json
//// [{"id": "42", "label": "Ada Lovelace", "detail": "ada@example.com", "image": "/avatars/42.png"}]
//// ```
////
//// The ids come back from the browser, so check each mention with
//// `document.mentions` before acting on it, such as sending a
//// notification. Show mentions from your records as they are now with
//// `document.view_with`.
////
//// Attachments use the same endpoint as `howdy/ui/uploader`: the browser
//// posts each file's name, type and size to `start`, which answers with a
//// key and where to send the file. The document keeps the key. Check each
//// one with `document.attachments` before you keep it.
////
//// The editor runs on ProseMirror, loaded the first time an editor is on
//// a page from the `ui.rich_text()` controller, which every app that uses
//// it must mount; see `howdy/ui/rich_text/script`. It looks like the rest of the theme: the toolbar,
//// menus and text use the same tokens and prose styles. Markdown-like
//// shortcuts work as you type: `#` for a heading, `>` for a quote, `-` or
//// `1.` for a list, three backticks for code, and `**bold**`, `_italic_`,
//// `~~strike~~` and `` `code` ``.
////
//// In a live view, `live.on_value(name, message)` hears the document each
//// time the editor loses focus. Setting a different value from the
//// server, such as clearing it after sending, replaces what is in the
//// editor.

import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import howdy/form.{type Form}
import howdy/ui/attachment as card
import howdy/ui/button
import howdy/ui/command
import howdy/ui/input
import howdy/ui/rich_text/document.{type Attachment, type Document}
import howdy/ui/rich_text/script
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import howdy/ui/tooltip
import howdy/ui/typography
import howdy/ui/uploader
import howdy/validate.{type Rule}
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/element/svg
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// A button on the toolbar.
pub type Tool {
  Bold
  Italic
  Strike
  /// Code within a line.
  Code
  Link
  /// A heading of this level, from 1 to 6. The button turns a paragraph
  /// into the heading, and back.
  Heading(level: Int)
  Quote
  BulletList
  NumberedList
  CodeBlock
  /// A horizontal rule.
  Divider
  /// Choose files to attach. Shown only with `attachments`.
  Attach
  Undo
  Redo
}

/// What the editor says. `heading` may contain `{level}`, and `too_large`
/// `{limit}`.
pub type Words {
  Words(
    toolbar: String,
    bold: String,
    italic: String,
    strike: String,
    code: String,
    link: String,
    heading: String,
    quote: String,
    bullet_list: String,
    numbered_list: String,
    code_block: String,
    divider: String,
    attach: String,
    undo: String,
    redo: String,
    link_address: String,
    link_apply: String,
    link_remove: String,
    bad_link: String,
    no_matches: String,
    remove: String,
    uploading: String,
    too_large: String,
    wrong_type: String,
    failed: String,
    wait: String,
    missing: String,
    unavailable: String,
  )
}

pub fn english() -> Words {
  Words(
    toolbar: "Formatting",
    bold: "Bold",
    italic: "Italic",
    strike: "Strikethrough",
    code: "Code",
    link: "Link",
    heading: "Heading {level}",
    quote: "Quote",
    bullet_list: "Bulleted list",
    numbered_list: "Numbered list",
    code_block: "Code block",
    divider: "Divider",
    attach: "Attach files",
    undo: "Undo",
    redo: "Redo",
    link_address: "Link address",
    link_apply: "Apply",
    link_remove: "Remove link",
    bad_link: "Enter a web address, such as https://example.com.",
    no_matches: "No matches",
    remove: "Remove",
    uploading: "Uploading",
    too_large: "Too large: the limit is {limit}.",
    wrong_type: "This type of file is not accepted.",
    failed: "The file could not be uploaded.",
    wait: "Wait for the files to finish uploading.",
    missing: "Write something.",
    unavailable: "The editor could not load. Reload the page to try again.",
  )
}

type Source {
  Source(trigger: String, kind: String, search: String)
}

type Uploads {
  Uploads(
    start: String,
    url: fn(Attachment) -> Option(String),
    accept: List(String),
    max_size: Option(Int),
  )
}

/// An editor under construction.
pub opaque type Editor {
  Editor(
    name: String,
    value: Document,
    id: Option(String),
    placeholder: String,
    tools: Option(List(List(Tool))),
    sources: List(Source),
    uploads: Option(Uploads),
    required: Bool,
    disabled: Bool,
    invalid: Bool,
    words: Words,
  )
}

/// An empty editor posting its document as `name`.
pub fn new(name name: String) -> Editor {
  Editor(
    name:,
    value: document.empty(),
    id: None,
    placeholder: "",
    tools: None,
    sources: [],
    uploads: None,
    required: False,
    disabled: False,
    invalid: False,
    words: english(),
  )
}

/// The document to start with.
pub fn value(editor: Editor, value: Document) -> Editor {
  Editor(..editor, value:)
}

/// Shown, faintly, while the editor is empty.
pub fn placeholder(editor: Editor, text: String) -> Editor {
  Editor(..editor, placeholder: text)
}

/// The toolbar's buttons, in groups with a line between each. The default
/// is `default_tools()`, with `Attach` when there are `attachments`. An
/// empty list hides the toolbar; the keyboard shortcuts still work.
pub fn tools(editor: Editor, groups: List(List(Tool))) -> Editor {
  Editor(..editor, tools: Some(groups))
}

/// The toolbar an editor has unless given `tools`.
pub fn default_tools() -> List(List(Tool)) {
  [
    [Bold, Italic, Strike, Code, Link],
    [Heading(2), Heading(3), Quote, CodeBlock],
    [BulletList, NumberedList],
    [Attach],
    [Undo, Redo],
  ]
}

/// Typing `trigger`, such as `"@"` or `"#"`, suggests things of `kind` to
/// mention, from the endpoint at `search`. It is sent what follows the
/// trigger as `?q=` and answers with `suggestions_to_json`. Call this once
/// for each trigger.
pub fn mentions(
  editor: Editor,
  trigger trigger: String,
  kind kind: String,
  search search: String,
) -> Editor {
  let sources =
    list.filter(editor.sources, fn(source) { source.trigger != trigger })
  Editor(
    ..editor,
    sources: list.append(sources, [Source(trigger:, kind:, search:)]),
  )
}

/// Let people attach files, by the toolbar, pasting or dropping them. The
/// browser asks the endpoint at `start` where to send each one, as
/// `howdy/ui/uploader` does. `url` gives the address to show an attached
/// file by, such as a signed storage URL, or `None` to show only its name.
pub fn attachments(
  editor: Editor,
  start start: String,
  url url: fn(Attachment) -> Option(String),
) -> Editor {
  let uploads = case editor.uploads {
    Some(uploads) -> Uploads(..uploads, start:, url:)
    None -> Uploads(start:, url:, accept: [], max_size: None)
  }
  Editor(..editor, uploads: Some(uploads))
}

/// Only attach files of these types: content types such as
/// `"image/png"`, families such as `"image/*"`, or extensions such as
/// `".pdf"`. Use with `attachments`.
pub fn accept(editor: Editor, types: List(String)) -> Editor {
  update_uploads(editor, fn(uploads) { Uploads(..uploads, accept: types) })
}

/// Refuse attachments over this many bytes before they are sent. Your
/// `start` endpoint must check too. Use with `attachments`.
pub fn max_size(editor: Editor, bytes: Int) -> Editor {
  update_uploads(editor, fn(uploads) {
    Uploads(..uploads, max_size: Some(bytes))
  })
}

fn update_uploads(editor: Editor, update: fn(Uploads) -> Uploads) -> Editor {
  case editor.uploads {
    Some(uploads) -> Editor(..editor, uploads: Some(update(uploads)))
    None -> editor
  }
}

/// Do not let the form submit while the editor is empty.
pub fn required(editor: Editor) -> Editor {
  Editor(..editor, required: True)
}

/// Show the document without letting it be edited. Nothing is posted.
pub fn disabled(editor: Editor) -> Editor {
  Editor(..editor, disabled: True)
}

/// Mark the editor as holding a value that was refused, such as when its
/// field has an error.
pub fn invalid(editor: Editor) -> Editor {
  Editor(..editor, invalid: True)
}

/// An id for a `<label for>`, such as a field's. Clicking the label
/// focuses the editor, and the label names it. Without one, the id is
/// made from the name.
pub fn id(editor: Editor, id: String) -> Editor {
  Editor(..editor, id: Some(id))
}

/// Say things in other words, or another language.
pub fn words(editor: Editor, words: Words) -> Editor {
  Editor(..editor, words:)
}

// -- Reading what was posted -------------------------------------------------

/// A required rich text field of a form, checked with `rules`. A value
/// that is missing or is not a document the editor could have made is an
/// error, so `rules` only see real documents.
///
/// ```gleam
/// use body <- rich_text.field(fields, "body", [rich_text.not_empty()])
/// ```
pub fn field(
  form: Form,
  name: String,
  rules: List(Rule(Document)),
  next: fn(Document) -> validate.Result(b),
) -> validate.Result(b) {
  case form.get(form, name) {
    Ok(value) ->
      case document.decode(value) {
        Ok(value) -> validate.field(name, value, rules, next)
        Error(_) -> refuse(name, "is not valid rich text", next)
      }
    Error(Nil) -> refuse(name, "is required", next)
  }
}

fn refuse(
  name: String,
  message: String,
  next: fn(Document) -> validate.Result(b),
) -> validate.Result(b) {
  validate.field(name, document.empty(), [fn(_) { Error(message) }], next)
}

/// Refuse a document with no text, mentions, attachments or dividers.
pub fn not_empty() -> Rule(Document) {
  validate.custom(fn(value) { !document.is_empty(value) }, "must not be empty")
}

/// Refuse a document whose plain text is longer than this many characters.
pub fn max_length(length: Int) -> Rule(Document) {
  validate.custom(
    fn(value) { string.length(document.to_plain_text(value)) <= length },
    "must be at most " <> int.to_string(length) <> " characters",
  )
}

// -- Answering searches ------------------------------------------------------

/// Something a mention search found. `label` is what the mention shows
/// after its trigger; `detail`, such as an email address, and `image`,
/// such as an avatar, appear in the list only.
pub type Suggestion {
  Suggestion(
    id: String,
    label: String,
    detail: Option(String),
    image: Option(String),
  )
}

/// A suggestion with an id and a label alone.
pub fn suggestion(id id: String, label label: String) -> Suggestion {
  Suggestion(id:, label:, detail: None, image: None)
}

/// The answer to a mention search, as the editor expects it. Send at most
/// ten or so, the best first.
pub fn suggestions_to_json(suggestions: List(Suggestion)) -> Json {
  json.array(suggestions, fn(suggestion) {
    json.object([
      #("id", json.string(suggestion.id)),
      #("label", json.string(suggestion.label)),
      #("detail", json.nullable(suggestion.detail, json.string)),
      #("image", json.nullable(suggestion.image, json.string)),
    ])
  })
}

// -- Drawing -----------------------------------------------------------------

/// The editor, with its toolbar.
pub fn view(editor: Editor) -> Element(msg) {
  let words = editor.words
  let id = case editor.id {
    Some(id) -> id
    None -> "rich-text-" <> slug(editor.name)
  }
  let groups =
    editor.tools
    |> option.unwrap(default_tools())
    |> list.map(
      list.filter(_, fn(tool) {
        tool != Attach || option.is_some(editor.uploads)
      }),
    )
    |> list.filter(fn(group) { group != [] })
  let url = case editor.uploads {
    Some(uploads) -> uploads.url
    None -> fn(_) { None }
  }
  let empty = document.is_empty(editor.value)
  let flags =
    list.flatten([
      on(editor.disabled, attribute.data("disabled", "")),
      on(editor.invalid, attribute.data("invalid", "")),
      on(editor.required, attribute.data("required", "")),
      upload_attributes(editor),
    ])
  element.element(
    "howdy-rich-text",
    [
      class(editor_class()),
      attribute.data("script", script.url()),
      attribute.data("placeholder", editor.placeholder),
      attribute.data(
        "mentions",
        json.to_string(
          json.array(editor.sources, fn(source) {
            json.object([
              #("trigger", json.string(source.trigger)),
              #("kind", json.string(source.kind)),
              #("search", json.string(source.search)),
            ])
          }),
        ),
      ),
      attribute.data("text-bad-link", words.bad_link),
      attribute.data("text-uploading", words.uploading),
      attribute.data("text-wrong-type", words.wrong_type),
      attribute.data("text-failed", words.failed),
      attribute.data("text-wait", words.wait),
      attribute.data("text-missing", words.missing),
      attribute.data("text-remove", words.remove),
      ..flags
    ],
    [
      case groups {
        [] -> element.none()
        _ -> toolbar(id, groups, editor)
      },
      // What the server drew, until the editor takes its place.
      html.div(
        [
          class(typography.prose_class(typography.Base)),
          class(document.document_class()),
          class(content_class()),
          attribute.data("howdy-rich-text-preview", ""),
        ],
        preview(editor, url, empty),
      ),
      // The editor goes in here. It stays empty as far as Lustre knows, so
      // a live view's patches never reach the editor's own elements.
      html.div(
        [
          class(typography.prose_class(typography.Base)),
          class(document.document_class()),
          class(content_class()),
          attribute.data("howdy-rich-text-mount", ""),
        ],
        [],
      ),
      html.div(
        [
          class(unavailable_class()),
          attribute.role("alert"),
          attribute.data("howdy-rich-text-failed", ""),
        ],
        [text(words.unavailable)],
      ),
      html.input([
        attribute.type_("hidden"),
        attribute.name(editor.name),
        attribute.value(
          json.to_string(document.to_json_with(editor.value, url)),
        ),
        attribute.disabled(editor.disabled),
        attribute.data("howdy-rich-text-value", ""),
      ]),
      // Something for a label to point at, and for the browser to check
      // when the editor is required. Focusing it focuses the editor.
      html.input([
        class(uploader.input_class()),
        attribute.id(id),
        attribute.type_("text"),
        attribute.tabindex(-1),
        attribute.autocomplete("off"),
        attribute.aria_hidden(True),
        attribute.required(editor.required && !editor.disabled),
        attribute.disabled(editor.disabled),
        attribute.data("howdy-rich-text-proxy", ""),
        ..on(!empty, attribute.value("filled"))
      ]),
      mention_menu(id, words),
      link_form(id, words),
      templates(),
      case editor.uploads {
        Some(uploads) ->
          html.input([
            attribute.type_("file"),
            attribute.multiple(True),
            attribute.hidden(True),
            attribute.tabindex(-1),
            attribute.data("howdy-rich-text-files", ""),
            ..case uploads.accept {
              [] -> []
              types -> [attribute.accept(types)]
            }
          ])
        None -> element.none()
      },
    ],
  )
}

fn on(condition: Bool, attribute: Attribute(msg)) -> List(Attribute(msg)) {
  case condition {
    True -> [attribute]
    False -> []
  }
}

fn upload_attributes(editor: Editor) -> List(Attribute(msg)) {
  case editor.uploads {
    Some(uploads) -> [
      attribute.data("upload-start", uploads.start),
      attribute.data("text-too-large", case uploads.max_size {
        Some(bytes) ->
          string.replace(
            editor.words.too_large,
            "{limit}",
            uploader.file_size(bytes),
          )
        None -> editor.words.too_large
      }),
      ..case uploads.max_size {
        Some(bytes) -> [attribute.data("max-size", int.to_string(bytes))]
        None -> []
      }
    ]
    None -> []
  }
}

fn slug(name: String) -> String {
  name
  |> string.to_graphemes
  |> list.map(fn(char) {
    case string.contains("abcdefghijklmnopqrstuvwxyz0123456789-_", char) {
      True -> char
      False ->
        case string.lowercase(char) == char {
          True -> "-"
          False -> string.lowercase(char)
        }
    }
  })
  |> string.concat
}

fn preview(
  editor: Editor,
  url: fn(Attachment) -> Option(String),
  empty: Bool,
) -> List(Element(msg)) {
  case empty, editor.value.blocks {
    True, [] | True, [document.Paragraph(_)] -> [
      html.p(
        case editor.placeholder {
          "" -> []
          placeholder -> [attribute.data("placeholder", placeholder)]
        },
        [html.br([])],
      ),
    ]
    _, _ ->
      document.elements(
        editor.value,
        mention: document.mention_view(_, href: None),
        attachment: fn(file) { document.attachment_view(file, url: url(file)) },
      )
  }
}

fn toolbar(
  id: String,
  groups: List(List(Tool)),
  editor: Editor,
) -> Element(msg) {
  let words = editor.words
  let buttons =
    groups
    |> list.index_map(fn(group, index) {
      list.map(group, fn(tool) { #(index, tool) })
    })
    |> list.flatten
  html.div(
    [
      class(toolbar_class()),
      attribute.role("toolbar"),
      attribute.aria_label(words.toolbar),
      attribute.aria_controls(id),
      attribute.data("howdy-rich-text-toolbar", ""),
    ],
    list.index_map(buttons, fn(entry, index) {
      let #(group, tool) = entry
      let separator = case
        index > 0 && group != previous_group(buttons, index)
      {
        True -> [
          html.span([class(separator_class()), attribute.aria_hidden(True)], []),
        ]
        False -> []
      }
      let tip = id <> "-tool-" <> int.to_string(index)
      let label = tool_label(tool, words)
      let pressable = case tool {
        Bold
        | Italic
        | Strike
        | Code
        | Link
        | Heading(_)
        | Quote
        | BulletList
        | NumberedList
        | CodeBlock -> [attribute.aria_pressed("false")]
        Divider | Attach | Undo | Redo -> []
      }
      element.fragment(
        list.append(separator, [
          html.button(
            [
              class(tool_class()),
              attribute.type_("button"),
              attribute.aria_label(label),
              attribute.data("command", tool_command(tool)),
              attribute.tabindex(case index {
                0 -> 0
                _ -> -1
              }),
              attribute.disabled(editor.disabled),
              ..list.append(pressable, tooltip.trigger(tip))
            ],
            [tool_icon(tool)],
          ),
          tooltip.tooltip(tip, [text(label)]),
        ]),
      )
    }),
  )
}

fn previous_group(buttons: List(#(Int, Tool)), index: Int) -> Int {
  case list.drop(buttons, index - 1) {
    [#(group, _), ..] -> group
    [] -> -1
  }
}

fn tool_label(tool: Tool, words: Words) -> String {
  case tool {
    Bold -> words.bold
    Italic -> words.italic
    Strike -> words.strike
    Code -> words.code
    Link -> words.link
    Heading(level) ->
      string.replace(words.heading, "{level}", int.to_string(level))
    Quote -> words.quote
    BulletList -> words.bullet_list
    NumberedList -> words.numbered_list
    CodeBlock -> words.code_block
    Divider -> words.divider
    Attach -> words.attach
    Undo -> words.undo
    Redo -> words.redo
  }
}

fn tool_command(tool: Tool) -> String {
  case tool {
    Bold -> "bold"
    Italic -> "italic"
    Strike -> "strike"
    Code -> "code"
    Link -> "link"
    Heading(level) -> "heading-" <> int.to_string(int.clamp(level, 1, 6))
    Quote -> "quote"
    BulletList -> "bullet-list"
    NumberedList -> "numbered-list"
    CodeBlock -> "code-block"
    Divider -> "divider"
    Attach -> "attach"
    Undo -> "undo"
    Redo -> "redo"
  }
}

// Icons drawn on a 24 unit grid with the current colour, so they follow
// the theme.
fn tool_icon(tool: Tool) -> Element(msg) {
  case tool {
    Heading(level) ->
      html.span([class(heading_icon_class())], [
        text("H" <> int.to_string(int.clamp(level, 1, 6))),
      ])
    _ -> icon(tool_paths(tool))
  }
}

fn tool_paths(tool: Tool) -> List(String) {
  case tool {
    Bold -> ["M7 5h6a3.5 3.5 0 0 1 0 7H7z", "M7 12h7a3.5 3.5 0 0 1 0 7H7z"]
    Italic -> ["M19 4h-9", "M14 20H5", "M15 4 9 20"]
    Strike -> [
      "M16 6.5C15.2 5 13.8 4 12 4 9.5 4 8 5.4 8 7.2c0 1.2.6 2 1.7 2.6",
      "M4 12h16",
      "M15.5 14.5c.4.5.5 1 .5 1.6 0 2.2-1.8 3.9-4.4 3.9-2 0-3.6-.9-4.4-2.5",
    ]
    Code -> ["m9 7-5 5 5 5", "m15 7 5 5-5 5"]
    Link -> [
      "M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1",
      "M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1",
    ]
    Quote -> ["M5 7h5v5c0 2.5-1.2 4-4 5", "M14 7h5v5c0 2.5-1.2 4-4 5"]
    BulletList -> [
      "M10 6h10", "M10 12h10", "M10 18h10", "M4.5 6h.01", "M4.5 12h.01",
      "M4.5 18h.01",
    ]
    NumberedList -> [
      "M10 6h10", "M10 12h10", "M10 18h10", "M4 4h1.5v4", "M4 8h3",
      "M4 14.5c0-1 .7-1.5 1.5-1.5S7 13.5 7 14.3c0 1.2-3 2-3 3.7h3",
    ]
    CodeBlock -> [
      "M5 4h14v16H5z",
      "m10 9.5-2.5 2.5 2.5 2.5",
      "m14 9.5 2.5 2.5-2.5 2.5",
    ]
    Divider -> ["M3 12h18", "M8 7h8", "M8 17h8"]
    Attach -> [
      "m20 11.5-8 8a5 5 0 0 1-7-7l8.5-8.5a3.3 3.3 0 0 1 4.7 4.7L9.7 17a1.7 1.7 0 0 1-2.4-2.4l7.4-7.4",
    ]
    Undo -> ["M9 14 4 9l5-5", "M4 9h10.5a5.5 5.5 0 0 1 0 11H11"]
    Redo -> ["m15 14 5-5-5-5", "M20 9H9.5a5.5 5.5 0 0 0 0 11H13"]
    Heading(_) -> []
  }
}

fn icon(paths: List(String)) -> Element(msg) {
  svg.svg(
    [
      attribute.attribute("viewBox", "0 0 24 24"),
      attribute.attribute("width", "16"),
      attribute.attribute("height", "16"),
      attribute.attribute("fill", "none"),
      attribute.attribute("stroke", "currentColor"),
      attribute.attribute("stroke-width", "2"),
      attribute.attribute("stroke-linecap", "round"),
      attribute.attribute("stroke-linejoin", "round"),
      attribute.aria_hidden(True),
    ],
    list.map(paths, fn(d) { svg.path([attribute.attribute("d", d)]) }),
  )
}

fn mention_menu(id: String, words: Words) -> Element(msg) {
  html.div(
    [
      class(menu_class()),
      attribute.id(id <> "-mentions"),
      attribute.popover("manual"),
      attribute.role("listbox"),
      attribute.data("howdy-rich-text-menu", ""),
    ],
    [
      // The editor puts the suggestions in here.
      html.div([attribute.data("howdy-rich-text-options", "")], []),
      html.div(
        [
          class(command.empty_class()),
          attribute.hidden(True),
          attribute.data("howdy-rich-text-empty", ""),
        ],
        [text(words.no_matches)],
      ),
    ],
  )
}

fn link_form(id: String, words: Words) -> Element(msg) {
  html.div(
    [
      class(link_form_class()),
      attribute.id(id <> "-link"),
      attribute.popover("auto"),
      attribute.data("howdy-rich-text-link", ""),
    ],
    [
      html.input([
        class(input.input_class()),
        class(link_input_class()),
        attribute.type_("url"),
        attribute.placeholder("https://"),
        attribute.aria_label(words.link_address),
        attribute.autocomplete("off"),
        attribute.data("howdy-rich-text-link-input", ""),
      ]),
      button.sized(
        button.Primary,
        button.Small,
        [attribute.data("howdy-rich-text-link-apply", "")],
        [text(words.link_apply)],
      ),
      button.sized(
        button.Ghost,
        button.Small,
        [attribute.data("howdy-rich-text-link-remove", "")],
        [text(words.link_remove)],
      ),
    ],
  )
}

// Elements the editor copies, so what it adds is styled by the theme too.
fn templates() -> Element(msg) {
  element.fragment([
    html.template([attribute.data("howdy-rich-text-option", "")], [
      html.div([class(command.item_class()), attribute.role("option")], [
        html.span([class(option_avatar_class()), attribute.aria_hidden(True)], [
          html.img([attribute.alt(""), attribute.hidden(True)]),
        ]),
        html.span([class(option_label_class())], []),
        html.span([class(option_detail_class())], []),
      ]),
    ]),
    html.template([attribute.data("howdy-rich-text-mention", "")], [
      html.span([class(document.mention_class())], []),
    ]),
    html.template([attribute.data("howdy-rich-text-attachment", "")], [
      html.figure([class(document.figure_class()), class(attached_class())], [
        html.img([attribute.alt(""), attribute.data("part", "image")]),
        html.div(
          [
            class(card.attachment_class(card.Row)),
            attribute.data("part", "card"),
          ],
          [
            html.span(
              [
                class(card.icon_class(card.Row)),
                attribute.aria_hidden(True),
                attribute.data("part", "icon"),
              ],
              [],
            ),
            html.div([class(card.text_class())], [
              html.div(
                [class(card.name_class()), attribute.data("part", "name")],
                [],
              ),
              html.div(
                [class(card.detail_class()), attribute.data("part", "detail")],
                [],
              ),
              html.div(
                [
                  class(card.track_class()),
                  attribute.role("progressbar"),
                  attribute.attribute("aria-valuemin", "0"),
                  attribute.attribute("aria-valuemax", "100"),
                  attribute.data("part", "progress"),
                ],
                [html.div([class(card.bar_class())], [])],
              ),
              html.div(
                [
                  class(card.failed_class()),
                  attribute.role("alert"),
                  attribute.data("part", "error"),
                ],
                [],
              ),
            ]),
            html.div([class(card.actions_class(card.Row))], [
              button.sized(
                button.Ghost,
                button.IconSmall,
                [attribute.data("part", "remove")],
                [text("×")],
              ),
            ]),
          ],
        ),
      ]),
    ]),
  ])
}

// -- Styles ------------------------------------------------------------------

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    editor_class(),
    toolbar_class(),
    separator_class(),
    tool_class(),
    heading_icon_class(),
    content_class(),
    unavailable_class(),
    menu_class(),
    option_avatar_class(),
    option_label_class(),
    option_detail_class(),
    link_form_class(),
    link_input_class(),
    attached_class(),
  ]
}

/// The frame, drawn like a text area.
pub fn editor_class() -> Class {
  css.class([
    css.position("relative"),
    css.display("block"),
    css.width(length.percent(100)),
    css.background(tokens.surface),
    css.color(tokens.text),
    style.bordered(),
    style.radius(tokens.radius_medium),
    css.font_family(tokens.font_body),
    css.selector(":focus-within:has([contenteditable]:focus-visible)", [
      style.focus_outline(),
      css.property("outline-offset", "2px"),
    ]),
    css.selector("[data-invalid]", [css.property("border-color", tokens.danger)]),
    css.selector(":has(:user-invalid)", [
      css.property("border-color", tokens.danger),
    ]),
    css.selector("[data-disabled]", [css.property("opacity", "0.6")]),
    // The server's drawing until the editor is ready, then the editor.
    css.selector("[data-ready] [data-howdy-rich-text-preview]", [
      css.display("none"),
    ]),
    css.selector(":not([data-ready]) [data-howdy-rich-text-mount]", [
      css.display("none"),
    ]),
    css.selector(":not([data-failed]) [data-howdy-rich-text-failed]", [
      css.display("none"),
    ]),
  ])
}

pub fn toolbar_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_wrap("wrap"),
    css.align_items("center"),
    css.gap(rem(0.125)),
    css.padding(rem(0.25)),
    style.bordered_side("bottom"),
  ])
}

pub fn separator_class() -> Class {
  css.class([
    css.property("align-self", "stretch"),
    css.width(length.px(1)),
    css.margin_("0.25rem 0.25rem"),
    css.background(tokens.border),
  ])
}

pub fn tool_class() -> Class {
  css.class([
    css.display("inline-flex"),
    css.align_items("center"),
    css.justify_content("center"),
    css.property("min-width", "2rem"),
    css.property("height", "2rem"),
    css.padding_("0 " <> tokens.space_1),
    css.border("1px solid transparent"),
    style.radius(tokens.radius_small),
    css.background("transparent"),
    css.color(tokens.text_muted),
    css.font_family(tokens.font_body),
    css.cursor("pointer"),
    css.hover([css.background(tokens.muted), css.color(tokens.text)]),
    css.selector("[aria-pressed=\"true\"]", [
      css.background(tokens.muted),
      css.color(tokens.text),
      css.property("border-color", tokens.border),
    ]),
    style.focus_ring(),
    style.disabled_look_with(cursor: "default"),
  ])
}

pub fn heading_icon_class() -> Class {
  css.class([
    css.font_size(rem(0.8125)),
    css.font_weight("600"),
    css.line_height("1"),
  ])
}

/// The text, set as prose, whether drawn by the server or the editor.
pub fn content_class() -> Class {
  css.class([
    css.property("max-width", "none"),
    // The same box for the server's drawing and the editor, so nothing
    // moves when the editor takes over.
    css.property("box-sizing", "content-box"),
    css.property("min-height", "6rem"),
    css.padding_(tokens.space_3 <> " " <> tokens.space_4),
    css.cursor("text"),
    css.selector(" [contenteditable]", [
      css.outline("none"),
      css.white_space("pre-wrap"),
      css.property("word-wrap", "break-word"),
      css.property("font-variant-ligatures", "none"),
      css.property("font-feature-settings", "\"liga\" 0"),
      css.position("relative"),
    ]),
    css.selector(" [contenteditable] > :first-child", [
      css.property("margin-top", "0"),
    ]),
    css.selector(" [contenteditable] pre", [css.white_space("pre-wrap")]),
    css.selector(" li", [css.position("relative")]),
    css.selector(" [data-howdy-link-pending]", [
      css.background(tokens.muted),
      css.property("box-shadow", "0 0 0 1px " <> tokens.border),
      style.radius(tokens.radius_small),
    ]),
    css.selector(" [data-placeholder]::before", [
      css.content("attr(data-placeholder)"),
      css.property("float", "inline-start"),
      css.height(rem(0.0)),
      css.color(tokens.text_muted),
      css.property("pointer-events", "none"),
    ]),
    css.selector(" .ProseMirror-selectednode", [
      css.property("outline", "2px solid " <> tokens.focus),
      css.property("outline-offset", "2px"),
    ]),
    css.selector(" .ProseMirror-hideselection *::selection", [
      css.background("transparent"),
    ]),
    css.selector(" .ProseMirror-hideselection", [
      css.property("caret-color", "transparent"),
    ]),
    css.selector(" img.ProseMirror-separator", [
      css.property("display", "inline !important"),
      css.property("border", "none !important"),
      css.property("margin", "0 !important"),
    ]),
    css.selector(" .ProseMirror-gapcursor", [
      css.display("none"),
      css.property("pointer-events", "none"),
      css.position("absolute"),
    ]),
    css.selector(" .ProseMirror-gapcursor::after", [
      css.content("\"\""),
      css.display("block"),
      css.position("absolute"),
      css.top(length.px(-2)),
      css.width(length.px(20)),
      css.property("border-top", "1px solid " <> tokens.text),
    ]),
    css.selector(" .ProseMirror-focused .ProseMirror-gapcursor", [
      css.display("block"),
    ]),
    css.selector(" .ProseMirror-focused", [css.outline("none")]),
  ])
}

pub fn unavailable_class() -> Class {
  css.class([
    css.padding_(tokens.space_2 <> " " <> tokens.space_4),
    style.bordered_side("top"),
    css.color(tokens.danger),
    css.font_size(rem(0.875)),
  ])
}

/// The list of suggestions, placed under the text being typed.
pub fn menu_class() -> Class {
  css.class([
    css.inset("auto"),
    css.margin(rem(0.0)),
    css.property("min-width", "14rem"),
    css.property("max-width", "min(22rem, calc(100vw - 1rem))"),
    css.property("max-height", "18rem"),
    css.overflow_y("auto"),
    css.padding(rem(0.25)),
    css.background(tokens.surface),
    css.color(tokens.text),
    style.bordered(),
    style.radius(tokens.radius_medium),
    css.box_shadow("0 10px 30px -10px rgb(0 0 0 / 0.3)"),
    // The active suggestion is marked by its background; a tick would say
    // it had been chosen.
    css.selector(" [role=option][aria-selected]::after", [css.display("none")]),
    css.selector(" [role=option]", [
      css.property("padding-inline-end", "0.5rem"),
    ]),
  ])
}

pub fn option_avatar_class() -> Class {
  css.class([
    css.position("relative"),
    css.display("inline-flex"),
    css.align_items("center"),
    css.justify_content("center"),
    css.flex_shrink(0.0),
    css.property("width", "1.5rem"),
    css.property("height", "1.5rem"),
    css.overflow("hidden"),
    style.pill(),
    css.background(tokens.muted),
    css.color(tokens.text_muted),
    css.font_size(rem(0.625)),
    css.font_weight("600"),
    css.selector(" img", [
      css.position("absolute"),
      css.inset("0"),
      css.width(length.percent(100)),
      css.height(length.percent(100)),
      css.property("object-fit", "cover"),
    ]),
    css.selector(" img[hidden]", [css.display("none")]),
  ])
}

pub fn option_label_class() -> Class {
  css.class([
    css.overflow("hidden"),
    css.property("text-overflow", "ellipsis"),
    css.white_space("nowrap"),
  ])
}

pub fn option_detail_class() -> Class {
  css.class([
    css.property("margin-inline-start", "auto"),
    css.padding_("0 0 0 " <> tokens.space_2),
    css.overflow("hidden"),
    css.property("text-overflow", "ellipsis"),
    css.white_space("nowrap"),
    css.color(tokens.text_muted),
    css.font_size(rem(0.75)),
  ])
}

pub fn link_form_class() -> Class {
  css.class([
    css.inset("auto"),
    css.margin(rem(0.0)),
    css.display("flex"),
    css.align_items("center"),
    css.gap(rem(0.375)),
    css.width(rem(24.0)),
    css.property("max-width", "calc(100vw - 1rem)"),
    css.padding(rem(0.375)),
    css.background(tokens.surface),
    css.color(tokens.text),
    style.bordered(),
    style.radius(tokens.radius_medium),
    css.box_shadow("0 10px 30px -10px rgb(0 0 0 / 0.3)"),
    css.selector(":not(:popover-open)", [css.display("none")]),
    css.selector(" [hidden]", [css.display("none")]),
  ])
}

pub fn link_input_class() -> Class {
  css.class([
    css.flex("1"),
    css.property("min-width", "0"),
    css.padding_(tokens.space_1 <> " " <> tokens.space_2),
    css.font_size(rem(0.875)),
  ])
}

/// A file in the editor: a picture, or a card while it uploads and for
/// other files.
pub fn attached_class() -> Class {
  css.class([
    css.position("relative"),
    css.property("width", "fit-content"),
    css.property("max-width", "100%"),
    css.property("user-select", "none"),
    css.selector(" img", [style.radius(tokens.radius_medium)]),
    css.selector(" [hidden]", [css.property("display", "none !important")]),
    css.selector("[data-uploading] img", [css.property("opacity", "0.6")]),
    css.selector(" img + div", [css.margin_(tokens.space_2 <> " 0 0")]),
  ])
}
