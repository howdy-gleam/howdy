//// One message: its envelope and attachments, and its body as HTML, text
//// and source, at desktop or mobile width.

import gleam/bit_array
import gleam/bytes_tree
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/format
import howdy/admin/internal/layout
import howdy/content.{type Content}
import howdy/controller.{type Context}
import howdy/mail.{type Address, type Outgoing}
import howdy/mail/mime
import howdy/mail/outbox
import howdy/ui
import howdy/ui/alert
import howdy/ui/badge
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html

// -- One message -------------------------------------------------------------

pub fn page(config: Config, ctx: Context) -> Response(Content) {
  use outgoing <- with_message(config, ctx)
  let base = config.path(config, "/mail/message/" <> outgoing.id)
  let width = width_of(ctx)
  layout.page(
    config,
    ctx,
    current: "/mail",
    heading: outgoing.subject,
    live: False,
    content: [
      ui.row([], [ui.link(config.path(config, "/mail"), [text("Outbox")])]),
      ..message_view(
        outgoing,
        html_src: base <> "/html",
        source: Some(base <> "/source"),
        attachment: fn(index) {
          Some(base <> "/attachment/" <> int.to_string(index))
        },
        width:,
        width_href: fn(width) { base <> "?width=" <> width },
      )
    ],
  )
}

pub fn with_message(
  config: Config,
  ctx: Context,
  next: fn(Outgoing) -> Response(Content),
) -> Response(Content) {
  let id = controller.param(ctx, "id") |> result.unwrap("")
  let found = case config.outbox {
    Some(box) -> outbox.get(box, id)
    None -> Error(Nil)
  }
  case found {
    Ok(outgoing) -> next(outgoing)
    Error(Nil) ->
      layout.page(
        config,
        ctx,
        current: "/mail",
        heading: "Not found",
        live: False,
        content: [
          notice(
            alert.Danger,
            "No such message",
            "The outbox no longer has it: it was cleared, or pushed out by newer mail.",
          ),
          ui.p([ui.link(config.path(config, "/mail"), [text("Outbox")])]),
        ],
      )
  }
}

/// The envelope, attachments, and the body as HTML, text and source.
pub fn message_view(
  outgoing: Outgoing,
  html_src html_src: String,
  source source: Option(String),
  attachment attachment: fn(Int) -> Option(String),
  width width: String,
  width_href width_href: fn(String) -> String,
) -> List(Element(msg)) {
  let field = fn(name, value) {
    ui.table_row([], [
      ui.table_head([attribute.attribute("scope", "row")], [text(name)]),
      ui.table_cell([], [value]),
    ])
  }
  let optional = fn(name, list: List(Address)) {
    case list {
      [] -> element.none()
      list -> field(name, text(addresses(list)))
    }
  }
  [
    ui.card([], [
      ui.card_content([], [
        ui.table([], [
          ui.table_body([], [
            field("From", text(mail.address_to_string(outgoing.from))),
            optional("To", outgoing.to),
            optional("Cc", outgoing.cc),
            optional("Bcc", outgoing.bcc),
            case outgoing.reply_to {
              Some(address) ->
                field("Reply-To", text(mail.address_to_string(address)))
              None -> element.none()
            },
            field("Date", text(format.date_time(outgoing.date))),
            field("Subject", text(outgoing.subject)),
            case outgoing.tags {
              [] -> element.none()
              list -> field("Tags", tags(list))
            },
            ..list.map(outgoing.headers, fn(header) {
              field(header.0, text(header.1))
            })
          ]),
        ]),
      ]),
    ]),
    case outgoing.attachments {
      [] -> element.none()
      attachments ->
        ui.card([], [
          ui.card_header([], [ui.card_title([text("Attachments")])]),
          ui.card_content([], [
            html.ul(
              [],
              list.index_map(attachments, fn(file: mail.Attachment, index) {
                let label =
                  file.filename
                  <> " · "
                  <> file.content_type
                  <> " · "
                  <> size(bit_array.byte_size(file.content))
                  <> case file.content_id {
                    Some(id) -> " · inline as cid:" <> id
                    None -> ""
                  }
                html.li([], [
                  case attachment(index) {
                    Some(href) -> ui.link(href, [text(label)])
                    None -> text(label)
                  },
                ])
              }),
            ),
          ]),
        ])
    },
    ui.tabs(
      "message",
      selected: case outgoing.html {
        Some(_) -> "html"
        None -> "text"
      },
      attributes: [],
      tabs: list.flatten([
        case outgoing.html {
          Some(_) -> [
            ui.tab("html", [], label: [text("HTML")], panel: [
              ui.stack([], [
                ui.row([], [
                  width_link("Desktop", "desktop", width, width_href),
                  width_link("Mobile", "mobile", width, width_href),
                  ui.link(html_src, [text("Open alone")]),
                ]),
                html.iframe([
                  attribute.src(html_src),
                  attribute.title("The message's HTML"),
                  // No scripts, no forms, no same-origin access; links open
                  // in a new tab.
                  attribute.attribute(
                    "sandbox",
                    "allow-popups allow-popups-to-escape-sandbox",
                  ),
                  attribute.attribute("referrerpolicy", "no-referrer"),
                  attribute.style("width", case width {
                    "mobile" -> "375px"
                    _ -> "100%"
                  }),
                  attribute.style("height", "70vh"),
                  attribute.style(
                    "border",
                    "1px solid var(--howdy-border, #ddd)",
                  ),
                  attribute.style("border-radius", "0.5rem"),
                  attribute.style("background", "white"),
                ]),
              ]),
            ]),
          ]
          None -> []
        },
        case outgoing.text {
          Some(body) -> [
            ui.tab("text", [], label: [text("Text")], panel: [
              monospace(linkify(body)),
            ]),
          ]
          None -> []
        },
        [
          ui.tab("source", [], label: [text("Source")], panel: [
            ui.stack([], [
              case source {
                Some(href) ->
                  ui.row([], [ui.link(href, [text("Download .eml")])])
                None -> element.none()
              },
              monospace([text(string.slice(mime.encode(outgoing), 0, 200_000))]),
            ]),
          ]),
        ],
      ]),
    ),
  ]
}

fn width_link(
  label: String,
  value: String,
  current: String,
  href: fn(String) -> String,
) -> Element(msg) {
  case value == current {
    True -> html.strong([], [text(label)])
    False -> ui.link(href(value), [text(label)])
  }
}

pub fn width_of(ctx: Context) -> String {
  case query(ctx, "width") {
    Ok("mobile") -> "mobile"
    _ -> "desktop"
  }
}

fn monospace(children: List(Element(msg))) -> Element(msg) {
  html.pre(
    [
      attribute.style("white-space", "pre-wrap"),
      attribute.style("overflow-wrap", "anywhere"),
      attribute.style("font-family", "ui-monospace, monospace"),
      attribute.style("font-size", "0.8125rem"),
      attribute.style("margin", "0"),
    ],
    children,
  )
}

/// Plain text with its `http` and `https` URLs as links, so a sign-in link
/// can be followed from here.
fn linkify(body: String) -> List(Element(msg)) {
  string.split(body, "\n")
  |> list.map(fn(line) {
    string.split(line, " ")
    |> list.map(fn(word) {
      case
        string.starts_with(word, "https://")
        || string.starts_with(word, "http://")
      {
        True ->
          html.a(
            [
              attribute.href(word),
              attribute.target("_blank"),
              attribute.rel("noreferrer"),
            ],
            [text(word)],
          )
        False -> text(word)
      }
    })
    |> list.intersperse(text(" "))
  })
  |> list.intersperse([text("\n")])
  |> list.flatten
}

/// The message's HTML on its own, for the frame. Inline attachments become
/// `data:` URLs so `cid:` images show, and links open in a new tab. The
/// content security policy repeats the frame's sandbox, so opening this URL
/// directly runs no script either.
pub fn html_response(outgoing: Outgoing) -> Response(Content) {
  let body =
    option.unwrap(outgoing.html, "")
    |> inline_images(outgoing.attachments)
    |> with_base
  response.new(200)
  |> response.set_header("content-type", "text/html; charset=utf-8")
  |> response.set_header(
    "content-security-policy",
    "sandbox allow-popups allow-popups-to-escape-sandbox; default-src 'none'; img-src * data:; style-src * 'unsafe-inline'; font-src * data:",
  )
  |> response.set_header("x-content-type-options", "nosniff")
  |> response.set_header("referrer-policy", "no-referrer")
  |> response.set_body(content.Text(body))
}

fn inline_images(html: String, attachments: List(mail.Attachment)) -> String {
  list.fold(attachments, html, fn(html, file) {
    case file.content_id {
      Some(id) ->
        string.replace(
          html,
          "cid:" <> id,
          "data:"
            <> file.content_type
            <> ";base64,"
            <> bit_array.base64_encode(file.content, True),
        )
      None -> html
    }
  })
}

fn with_base(html: String) -> String {
  let base = "<base target=\"_blank\">"
  case string.split_once(html, "<head>") {
    Ok(#(before, after)) -> before <> "<head>" <> base <> after
    Error(Nil) -> base <> html
  }
}

pub fn source_response(outgoing: Outgoing) -> Response(Content) {
  response.new(200)
  |> response.set_header("content-type", "message/rfc822")
  |> response.set_header(
    "content-disposition",
    "attachment; filename=\"" <> outgoing.id <> ".eml\"",
  )
  |> response.set_body(content.Text(mime.encode(outgoing)))
}

pub fn attachment_response(
  outgoing: Outgoing,
  ctx: Context,
) -> Response(Content) {
  let found = {
    use index <- result.try(
      controller.param(ctx, "index") |> result.try(int.parse),
    )
    list.drop(outgoing.attachments, index) |> list.first
  }
  case found {
    Ok(file) ->
      response.new(200)
      |> response.set_header("content-type", "application/octet-stream")
      |> response.set_header(
        "content-disposition",
        "attachment; filename=\""
          <> string.replace(file.filename, "\"", "")
          <> "\"",
      )
      |> response.set_header("x-content-type-options", "nosniff")
      |> response.set_body(
        content.Bytes(bytes_tree.from_bit_array(file.content)),
      )
    Error(Nil) ->
      response.new(404) |> response.set_body(content.Text("No such attachment"))
  }
}

// -- Helpers -----------------------------------------------------------------

pub fn query(ctx: Context, name: String) -> Result(String, Nil) {
  request.get_query(ctx.request)
  |> result.unwrap([])
  |> list.key_find(name)
}

pub fn notice(
  variant: alert.Variant,
  title: String,
  description: String,
) -> Element(msg) {
  ui.alert(variant, [], [
    ui.alert_title([text(title)]),
    ui.alert_description([text(description)]),
  ])
}

pub fn addresses(list: List(Address)) -> String {
  list.map(list, mail.address_to_string) |> string.join(", ")
}

pub fn tags(list: List(String)) -> Element(msg) {
  ui.row(
    [],
    list.map(list, fn(tag) { ui.badge(badge.Secondary, [], [text(tag)]) }),
  )
}

fn size(bytes: Int) -> String {
  case bytes {
    _ if bytes < 1024 -> int.to_string(bytes) <> " B"
    _ if bytes < 1_048_576 -> int.to_string(bytes / 1024) <> " KB"
    _ -> int.to_string(bytes / 1_048_576) <> " MB"
  }
}
