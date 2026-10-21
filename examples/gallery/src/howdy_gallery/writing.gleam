//// Somewhere for the rich text examples to search and post: people and
//// issues to mention, and a page showing a posted document as the server
//// reads it, with the editor again so it can be changed and posted back.
////
//// A real app would search its own records, check that each mention and
//// attachment is one the signed-in user may use, and save the document
//// with `document.to_string`.

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import howdy/controller.{type Context}
import howdy/form
import howdy/query
import howdy/storage
import howdy/storage/local
import howdy/ui
import howdy/ui/button.{Primary}
import howdy/ui/rich_text
import howdy/ui/rich_text/document.{type Document}
import howdy_gallery/uploads
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html

pub fn people() -> List(rich_text.Suggestion) {
  [
    person("1", "Ada Lovelace", "ada@example.com"),
    person("2", "Alan Turing", "alan@example.com"),
    person("3", "Grace Hopper", "grace@example.com"),
    person("4", "Katherine Johnson", "katherine@example.com"),
    person("5", "Margaret Hamilton", "margaret@example.com"),
    person("6", "Edsger Dijkstra", "edsger@example.com"),
  ]
}

fn person(id: String, name: String, email: String) -> rich_text.Suggestion {
  rich_text.Suggestion(id:, label: name, detail: Some(email), image: None)
}

fn issues() -> List(rich_text.Suggestion) {
  [
    rich_text.Suggestion(
      id: "42",
      label: "42",
      detail: Some("Editor loses focus"),
      image: None,
    ),
    rich_text.Suggestion(
      id: "57",
      label: "57",
      detail: Some("Dark mode contrast"),
      image: None,
    ),
  ]
}

/// GET /people/search?q=
pub fn search_people(ctx: Context) {
  use q <- query.string_or(ctx, "q", default: "")
  controller.json(ctx, rich_text.suggestions_to_json(matching(people(), q)))
}

/// GET /issues/search?q=
pub fn search_issues(ctx: Context) {
  use q <- query.string_or(ctx, "q", default: "")
  controller.json(ctx, rich_text.suggestions_to_json(matching(issues(), q)))
}

fn matching(
  suggestions: List(rich_text.Suggestion),
  q: String,
) -> List(rich_text.Suggestion) {
  let q = string.lowercase(q)
  list.filter(suggestions, fn(suggestion) {
    string.contains(string.lowercase(suggestion.label), q)
    || string.contains(
      string.lowercase(option.unwrap(suggestion.detail, "")),
      q,
    )
  })
}

/// What POST /rich-text shows: each document posted, drawn from the
/// server's records, its plain text and mentions, and the editor again.
pub fn received(fields: form.Form) -> List(Element(msg)) {
  ["comment", "article"]
  |> list.filter_map(fn(name) {
    use value <- result.try(form.get(fields, name))
    case document.decode(value) {
      Ok(body) -> Ok(shown(name, body))
      Error(problem) ->
        Ok([html.p([attribute.id("rich-text-error")], [text(problem)])])
    }
  })
  |> list.flatten
}

fn shown(name: String, body: Document) -> List(Element(msg)) {
  let files = local.adapter(uploads.config())
  let url = fn(file: document.Attachment) {
    case storage.url(files, file.key, expires_in: 3600) {
      Ok(url) -> Some(url)
      Error(_) -> None
    }
  }
  let mentioned =
    document.mentions(body)
    |> list.map(fn(mention) {
      let known = case mention.kind {
        "person" -> list.any(people(), fn(person) { person.id == mention.id })
        "issue" -> list.any(issues(), fn(issue) { issue.id == mention.id })
        _ -> False
      }
      mention.kind
      <> ":"
      <> mention.id
      <> case known {
        True -> ""
        False -> "?"
      }
    })
    |> string.join(" ")
  [
    ui.h2("Received"),
    html.div([attribute.id("rich-text-shown")], [
      document.view_with(
        body,
        mention: fn(mention) {
          // Drawn from today's records, not the label saved with it.
          let label = case
            list.find(people(), fn(person) { person.id == mention.id })
          {
            Ok(person) if mention.kind == "person" -> person.label
            _ -> mention.label
          }
          document.mention_view(
            document.Mention(..mention, label:),
            href: Some("#" <> mention.kind <> "-" <> mention.id),
          )
        },
        attachment: fn(file) { document.attachment_view(file, url: url(file)) },
      ),
    ]),
    ui.h3("Mentions"),
    html.output([attribute.id("rich-text-mentions")], [text(mentioned)]),
    ui.h3("Plain text"),
    html.pre([attribute.id("rich-text-plain")], [
      text(document.to_plain_text(body)),
    ]),
    ui.h3("Edit again"),
    html.form([attribute.method("post"), attribute.action("/rich-text")], [
      ui.stack([], [
        rich_text.new(name:)
          |> rich_text.value(body)
          |> rich_text.mentions(
            trigger: "@",
            kind: "person",
            search: "/people/search",
          )
          |> rich_text.attachments(start: "/uploads/start", url:)
          |> rich_text.view,
        ui.submit_button(Primary, [], [text("Post again")]),
      ]),
    ]),
  ]
}

pub fn check_attachments(body: Document) -> String {
  let files = local.adapter(uploads.config())
  document.attachments(body)
  |> list.map(fn(file) {
    case storage.exists(files, file.key) {
      Ok(True) -> file.key <> "=found"
      _ -> file.key <> "=missing"
    }
  })
  |> string.join(" ")
}

/// Posted attachments: each key, and whether storage has it.
pub fn attachment_report(fields: form.Form) -> Element(msg) {
  let report =
    ["comment", "article"]
    |> list.filter_map(fn(name) {
      use value <- result.try(form.get(fields, name))
      case document.decode(value) {
        Ok(body) -> Ok(check_attachments(body))
        Error(_) -> Error(Nil)
      }
    })
    |> string.join(" ")
  html.output([attribute.id("rich-text-attachments")], [text(report)])
}
