//// Email previews: each template rendered from its sample data, and sent
//// on demand through the mailer the app registered.

import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/uri
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/layout
import howdy/admin/internal/mail/message
import howdy/content.{type Content}
import howdy/controller.{type Context}
import howdy/mail.{type Mailer, type Outgoing}
import howdy/mail/outbox
import howdy/mail/preview.{type Preview}
import howdy/ui
import howdy/ui/alert
import howdy/ui/button
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html

pub fn page(config: Config, ctx: Context) -> Response(Content) {
  let page = fn(heading, content) {
    layout.page(
      config,
      ctx,
      current: "/mail/previews",
      heading:,
      live: False,
      content:,
    )
  }
  case config.mailer, config.previews {
    None, _ ->
      page("Previews", [
        message.notice(
          alert.Info,
          "No previews registered",
          "Pass your previews and a mailer to admin.mail_previews.",
        ),
      ])
    Some(_), [] ->
      page("Previews", [
        message.notice(
          alert.Info,
          "No previews registered",
          "admin.mail_previews was given an empty list. Build previews with howdy/mail/preview.",
        ),
      ])
    Some(mailer), [first, ..] as previews -> {
      let selected =
        message.query(ctx, "p")
        |> result.try(preview.find(previews, _))
        |> result.unwrap(first)
      let key = preview.key(selected)
      let base = config.path(config, "/mail/previews")
      let width = message.width_of(ctx)
      page(preview.group(selected) <> " · " <> preview.name(selected), [
        html.div(
          [
            attribute.style("display", "grid"),
            attribute.style("grid-template-columns", "minmax(12rem, 16rem) 1fr"),
            attribute.style("gap", "1.5rem"),
            attribute.style("align-items", "start"),
          ],
          [
            index(previews, selected, base, width),
            ui.stack([], [
              case message.query(ctx, "sent") {
                Ok(adapter) ->
                  message.notice(
                    alert.Info,
                    "Sent",
                    "Delivered by " <> adapter <> ".",
                  )
                Error(Nil) -> element.none()
              },
              ..case render(mailer, selected) {
                Error(problem) -> [problem]
                Ok(outgoing) -> [
                  html.form(
                    [
                      attribute.method("post"),
                      attribute.action(
                        base <> "/send?p=" <> uri.percent_encode(key),
                      ),
                    ],
                    [
                      ui.row([], [
                        ui.submit_button(button.Primary, [], [
                          text(case config.outbox {
                            Some(_) -> "Send to outbox"
                            None -> "Send"
                          }),
                        ]),
                        ui.muted(
                          "Through "
                          <> mail.adapter_name(mail.mailer_adapter(mailer)),
                        ),
                      ]),
                    ],
                  ),
                  ..message.message_view(
                    outgoing,
                    html_src: base <> "/html?p=" <> uri.percent_encode(key),
                    source: None,
                    attachment: fn(_) { None },
                    width:,
                    width_href: fn(width) {
                      base
                      <> "?p="
                      <> uri.percent_encode(key)
                      <> "&width="
                      <> width
                    },
                  )
                ]
              }
            ]),
          ],
        ),
      ])
    }
  }
}

/// The previews by group, the selected one marked.
fn index(
  previews: List(Preview),
  selected: Preview,
  base: String,
  width: String,
) -> Element(msg) {
  let groups =
    list.fold(previews, [], fn(groups, preview) {
      case list.contains(groups, preview.group(preview)) {
        True -> groups
        False -> list.append(groups, [preview.group(preview)])
      }
    })
  ui.card([], [
    ui.card_content(
      [],
      list.map(groups, fn(group) {
        html.nav([attribute.attribute("aria-label", group)], [
          html.h3([attribute.style("margin", "0.5rem 0 0.25rem")], [text(group)]),
          html.ul(
            [
              attribute.style("margin", "0"),
              attribute.style("padding-left", "1rem"),
            ],
            list.filter(previews, fn(p) { preview.group(p) == group })
              |> list.map(fn(p) {
                let href =
                  base
                  <> "?p="
                  <> uri.percent_encode(preview.key(p))
                  <> "&width="
                  <> width
                html.li([], [
                  case preview.key(p) == preview.key(selected) {
                    True ->
                      html.strong(
                        [attribute.attribute("aria-current", "page")],
                        [
                          text(preview.name(p)),
                        ],
                      )
                    False -> ui.link(href, [text(preview.name(p))])
                  },
                ])
              }),
          ),
        ])
      }),
    ),
  ])
}

/// The preview as it would be sent, or why it cannot be.
fn render(mailer: Mailer, selected: Preview) -> Result(Outgoing, Element(msg)) {
  use message <- result.try(
    preview.build(selected)
    |> result.map_error(fn(reason) {
      message.notice(alert.Danger, "The template crashed", reason)
    }),
  )
  mail.prepare(mailer, message)
  |> result.map_error(fn(error) {
    message.notice(
      alert.Danger,
      "This message would not be sent",
      mail.error_to_string(error),
    )
  })
}

pub fn with_preview(
  config: Config,
  ctx: Context,
  next: fn(Outgoing) -> Response(Content),
) -> Response(Content) {
  let found = {
    use mailer <- result.try(option.to_result(config.mailer, Nil))
    use key <- result.try(message.query(ctx, "p"))
    use selected <- result.try(preview.find(config.previews, key))
    render(mailer, selected) |> result.replace_error(Nil)
  }
  case found {
    Ok(outgoing) -> next(outgoing)
    Error(Nil) ->
      response.new(404) |> response.set_body(content.Text("No such preview"))
  }
}

pub fn send_preview(config: Config, ctx: Context) -> Response(Content) {
  let base = config.path(config, "/mail/previews")
  let sent = {
    use mailer <- result.try(option.to_result(
      config.mailer,
      "No mailer was registered.",
    ))
    use key <- result.try(
      message.query(ctx, "p") |> result.replace_error("No preview was chosen."),
    )
    use selected <- result.try(
      preview.find(config.previews, key)
      |> result.replace_error("There is no preview " <> key <> "."),
    )
    use message <- result.try(preview.build(selected))
    use receipt <- result.try(
      mail.send(mailer, message) |> result.map_error(mail.error_to_string),
    )
    Ok(#(key, mailer, receipt))
  }
  case sent {
    Ok(#(key, mailer, receipt)) ->
      case config.outbox {
        Some(box) ->
          case outbox.get(box, receipt.id) {
            Ok(_) ->
              layout.redirect(config.path(
                config,
                "/mail/message/" <> receipt.id,
              ))
            Error(Nil) -> back_to(base, key, mailer)
          }
        None -> back_to(base, key, mailer)
      }
    Error(reason) ->
      layout.page(
        config,
        ctx,
        current: "/mail/previews",
        heading: "Not sent",
        live: False,
        content: [
          message.notice(alert.Danger, "The preview was not sent", reason),
          ui.p([ui.link(base, [text("Previews")])]),
        ],
      )
  }
}

fn back_to(base: String, key: String, mailer: Mailer) -> Response(Content) {
  layout.redirect(
    base
    <> "?p="
    <> uri.percent_encode(key)
    <> "&sent="
    <> uri.percent_encode(mail.adapter_name(mail.mailer_adapter(mailer))),
  )
}
