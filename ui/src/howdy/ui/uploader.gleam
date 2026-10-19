//// An uploader: a place to drop or choose files, which the browser sends
//// straight to storage, showing each as an attachment with its progress.
////
//// ```gleam
//// html.form([attribute.method("post"), attribute.action("/profile")], [
////   uploader.new(name: "avatar", start: "/profile/uploads")
////   |> uploader.accept(["image/png", "image/jpeg"])
////   |> uploader.max_size(5_000_000)
////   |> uploader.layout(attachment.Tile)
////   |> uploader.view,
////   ui.submit_button(Primary, [], [text("Save")]),
//// ])
//// ```
////
//// For each file the browser asks your app for somewhere to put it, sends
//// it there, and once it has arrived adds a hidden input named `name`
//// holding its key. The form then posts the keys, not the files. While a
//// file is still on its way the form will not submit.
////
//// `start` is an endpoint of your own that the browser posts
//// `{"name": "cat.png", "type": "image/png", "size": 48213}` to, as JSON.
//// It checks the type and size, chooses a key and answers with where to
//// send the file:
////
//// ```json
//// {"key": "avatars/42/k3j…/cat.png",
////  "upload": {"url": "https://…", "method": "PUT", "headers": {"content-type": "image/png"}}}
//// ```
////
//// With `howdy_storage` that is `storage.upload_url` and
//// `storage.direct_upload_to_json`; see its direct uploads guide. An error
//// response from `howdy/service` is shown on the file, using the message of
//// its first field if it has one.
////
//// The keys come back from the browser, so check each one before you use
//// it: that it is one your app handed to this user, and that the object
//// exists.
////
//// The sending is done by `howdy/ui/behaviour`, which every page includes.
//// In a live view, `live.on_values(name, message)` hears the keys each time
//// a file arrives or is removed.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import howdy/ui/attachment.{type Layout, Row}
import howdy/ui/button
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// A file stored before the page was drawn, such as the current avatar,
/// shown as already uploaded. Its key is posted with the others unless it
/// is removed.
pub type Stored {
  Stored(key: String, name: String, size: Int, thumbnail: Option(String))
}

/// What the uploader says. `too_large` may contain `{limit}`, and
/// `too_many` `{count}`, for the limit.
pub type Words {
  Words(
    prompt: String,
    remove: String,
    retry: String,
    uploading: String,
    too_large: String,
    wrong_type: String,
    too_many: String,
    failed: String,
    wait: String,
    missing: String,
  )
}

pub fn english() -> Words {
  Words(
    prompt: "Drop files here, or click to choose",
    remove: "Remove",
    retry: "Try again",
    uploading: "Uploading",
    too_large: "Too large: the limit is {limit}.",
    wrong_type: "This type of file is not accepted.",
    too_many: "Too many files: the limit is {count}.",
    failed: "The file could not be uploaded.",
    wait: "Wait for the files to finish uploading.",
    missing: "Choose a file.",
  )
}

/// An uploader under construction.
pub opaque type Uploader {
  Uploader(
    name: String,
    start: String,
    id: Option(String),
    accept: List(String),
    max_size: Option(Int),
    max_files: Int,
    required: Bool,
    layout: Layout,
    stored: List(Stored),
    words: Words,
  )
}

/// An uploader for one file, posting its key as `name`, that asks the
/// endpoint at `start` where to send each file.
pub fn new(name name: String, start start: String) -> Uploader {
  Uploader(
    name:,
    start:,
    id: None,
    accept: [],
    max_size: None,
    max_files: 1,
    required: False,
    layout: Row,
    stored: [],
    words: english(),
  )
}

/// Take up to `max_files` files. Without this, a new file replaces the one
/// there.
pub fn multiple(uploader: Uploader, max_files max_files: Int) -> Uploader {
  Uploader(..uploader, max_files: int.max(max_files, 1))
}

/// Only take files of these types: content types such as `"image/png"`,
/// families such as `"image/*"`, or extensions such as `".pdf"`, as in the
/// `accept` attribute. The file chooser offers only these, and other files
/// are refused before they are sent.
pub fn accept(uploader: Uploader, types: List(String)) -> Uploader {
  Uploader(..uploader, accept: types)
}

/// Refuse files over this many bytes before they are sent. Your `start`
/// endpoint must check too: this only saves a wasted request.
pub fn max_size(uploader: Uploader, bytes: Int) -> Uploader {
  Uploader(..uploader, max_size: Some(bytes))
}

/// Do not let the form submit without a file.
pub fn required(uploader: Uploader) -> Uploader {
  Uploader(..uploader, required: True)
}

/// Show files as rows, compact rows or tiles. Tiles suit images, which
/// are shown as thumbnails while they upload.
pub fn layout(uploader: Uploader, layout: Layout) -> Uploader {
  Uploader(..uploader, layout:)
}

/// Files already stored, shown first.
pub fn stored(uploader: Uploader, files: List(Stored)) -> Uploader {
  Uploader(..uploader, stored: files)
}

/// The id of the file input, for a `<label for>` such as a field's.
pub fn id(uploader: Uploader, id: String) -> Uploader {
  Uploader(..uploader, id: Some(id))
}

/// Say things in other words, or another language.
pub fn words(uploader: Uploader, words: Words) -> Uploader {
  Uploader(..uploader, words:)
}

/// The uploader on its own.
pub fn view(uploader: Uploader) -> Element(msg) {
  let words = uploader.words
  let limit = case uploader.max_size {
    Some(bytes) -> [attribute.data("max-size", int.to_string(bytes))]
    None -> []
  }
  let id = case uploader.id {
    Some(id) -> [attribute.id(id)]
    None -> []
  }
  let accept = case uploader.accept {
    [] -> []
    types -> [attribute.accept(types)]
  }
  html.div(
    [
      class(uploader_class()),
      attribute.data("howdy-uploader", ""),
      attribute.data("name", uploader.name),
      attribute.data("start", uploader.start),
      attribute.data("max-files", int.to_string(uploader.max_files)),
      attribute.data("required", bool_string(uploader.required)),
      attribute.data("text-remove", words.remove),
      attribute.data("text-uploading", words.uploading),
      attribute.data("text-too-large", too_large(words, uploader.max_size)),
      attribute.data("text-wrong-type", words.wrong_type),
      attribute.data(
        "text-too-many",
        string.replace(
          words.too_many,
          "{count}",
          int.to_string(uploader.max_files),
        ),
      ),
      attribute.data("text-failed", words.failed),
      attribute.data("text-wait", words.wait),
      attribute.data("text-missing", words.missing),
      ..limit
    ],
    [
      html.label(
        [class(drop_class()), attribute.data("howdy-upload-drop", "")],
        [
          html.input([
            class(input_class()),
            attribute.type_("file"),
            attribute.data("howdy-upload-input", ""),
            attribute.multiple(uploader.max_files > 1),
            // Until the script takes over; it keeps this up to date itself.
            attribute.required(uploader.required && uploader.stored == []),
            ..list.append(id, accept)
          ]),
          html.span([class(prompt_class())], [text(words.prompt)]),
        ],
      ),
      html.ul(
        [
          class(attachment.group_class()),
          attribute.data("howdy-upload-list", ""),
        ],
        list.map(uploader.stored, fn(file) {
          item(uploader, Some(file), file.name, describe(file.name, file.size))
        }),
      ),
      html.template([attribute.data("howdy-upload-blank", "")], [
        item(uploader, None, "", ""),
      ]),
    ],
  )
}

/// A file's row. The script fills in a blank one for each file chosen.
fn item(
  uploader: Uploader,
  stored: Option(Stored),
  name: String,
  detail: String,
) -> Element(msg) {
  let layout = uploader.layout
  let words = uploader.words
  let thumbnail = case stored {
    Some(Stored(thumbnail: Some(src), ..)) -> Some(src)
    _ -> None
  }
  let key = case stored {
    Some(file) -> [attribute.value(file.key)]
    None -> [attribute.disabled(True)]
  }
  html.li([attribute.data("howdy-upload-item", "")], [
    html.div([class(attachment.attachment_class(layout))], [
      html.span(
        [
          class(attachment.icon_class(layout)),
          attribute.aria_hidden(True),
          attribute.data("howdy-upload-icon", ""),
          attribute.hidden(thumbnail != None),
        ],
        [text(attachment.extension(name))],
      ),
      html.span(
        [
          class(attachment.media_class(layout)),
          attribute.aria_hidden(True),
          attribute.data("howdy-upload-media", ""),
          attribute.hidden(thumbnail == None),
        ],
        [
          html.img([
            attribute.alt(""),
            ..case thumbnail {
              Some(src) -> [attribute.src(src)]
              None -> []
            }
          ]),
        ],
      ),
      html.div([class(attachment.text_class())], [
        html.div(
          [
            class(attachment.name_class()),
            attribute.data("howdy-upload-name", ""),
          ],
          [text(name)],
        ),
        html.div(
          [
            class(attachment.detail_class()),
            attribute.data("howdy-upload-detail", ""),
          ],
          [text(detail)],
        ),
        html.div(
          [
            class(attachment.track_class()),
            attribute.role("progressbar"),
            attribute.attribute("aria-valuemin", "0"),
            attribute.attribute("aria-valuemax", "100"),
            attribute.attribute("aria-valuenow", "0"),
            attribute.data("howdy-upload-progress", ""),
            attribute.hidden(True),
          ],
          [
            html.div(
              [class(attachment.bar_class()), attribute.style("width", "0%")],
              [],
            ),
          ],
        ),
        html.div(
          [
            class(attachment.failed_class()),
            attribute.role("alert"),
            attribute.data("howdy-upload-error", ""),
            attribute.hidden(True),
          ],
          [],
        ),
      ]),
      html.div([class(attachment.actions_class(layout))], [
        icon_button(
          [
            attribute.aria_label(words.retry <> " " <> name),
            attribute.data("howdy-upload-retry", ""),
            attribute.data("label", words.retry),
            attribute.hidden(True),
          ],
          "↻",
        ),
        icon_button(
          [
            attribute.aria_label(words.remove <> " " <> name),
            attribute.data("howdy-upload-remove", ""),
          ],
          "×",
        ),
      ]),
      html.input([
        attribute.type_("hidden"),
        attribute.name(uploader.name),
        attribute.data("howdy-upload-key", ""),
        ..key
      ]),
    ]),
  ])
}

fn icon_button(attributes: List(Attribute(msg)), icon: String) -> Element(msg) {
  button.sized(button.Ghost, button.IconSmall, attributes, [text(icon)])
}

fn too_large(words: Words, max_size: Option(Int)) -> String {
  case max_size {
    Some(bytes) -> string.replace(words.too_large, "{limit}", file_size(bytes))
    None -> words.too_large
  }
}

fn bool_string(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}

/// A file's type and size as an attachment shows them, such as
/// `"PDF · 2.4 MB"`, the same as the browser shows for a file just chosen.
pub fn describe(name: String, size: Int) -> String {
  case attachment.extension(name) {
    "FILE" -> file_size(size)
    extension -> extension <> " · " <> file_size(size)
  }
}

/// A number of bytes for people: `"820 KB"`, `"2.4 MB"`, `"18 MB"`. Units
/// go up in thousands, with one decimal place below ten.
pub fn file_size(bytes: Int) -> String {
  scaled(int.to_float(int.max(bytes, 0)), ["B", "KB", "MB", "GB", "TB"])
}

fn scaled(amount: Float, units: List(String)) -> String {
  case units {
    [unit] -> number(amount) <> " " <> unit
    ["B", ..rest] if amount >=. 1000.0 -> scaled(amount /. 1000.0, rest)
    ["B", ..] -> int.to_string(float.round(amount)) <> " B"
    [_, ..rest] if amount >=. 999.5 -> scaled(amount /. 1000.0, rest)
    [unit, ..] -> number(amount) <> " " <> unit
    [] -> number(amount)
  }
}

fn number(amount: Float) -> String {
  case amount <. 9.95 {
    True -> {
      let tenths = float.round(amount *. 10.0)
      case tenths % 10 {
        0 -> int.to_string(tenths / 10)
        rest -> int.to_string(tenths / 10) <> "." <> int.to_string(rest)
      }
    }
    False -> int.to_string(float.round(amount))
  }
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [uploader_class(), drop_class(), input_class(), prompt_class()]
}

pub fn uploader_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(0.75)),
    // The attachment parts set their own display, which `hidden` must win.
    css.selector(" [hidden]", [css.property("display", "none !important")]),
  ])
}

pub fn drop_class() -> Class {
  css.class([
    css.position("relative"),
    css.display("flex"),
    css.align_items("center"),
    css.justify_content("center"),
    css.padding(rem(1.5)),
    css.property("border", "1px dashed " <> tokens.border),
    style.radius(tokens.radius_medium),
    css.background(tokens.background),
    css.color(tokens.text_muted),
    css.font_size(rem(0.875)),
    css.text_align("center"),
    css.cursor("pointer"),
    css.transition("border-color 150ms, background 150ms"),
    css.hover([css.property("border-color", tokens.text_muted)]),
    css.selector(":has(:focus-visible)", [
      style.focus_outline(),
      css.property("outline-offset", "2px"),
    ]),
    css.selector("[data-dragging]", [
      css.property("border-color", tokens.primary),
      css.background(tokens.muted),
      css.color(tokens.text),
    ]),
    css.selector(":has(:user-invalid)", [
      css.property("border-color", tokens.danger),
    ]),
  ])
}

/// The file input, hidden but still focusable and announced.
pub fn input_class() -> Class {
  css.class([
    css.position("absolute"),
    css.width(rem(0.0625)),
    css.height(rem(0.0625)),
    css.padding(rem(0.0)),
    css.margin(rem(-0.0625)),
    css.overflow("hidden"),
    css.property("clip", "rect(0, 0, 0, 0)"),
    css.white_space("nowrap"),
    css.property("border", "0"),
  ])
}

pub fn prompt_class() -> Class {
  css.class([css.property("pointer-events", "none")])
}
