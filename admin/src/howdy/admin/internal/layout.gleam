//// The admin's page shell and small response helpers.

import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import howdy/admin/internal/config.{type Config}
import howdy/content.{type Content}
import howdy/controller.{type Context}
import howdy/cookie
import howdy/service
import howdy/ui
import howdy/ui/alert
import howdy/ui/blocks/app_shell.{Group, Link}
import howdy/ui/page
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html

/// Render `content` in the shell, with `current` marking the sidebar link.
pub fn page(
  config: Config,
  ctx: Context,
  current current: String,
  heading heading: String,
  live live: Bool,
  content content: List(Element(msg)),
) -> Response(Content) {
  use theme <- cookie.string_or(ctx, "theme", default: "system")
  use sidebar <- cookie.string_or(ctx, "sidebar", default: "expanded")
  let document =
    page.new(heading <> " · " <> config.name)
    |> page.theme(theme)
    |> page.body([
      app_shell.app_shell(
        app: config.name,
        collapsed: sidebar == "collapsed",
        current: config.prefix <> current,
        navigation: navigation(config),
        footer: [ui.muted("Development only")],
        heading:,
        actions: [ui.theme_toggle([text("Theme")], from: "light", to: "dark")],
        content:,
      ),
    ])
  case live {
    True -> page.live(document)
    False -> document
  }
  |> page.respond(ctx)
}

fn navigation(config: Config) -> List(app_shell.Group) {
  let at = config.path(config, _)
  list.flatten([
    [Group("Howdy", [Link(at(""), "Overview")])],
    case config.database {
      Some(_) -> [Group("Database", [Link(at("/data"), "Tables")])]
      None -> []
    },
    case config.identity {
      Some(_) -> [
        Group(
          "Auth",
          list.append(
            [Link(at("/users"), "Users"), Link(at("/groups"), "Groups")],
            case config.authorization {
              Some(_) -> [Link(at("/roles"), "Roles")]
              None -> []
            },
          ),
        ),
      ]
      None -> []
    },
    case config.outbox, config.mailer {
      None, None -> []
      outbox, mailer -> [
        Group(
          "Mail",
          list.flatten([
            case outbox {
              Some(_) -> [Link(at("/mail"), "Outbox")]
              None -> []
            },
            case mailer {
              Some(_) -> [Link(at("/mail/previews"), "Previews")]
              None -> []
            },
          ]),
        ),
      ]
    },
    case config.flags {
      Some(_) -> [
        Group("Flags", [
          Link(at("/flags"), "Flags"),
          Link(at("/flags/groups"), "Groups"),
        ]),
      ]
      None -> []
    },
    case config.jobs {
      Some(_) -> [Group("Jobs", [Link(at("/jobs"), "Jobs")])]
      None -> []
    },
    case config.api {
      Some(_) -> [Group("API", [Link(at("/api"), "Endpoints")])]
      None -> []
    },
    case config.recorder {
      Some(_) -> [
        Group("Telemetry", [
          Link(at("/telemetry"), "Traces"),
          Link(at("/telemetry/logs"), "Logs"),
        ]),
      ]
      None -> []
    },
  ])
}

/// A `303 See Other` to `location`, after a form has been handled.
pub fn redirect(location: String) -> Response(Content) {
  response.new(303)
  |> response.set_header("location", location)
  |> response.set_body(content.Text(""))
}

/// A page explaining a failed operation, in place of the page it failed on.
pub fn failure(
  config: Config,
  ctx: Context,
  current current: String,
  heading heading: String,
  error error: service.Error,
  back back: String,
) -> Response(Content) {
  page(config, ctx, current:, heading:, live: False, content: [
    problem(error),
    ui.p([ui.link(back, [text("Back")])]),
  ])
}

/// `failure` for a page whose way back is the section it belongs to.
pub fn failed(
  config: Config,
  ctx: Context,
  current current: String,
  heading heading: String,
  error error: service.Error,
) -> Response(Content) {
  failure(
    config,
    ctx,
    current:,
    heading:,
    error:,
    back: config.path(config, current),
  )
}

/// An alert describing a service error.
pub fn problem(error: service.Error) -> Element(msg) {
  ui.alert(alert.Danger, [], [
    ui.alert_title([text(title(error))]),
    ui.alert_description([text(service.message(error))]),
  ])
}

fn title(error: service.Error) -> String {
  case error {
    service.NotFound(_) -> "Not found"
    service.Invalid(_) -> "The database refused it"
    service.Conflict(_) -> "Conflict"
    service.Unauthorized -> "Unauthorized"
    service.Forbidden -> "Forbidden"
    service.UnsupportedMediaType(_) -> "Unsupported media type"
    service.Internal(_) -> "Something went wrong"
    service.Validation(_) -> "Invalid input"
    service.TooManyRequests(_) -> "Too many requests"
    service.Coded(error:, ..) -> title(error)
  }
}

/// Label and value pairs, one per row.
pub fn facts(pairs: List(#(String, String))) -> Element(msg) {
  ui.table([], [
    ui.table_body(
      [],
      list.map(pairs, fn(pair) {
        ui.table_row([], [
          ui.table_head([], [text(pair.0)]),
          ui.table_cell([], [text(pair.1)]),
        ])
      }),
    ),
  ])
}

/// Inline code in the admin's monospace face.
pub fn mono(content: String) -> Element(msg) {
  html.code([attribute.style("font-family", "var(--howdy-font-mono)")], [
    text(content),
  ])
}

/// A short form of a value for a cell.
pub fn clip(value: String) -> String {
  case string.length(value) > 80 {
    True -> string.slice(value, 0, 77) <> "…"
    False -> value
  }
}
