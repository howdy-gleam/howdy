//// The first page: what the admin found, and where to go.

import gleam/dynamic/decode
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gloo/repo.{type Repo}
import howdy/admin/internal/accounts/groups as group_pages
import howdy/admin/internal/accounts/users as user_pages
import howdy/admin/internal/api_spec
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/format
import howdy/admin/internal/layout
import howdy/admin/internal/schema
import howdy/auth.{type Auth}
import howdy/auth/group
import howdy/authorization
import howdy/content.{type Content}
import howdy/controller.{type Context, type Controller}
import howdy/database.{Postgres, Sqlite}
import howdy/flags.{type Flags}
import howdy/jobs
import howdy/mail
import howdy/mail/outbox.{type Outbox}
import howdy/service
import howdy/telemetry/recorder.{type Recorder}
import howdy/ui
import lustre/element.{type Element, text}

pub fn controller(config: Config) -> Controller {
  controller.new(config.prefix)
  |> controller.get("/", fn(ctx) { index(config, ctx) })
}

fn index(config: Config, ctx: Context) -> Response(Content) {
  layout.page(
    config,
    ctx,
    current: "",
    heading: "Overview",
    live: False,
    content: [
      ui.stack([], [
        case config.database {
          Some(repo) -> database_card(config, repo)
          None ->
            absent(
              "howdy_database",
              "Not registered. Pass your Gloo Repo to admin.database to browse and edit tables.",
            )
        },
        case config.identity {
          Some(identity) -> auth_card(config, identity)
          None ->
            absent(
              "howdy_auth",
              "Not registered. Pass your auth.Auth to admin.auth to manage users and groups.",
            )
        },
        case config.outbox, config.mailer {
          None, None ->
            absent(
              "howdy_mail",
              "Not registered. Pass an outbox to admin.mail to read the mail your app sends, and previews to admin.mail_previews.",
            )
          box, _ -> mail_card(config, box)
        },
        case config.recorder {
          Some(recorder) -> telemetry_card(config, recorder)
          None ->
            absent(
              "howdy_telemetry",
              "Not registered. Start telemetry with a recorder and pass it to admin.telemetry to see each request's queries, calls and logs.",
            )
        },
        case config.flags {
          Some(features) -> flags_card(config, features)
          None ->
            absent(
              "howdy_flags",
              "Not registered. Pass your running flags to admin.flags to switch them off, roll them out and see their history.",
            )
        },
        case config.jobs {
          Some(runner) -> jobs_card(config, runner)
          None ->
            absent(
              "howdy_jobs",
              "Not registered. Pass your jobs runner to admin.jobs to see queues, schedules and failed jobs, and retry them.",
            )
        },
        case config.api {
          Some(api) -> api_card(config, api)
          None ->
            absent(
              "howdy_openapi",
              "No OpenAPI document found. Serve one with openapi.serve before admin.mount to browse and call your endpoints here.",
            )
        },
      ]),
    ],
  )
}

fn jobs_card(config: Config, runner: jobs.Runner) -> Element(msg) {
  case jobs.counts(jobs.repo(runner)) {
    Error(error) -> layout.problem(error)
    Ok(counts) -> {
      let total = fn(state) {
        list.filter(counts, fn(count) { count.state == state })
        |> list.fold(0, fn(sum, count) { sum + count.count })
      }
      ui.card([], [
        ui.card_header([], [
          ui.card_title([text("howdy_jobs")]),
          ui.card_description([
            text(format.describe(list.length(jobs.queues(runner)), "queue")),
            text(" · " <> int.to_string(total(jobs.Available)) <> " waiting"),
            text(" · " <> int.to_string(total(jobs.Scheduled)) <> " scheduled"),
            text(" · " <> int.to_string(total(jobs.Executing)) <> " running"),
            text(" · " <> int.to_string(total(jobs.Failed)) <> " failed"),
          ]),
        ]),
        ui.card_footer([], [
          ui.link(config.path(config, "/jobs"), [text("Manage jobs")]),
        ]),
      ])
    }
  }
}

fn flags_card(config: Config, features: Flags) -> Element(msg) {
  case flags.settings(features) {
    Error(error) -> layout.problem(error)
    Ok(stored) -> {
      let killed = list.count(stored, fn(row) { { row.1 }.killed })
      let ramping =
        list.count(stored, fn(row) {
          case { row.1 }.ramp {
            Some(flags.Ramp(next: Some(_), ..)) -> True
            _ -> False
          }
        })
      ui.card([], [
        ui.card_header([], [
          ui.card_title([text("howdy_flags")]),
          ui.card_description([
            text(format.describe(
              list.length(flags.defined(features)),
              "registered flag",
            )),
            text(" · " <> int.to_string(list.length(stored)) <> " changed"),
            text(" · " <> int.to_string(killed) <> " killed"),
            text(" · " <> int.to_string(ramping) <> " ramping"),
            text(
              " · kept in "
              <> flags.store_name(features)
              <> case flags.writable(features) {
                True -> ""
                False -> ", read-only"
              },
            ),
          ]),
        ]),
        ui.card_footer([], [
          ui.link(config.path(config, "/flags"), [text("Manage flags")]),
        ]),
      ])
    }
  }
}

fn database_card(config: Config, repo: Repo) -> Element(msg) {
  let facts = {
    use backend <- result.try(database.backend(repo))
    use tables <- result.try(schema.tables(repo))
    Ok(#(backend, tables))
  }
  case facts {
    Error(error) -> layout.problem(error)
    Ok(#(backend, tables)) ->
      ui.card([], [
        ui.card_header([], [
          ui.card_title([text("howdy_database")]),
          ui.card_description([
            text(case backend {
              Postgres -> "PostgreSQL"
              Sqlite -> "SQLite"
            }),
            text(" · " <> format.describe(list.length(tables), "table")),
          ]),
        ]),
        ui.card_content([], [
          migrations(repo),
        ]),
        ui.card_footer([], [
          ui.link(config.path(config, "/data"), [text("Browse tables")]),
        ]),
      ])
  }
}

/// The migration ledger, if `howdy/migration` has created one.
fn migrations(repo: Repo) -> Element(msg) {
  let ledger = {
    use conn <- database.connect(repo)
    repo.all(
      conn,
      "SELECT package, MAX(version) FROM howdy_migrations GROUP BY package ORDER BY package",
      [],
      {
        use package <- decode.field(0, decode.string)
        use version <- decode.field(1, decode.int)
        decode.success(#(package, version))
      },
    )
    |> result.replace_error(service.NotFound("ledger"))
  }
  case ledger {
    Error(_) ->
      ui.p([ui.muted("No migration ledger: howdy/migration has not run here.")])
    Ok([]) -> ui.p([ui.muted("The migration ledger is empty.")])
    Ok(packages) ->
      ui.p([
        text("Migrated packages: "),
        text(
          list.map(packages, fn(entry) {
            entry.0 <> " v" <> int.to_string(entry.1)
          })
          |> string.join(", "),
        ),
      ])
  }
}

fn auth_card(config: Config, identity: Auth) -> Element(msg) {
  let facts = {
    use users <- result.try(user_pages.count_users(identity))
    use groups <- result.try(group_pages.count_groups(identity))
    Ok(#(users, groups))
  }
  case facts {
    Error(error) -> layout.problem(error)
    Ok(#(users, groups)) -> {
      let enabled = fn(flag, name) {
        case flag {
          True -> [name]
          False -> []
        }
      }
      let methods =
        list.flatten([
          enabled(auth.email_tokens_enabled(identity), "email tokens"),
          enabled(auth.passwords_enabled(identity), "passwords"),
          enabled(auth.passkeys_enabled(identity), "passkeys"),
          enabled(auth.mfa_enabled(identity), "MFA"),
          enabled(auth.sso_enabled(identity), "enterprise SSO"),
          list.map(auth.providers(identity), fn(provider) { provider.1 }),
        ])
      ui.card([], [
        ui.card_header([], [
          ui.card_title([text("howdy_auth")]),
          ui.card_description([
            text(format.describe(users, "user")),
            text(" · " <> format.describe(groups, "group")),
            text(" · group mode " <> group.mode_name(auth.group_mode(identity))),
            case config.authorization {
              Some(access) ->
                text(
                  " · "
                  <> case authorization.roles(access) {
                    Ok(roles) -> format.describe(list.length(roles), "role")
                    Error(_) -> "roles unavailable"
                  },
                )
              None -> element.none()
            },
          ]),
        ]),
        ui.card_content([], [
          ui.p([
            text("Origin " <> auth.origin(identity)),
          ]),
          ui.p([
            text("Login methods: "),
            text(case methods {
              [] -> "none enabled"
              _ -> string.join(methods, ", ")
            }),
          ]),
          ui.p([
            text("Registration "),
            text(case auth.registration_enabled(identity) {
              True -> "open"
              False -> "closed"
            }),
          ]),
        ]),
        ui.card_footer([], [
          ui.row([], [
            ui.link(config.path(config, "/users"), [text("Users")]),
            ui.link(config.path(config, "/groups"), [text("Groups")]),
            case config.authorization {
              Some(_) -> ui.link(config.path(config, "/roles"), [text("Roles")])
              None -> element.none()
            },
          ]),
        ]),
      ])
    }
  }
}

fn mail_card(config: Config, box: Option(Outbox)) -> Element(msg) {
  ui.card([], [
    ui.card_header([], [
      ui.card_title([text("howdy_mail")]),
      ui.card_description([
        text(case box {
          Some(box) ->
            case outbox.messages(box) {
              Ok(messages) ->
                format.describe(list.length(messages), "message")
                <> " in the outbox"
              Error(error) ->
                "The outbox could not be read: " <> mail.error_to_string(error)
            }
          None -> "No outbox registered"
        }),
        text(" · " <> format.describe(list.length(config.previews), "preview")),
      ]),
    ]),
    ui.card_footer([], [
      ui.row([], [
        case box {
          Some(_) -> ui.link(config.path(config, "/mail"), [text("Outbox")])
          None -> element.none()
        },
        case config.mailer {
          Some(_) ->
            ui.link(config.path(config, "/mail/previews"), [text("Previews")])
          None -> element.none()
        },
      ]),
    ]),
  ])
}

fn telemetry_card(config: Config, recorder: Recorder) -> Element(msg) {
  let traces = recorder.traces(recorder, limit: 1000)
  let failing = list.count(traces, fn(trace) { trace.failed > 0 })
  ui.card([], [
    ui.card_header([], [
      ui.card_title([text("howdy_telemetry")]),
      ui.card_description([
        text(
          format.describe(list.length(traces), "trace")
          <> " recorded · "
          <> int.to_string(failing)
          <> " with failures",
        ),
      ]),
    ]),
    ui.card_footer([], [
      ui.row([], [
        ui.link(config.path(config, "/telemetry"), [text("Traces")]),
        ui.link(config.path(config, "/telemetry/logs"), [text("Logs")]),
      ]),
    ]),
  ])
}

fn api_card(config: Config, api: config.Api) -> Element(msg) {
  let served =
    list.find(api.documents, fn(served) { served.main })
    |> result.lazy_or(fn() { list.first(api.documents) })
  let endpoints = case served {
    Ok(served) ->
      case api_spec.parse(served.document) {
        Ok(document) -> list.length(document.operations)
        Error(_) -> 0
      }
    Error(Nil) -> 0
  }
  let versions = list.count(api.documents, fn(served) { !served.main })
  ui.card([], [
    ui.card_header([], [
      ui.card_title([text("howdy_openapi")]),
      ui.card_description([
        text(
          "Found in the app · "
          <> format.describe(endpoints, "endpoint")
          <> case versions {
            0 -> ""
            count -> " · " <> format.describe(count, "version")
          },
        ),
      ]),
    ]),
    ui.card_footer([], [
      ui.link(config.path(config, "/api"), [text("Endpoints")]),
    ]),
  ])
}

fn absent(name: String, why: String) -> Element(msg) {
  ui.card([], [
    ui.card_header([], [ui.card_title([text(name)])]),
    ui.card_content([], [ui.p([ui.muted(why)])]),
  ])
}
