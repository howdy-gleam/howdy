//// The mail pages: the outbox as messages arrive, each message rendered,
//// and email previews built from sample data.

import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/format
import howdy/admin/internal/layout
import howdy/admin/internal/mail/message
import howdy/admin/internal/mail/previews
import howdy/content.{type Content}
import howdy/controller.{type Context, type Controller}
import howdy/mail.{type Outgoing}
import howdy/mail/outbox.{type Outbox}
import howdy/ui
import howdy/ui/alert
import howdy/ui/button
import howdy/ui/live
import lustre
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/event

pub fn controller(config: Config) -> Controller {
  controller.new(config.prefix)
  |> controller.get("/mail", fn(ctx) { outbox_page(config, ctx) })
  |> controller.post("/mail/clear", fn(ctx) { clear(config, ctx) })
  |> controller.get("/mail/message/:id", fn(ctx) { message.page(config, ctx) })
  |> controller.get("/mail/message/:id/html", fn(ctx) {
    use outgoing <- message.with_message(config, ctx)
    message.html_response(outgoing)
  })
  |> controller.get("/mail/message/:id/source", fn(ctx) {
    use outgoing <- message.with_message(config, ctx)
    message.source_response(outgoing)
  })
  |> controller.get("/mail/message/:id/attachment/:index", fn(ctx) {
    use outgoing <- message.with_message(config, ctx)
    message.attachment_response(outgoing, ctx)
  })
  |> controller.get("/mail/previews", fn(ctx) { previews.page(config, ctx) })
  |> controller.get("/mail/previews/html", fn(ctx) {
    use outgoing <- previews.with_preview(config, ctx)
    message.html_response(outgoing)
  })
  |> controller.post("/mail/previews/send", fn(ctx) {
    previews.send_preview(config, ctx)
  })
  |> controller.get("/live/mail", fn(ctx) { socket(config, ctx) })
}

// -- The outbox --------------------------------------------------------------

fn outbox_page(config: Config, ctx: Context) -> Response(Content) {
  case config.outbox {
    None -> layout.redirect(config.path(config, "/mail/previews"))
    Some(box) -> outbox_view(config, ctx, box, [])
  }
}

/// The outbox page, with `notices` above the list.
fn outbox_view(
  config: Config,
  ctx: Context,
  box: Outbox,
  notices: List(Element(msg)),
) -> Response(Content) {
  layout.page(
    config,
    ctx,
    current: "/mail",
    heading: "Outbox",
    live: True,
    content: list.append(notices, [
      ui.p([
        ui.muted(case outbox.directory(box) {
          Some(directory) ->
            "Mail sent through the outbox adapter, also written to "
            <> directory
            <> ". The newest "
            <> int.to_string(outbox.capacity)
            <> " are kept."
          None ->
            "Mail sent through the outbox adapter, kept in memory until the app stops. The newest "
            <> int.to_string(outbox.capacity)
            <> " are kept."
        }),
      ]),
      live.mount(config.path(config, "/live/mail")),
    ]),
  )
}

/// Empty the outbox. When it cannot be, the page says so in place of the
/// redirect.
fn clear(config: Config, ctx: Context) -> Response(Content) {
  case config.outbox {
    Some(box) ->
      case outbox.clear(box) {
        Ok(Nil) -> layout.redirect(config.path(config, "/mail"))
        Error(error) ->
          outbox_view(config, ctx, box, [
            problem("The outbox was not cleared", error),
          ])
      }
    None -> layout.redirect(config.path(config, "/mail"))
  }
}

fn socket(config: Config, ctx: Context) -> Response(Content) {
  case config.outbox {
    Some(box) -> live.serve(ctx, list_app(), with: Args(config, box))
    None -> layout.redirect(config.path(config, "/mail/previews"))
  }
}

/// The outbox's messages, or why it could not say: it is not running.
fn messages_in(box: Outbox) -> Result(List(Outgoing), mail.Error) {
  outbox.messages(box)
}

/// What the outbox answered instead, for the developer to read.
fn problem(title: String, error: mail.Error) -> Element(msg) {
  message.notice(alert.Danger, title, mail.error_to_string(error))
}

pub type Args {
  Args(config: Config, box: Outbox)
}

pub type Model {
  Model(
    config: Config,
    box: Outbox,
    /// What the outbox holds, or why it could not say.
    messages: Result(List(Outgoing), mail.Error),
    /// Why the last clear failed, until the outbox changes.
    cleared: Result(Nil, mail.Error),
  )
}

pub type Msg {
  /// A message arrived or the outbox was cleared.
  Changed
  Clear
}

fn list_app() -> lustre.App(Args, Model, Msg) {
  lustre.application(
    init: fn(args: Args) {
      #(
        Model(args.config, args.box, messages_in(args.box), Ok(Nil)),
        subscribe(args.box),
      )
    },
    update: fn(model: Model, msg) {
      case msg {
        Changed -> #(
          Model(..model, messages: messages_in(model.box), cleared: Ok(Nil)),
          effect.none(),
        )
        Clear ->
          case outbox.clear(model.box) {
            Ok(Nil) -> #(
              Model(..model, messages: Ok([]), cleared: Ok(Nil)),
              effect.none(),
            )
            Error(error) -> #(
              Model(..model, cleared: Error(error)),
              effect.none(),
            )
          }
      }
    },
    view: list_view,
  )
}

/// The effect runs in the runtime's process, so the outbox drops the
/// subscription when the page goes away.
fn subscribe(box: Outbox) -> Effect(Msg) {
  use dispatch <- effect.from
  outbox.subscribe(box, fn() { dispatch(Changed) })
}

fn list_view(model: Model) -> Element(Msg) {
  let config = model.config
  case model.messages {
    Error(error) -> problem("The outbox could not be read", error)
    Ok([]) ->
      ui.empty(
        icon: text("✉"),
        title: "No mail yet",
        description: "Messages your app sends appear here as they are sent.",
        actions: case config.mailer {
          Some(_) -> [
            ui.link(config.path(config, "/mail/previews"), [
              text("Send a preview"),
            ]),
          ]
          None -> []
        },
      )
    Ok(messages) ->
      ui.stack(
        [],
        list.append(
          case model.cleared {
            Ok(Nil) -> []
            Error(error) -> [problem("The outbox was not cleared", error)]
          },
          [
            ui.row([], [
              ui.muted(format.describe(list.length(messages), "message")),
              ui.button(button.Outline, [event.on_click(Clear)], [
                text("Clear all"),
              ]),
            ]),
            ui.table([], [
              ui.table_header([], [
                ui.table_row([], [
                  ui.table_head([], [text("Sent")]),
                  ui.table_head([], [text("To")]),
                  ui.table_head([], [text("Subject")]),
                  ui.table_head([], [text("Tags")]),
                ]),
              ]),
              ui.table_body(
                [],
                list.map(messages, fn(outgoing) {
                  let href =
                    config.path(config, "/mail/message/" <> outgoing.id)
                  ui.table_row([], [
                    ui.table_cell([], [text(format.date_time(outgoing.date))]),
                    ui.table_cell([], [
                      text(
                        layout.clip(
                          message.addresses(mail.recipients(outgoing)),
                        ),
                      ),
                    ]),
                    ui.table_cell([], [
                      ui.link(href, [text(layout.clip(outgoing.subject))]),
                    ]),
                    ui.table_cell([], [message.tags(outgoing.tags)]),
                  ])
                }),
              ),
            ]),
          ],
        ),
      )
  }
}
