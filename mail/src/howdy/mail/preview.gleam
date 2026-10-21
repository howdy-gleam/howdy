//// Named examples of your emails, built from sample data, for the admin
//// area to render without running the flow that sends them.
////
//// ```gleam
//// pub fn previews() -> List(preview.Preview) {
////   [
////     preview.new("Welcome", fn() { emails.welcome(sample_user()) }),
////     preview.new("Invoice", fn() { emails.invoice(sample_invoice()) })
////       |> preview.in_group("Billing"),
////   ]
//// }
//// ```
////
//// A preview is built each time it is shown, so with `howdy/dev` an edited
//// template shows on the next refresh.

import gleam/list
import gleam/string
import howdy/mail.{type Message}

pub opaque type Preview {
  Preview(group: String, name: String, build: fn() -> Message)
}

/// A preview in the group "Emails".
pub fn new(name: String, build: fn() -> Message) -> Preview {
  Preview(group: "Emails", name:, build:)
}

/// Show the preview under this heading.
pub fn in_group(preview: Preview, group: String) -> Preview {
  Preview(..preview, group:)
}

pub fn name(preview: Preview) -> String {
  preview.name
}

pub fn group(preview: Preview) -> String {
  preview.group
}

@external(erlang, "howdy_mail_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, String)

/// Build the message. A template that panics or crashes on the sample data
/// gives `Error` with the reason instead.
pub fn build(preview: Preview) -> Result(Message, String) {
  rescue(preview.build)
}

/// A URL-safe key for the preview, from its group and name.
pub fn key(preview: Preview) -> String {
  slug(preview.group) <> "." <> slug(preview.name)
}

fn slug(text: String) -> String {
  string.lowercase(text)
  |> string.to_graphemes
  |> list.map(fn(c) {
    case string.contains("abcdefghijklmnopqrstuvwxyz0123456789", c) {
      True -> c
      False -> "-"
    }
  })
  |> string.concat
}

/// The preview with this `key`.
pub fn find(previews: List(Preview), wanted: String) -> Result(Preview, Nil) {
  list.find(previews, fn(preview) { key(preview) == wanted })
}
