//// A development admin area for a Howdy app. Mount it from your `dev/`
//// entry point, and it appears at `/_howdy`:
////
//// ```gleam
//// import howdy/admin
//// import howdy/dev
////
//// pub fn main() {
////   let db = my_app.open_database()
////   let identity = my_app.identity(db)
////   let assert Ok(_) =
////     dev.start(fn() {
////       my_app.app(db, identity)
////       |> admin.mount(admin.new() |> admin.database(db) |> admin.auth(identity))
////     })
////   process.sleep_forever()
//// }
//// ```
////
//// Gleam has no way to find out which packages an app uses at runtime, and
//// no registry of the values it built, so the app hands the admin what it
//// has. What is registered decides what the admin shows:
////
//// - `database`: the tables of the Gloo Repo, on PostgreSQL or SQLite, in a
////   grid that refreshes as the data changes, with forms to insert, edit
////   and delete rows.
//// - `auth`: users and groups, creating and suspending users, moving them
////   between groups, and signing in to the app as any user. Registering
////   auth registers its database too.
//// - `authorization`: roles and their permissions, and which users hold
////   them, in every scope.
//// - `mail`: the messages a `howdy/mail/outbox` keeps, as they arrive.
//// - `mail_previews`: your email templates rendered from sample data, and
////   sent on demand.
//// - `telemetry`: the traces and log lines a `howdy/telemetry/recorder`
////   holds, as they happen: each request as a timeline of its queries,
////   remote calls and emails, with repeated and slow queries pointed out.
//// - `flags`: the feature flags of a `howdy/flags`: their kill switches,
////   who they are allowed or blocked for, their history with undo, and the
////   groups rules can name. Rollouts are shown, not set.
//// - `jobs`: the background jobs of a `howdy/jobs` runner: each queue's
////   jobs by state, pausing queues, the schedules it keeps, and each job
////   with its errors, to retry, cancel or delete.
////
//// Some things need no registering, because `mount` can see them in the
//// app:
////
//// - The OpenAPI documents `howdy/openapi` serves: every endpoint, with a
////   form to call it and see the response. Calls go straight through the
////   app, anonymously or as any user when `auth` is registered.
////
//// ## Development only
////
//// There is no login: anyone who can reach the pages can read and change
//// every row and sign in as anyone. Keep `howdy_admin` a dev dependency,
//// mount it only from `dev/`, and serve it from `howdy/dev`, which listens
//// on loopback. The pages also refuse a request whose `Host` is not
//// `localhost`, `127.0.0.1` or `[::1]` unless `allow_hosts` says otherwise,
//// so a browser on another machine, or a DNS-rebinding page, gets `403`.
//// Writes must also come from the admin's own origin: a `POST` whose
//// `Sec-Fetch-Site` or `Origin` header says another site sent it gets
//// `403` too, so a page you visit while the admin runs cannot post to it.

import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gloo/repo.{type Repo}
import howdy.{type App}
import howdy/admin/internal/accounts
import howdy/admin/internal/api as api_pages
import howdy/admin/internal/config.{type Config, Config}
import howdy/admin/internal/data
import howdy/admin/internal/flags as flag_pages
import howdy/admin/internal/jobs as job_pages
import howdy/admin/internal/mail as mail_pages
import howdy/admin/internal/notify
import howdy/admin/internal/overview
import howdy/admin/internal/roles
import howdy/admin/internal/telemetry as telemetry_pages
import howdy/auth.{type Auth}
import howdy/authorization.{type Authorization}
import howdy/content
import howdy/controller.{type Controller}
import howdy/flags.{type Flags}
import howdy/jobs.{type Runner}
import howdy/mail.{type Mailer}
import howdy/mail/outbox.{type Outbox}
import howdy/mail/preview.{type Preview}
import howdy/openapi
import howdy/service
import howdy/telemetry/recorder.{type Recorder}
import pog

/// An admin area under construction.
pub opaque type Admin {
  Admin(config: Config)
}

/// An admin at `/_howdy` that knows about nothing yet.
pub fn new() -> Admin {
  Admin(Config(
    prefix: "/_howdy",
    name: "Howdy admin",
    database: None,
    identity: None,
    authorization: None,
    outbox: None,
    previews: [],
    mailer: None,
    recorder: None,
    flags: None,
    jobs: None,
    api: None,
    hosts: [
      "localhost",
      "127.0.0.1",
      "[::1]",
    ],
    listen: None,
  ))
}

/// How the grid's listening connection reaches PostgreSQL, so it hears
/// about changes through `NOTIFY` rather than polling. Give the same
/// settings the app's pool uses, such as `pog.url_config(name, url)`; the
/// pool name in them is not used. Only needed for a pool the app did not
/// open with `howdy/database/postgres`, whose settings
/// `postgres.listen` cannot find: without them the grid polls. Does
/// nothing on SQLite.
pub fn notify_via(admin: Admin, config: pog.Config) -> Admin {
  Admin(Config(..admin.config, listen: Some(config)))
}

/// Mount the pages somewhere other than `/_howdy`.
pub fn at(admin: Admin, prefix: String) -> Admin {
  let prefix =
    "/"
    <> {
      string.split(prefix, "/")
      |> list.filter(fn(segment) { segment != "" })
      |> string.join("/")
    }
  let assert True = prefix != "/"
    as "howdy/admin: the prefix cannot be the root"
  Admin(Config(..admin.config, prefix:))
}

/// The name shown in the sidebar. Defaults to "Howdy admin".
pub fn named(admin: Admin, name: String) -> Admin {
  Admin(Config(..admin.config, name:))
}

/// Browse and edit the tables of this Repo.
pub fn database(admin: Admin, repo: Repo) -> Admin {
  Admin(Config(..admin.config, database: Some(repo)))
}

/// Manage the users and groups of this auth configuration, and sign in as
/// them. Its Repo is browsed too, unless `database` was given another.
pub fn auth(admin: Admin, identity: Auth) -> Admin {
  let database = case admin.config.database {
    Some(repo) -> Some(repo)
    None -> Some(auth.repo(identity))
  }
  Admin(Config(..admin.config, identity: Some(identity), database:))
}

/// Manage roles, their permissions and who holds them. Needs `auth` too,
/// since roles are assigned to users.
pub fn authorization(admin: Admin, access: Authorization) -> Admin {
  Admin(Config(..admin.config, authorization: Some(access)))
}

/// Show the messages this outbox keeps, as they arrive: the rendered HTML,
/// the text, the headers and the raw source, with links that open.
pub fn mail(admin: Admin, box: Outbox) -> Admin {
  Admin(Config(..admin.config, outbox: Some(box)))
}

/// Render these email previews, each built from its sample data every time
/// it is shown, and send one on demand through `mailer`. Previews from
/// several calls are shown together; the last mailer given is used.
///
/// The mailer's default sender applies, and its adapter really sends:
/// point it at the outbox, or at a local SMTP server such as Mailpit, not
/// at production.
pub fn mail_previews(
  admin: Admin,
  previews: List(Preview),
  send_with mailer: Mailer,
) -> Admin {
  Admin(
    Config(
      ..admin.config,
      previews: list.append(admin.config.previews, previews),
      mailer: Some(mailer),
    ),
  )
}

/// Show the traces and log lines `recorder` holds. Start telemetry with
/// `telemetry.record(recorder)` so it has something to hold:
///
/// ```gleam
/// let recorder = recorder.new(keep: 200)
/// let assert Ok(Nil) =
///   telemetry.new("my-app") |> telemetry.record(recorder) |> telemetry.start
/// admin.new() |> admin.telemetry(recorder)
/// ```
pub fn telemetry(admin: Admin, recorder: Recorder) -> Admin {
  Admin(Config(..admin.config, recorder: Some(recorder)))
}

/// Manage these feature flags: turn them off at once, allow or block them
/// for users, organizations and groups, and undo any change. Rollouts and
/// ramps are shown but set from the app. Changes are recorded as made by
/// `howdy_admin`.
pub fn flags(admin: Admin, features: Flags) -> Admin {
  Admin(Config(..admin.config, flags: Some(features)))
}

/// Show and manage the jobs of this runner, in the database it uses: each
/// queue's jobs by state, pausing queues, the runner's schedules, and each
/// job with its errors, to retry, cancel or delete. The runner need not be
/// running in this process.
pub fn jobs(admin: Admin, runner: Runner) -> Admin {
  Admin(Config(..admin.config, jobs: Some(runner)))
}

/// Exact request hostnames (without port) the pages answer, replacing the
/// loopback names. Anyone who can reach an allowed host owns your data.
pub fn allow_hosts(admin: Admin, hosts: List(String)) -> Admin {
  let assert True =
    list.all(hosts, fn(host) {
      host != "" && !string.contains(host, "*") && !string.contains(host, "/")
    })
    as "howdy/admin: allow_hosts requires exact hostnames, not URLs or wildcards"
  Admin(Config(..admin.config, hosts:))
}

/// Add the admin's routes to an app. Mount it last: the admin looks at the
/// app as it is here. If the app serves OpenAPI documents with
/// `howdy/openapi`, the admin finds them and adds pages to read them and
/// call the endpoints.
pub fn mount(app: App, admin: Admin) -> App {
  list.fold(controllers(detect(admin, app)), app, howdy.controller)
}

/// Find what the admin can see in the app itself, without being told.
fn detect(admin: Admin, app: App) -> Admin {
  case openapi.served(app) {
    [] -> admin
    documents ->
      Admin(Config(..admin.config, api: Some(config.Api(app:, documents:))))
  }
}

/// The admin's controllers, for mounting them yourself. The API pages need
/// the app, so only `mount` adds them.
pub fn controllers(admin: Admin) -> List(Controller) {
  let config = admin.config
  list.flatten([
    [overview.controller(config)],
    case config.database {
      Some(repo) -> [data.controller(config, repo)]
      None -> []
    },
    case config.identity {
      Some(identity) -> [accounts.controller(config, identity)]
      None -> []
    },
    case config.identity, config.authorization {
      Some(identity), Some(access) -> [
        roles.controller(config, identity, access),
      ]
      _, _ -> []
    },
    case config.outbox, config.mailer {
      None, None -> []
      _, _ -> [mail_pages.controller(config)]
    },
    case config.recorder {
      Some(recorder) -> [telemetry_pages.controller(config, recorder)]
      None -> []
    },
    case config.flags {
      Some(features) -> [flag_pages.controller(config, features)]
      None -> []
    },
    case config.jobs {
      Some(runner) -> [job_pages.controller(config, runner)]
      None -> []
    },
    case config.api {
      Some(api) -> [api_pages.controller(config, api)]
      None -> []
    },
  ])
  |> list.map(controller.middleware(_, only_hosts(config)))
}

/// Refuse requests from hosts other than the allowed ones. `request.host`
/// carries no port, so entries are compared whole.
///
/// Writes (`POST`, `PUT`, `PATCH`, `DELETE`) must also come from the admin's
/// own origin, or a page on another site could make the browser send one.
/// A `Sec-Fetch-Site` of `same-origin` or `none` (typed into the address
/// bar) passes. Without that header, an `Origin` passes when its host is
/// an allowed one and it names the same host and port the request was
/// sent to. Anything else gets `403`. This mirrors `howdy/csrf`, which
/// cannot be reused here because it takes whole origins with a scheme and
/// the admin only knows host names. `GET`, `HEAD` and `OPTIONS`, including
/// the grid's WebSocket upgrade, are not checked.
fn only_hosts(config: Config) -> controller.Middleware {
  fn(ctx: controller.Context, next) {
    case list.contains(config.hosts, ctx.request.host) {
      False -> service.error_response(ctx, service.Forbidden)
      True ->
        case ctx.request.method {
          http.Get | http.Head | http.Options -> next(ctx)
          _ ->
            case same_origin(ctx, config.hosts) {
              True -> next(ctx)
              False ->
                response.new(403)
                |> response.set_body(content.Text(
                  "Forbidden: the admin only accepts writes from its own origin. This request's Sec-Fetch-Site or Origin header says another site sent it.",
                ))
            }
        }
    }
  }
}

/// Whether a write came from the admin's own origin, by the browser's
/// fetch metadata first and the `Origin` header otherwise. Fails closed when
/// neither is present, or either is sent more than once.
fn same_origin(ctx: controller.Context, hosts: List(String)) -> Bool {
  case headers(ctx, "sec-fetch-site"), headers(ctx, "origin") {
    ["same-origin"], _ | ["none"], _ -> True
    [], [origin] ->
      case string.split_once(origin, "://") {
        Ok(#(_scheme, authority)) ->
          authority == request_authority(ctx)
          && list.contains(hosts, authority_host(authority))
        Error(Nil) -> False
      }
    _, _ -> False
  }
}

/// The host and port this request was sent to, as an `Origin` would name
/// them: the `Host` header when there is one, else the parsed request.
fn request_authority(ctx: controller.Context) -> String {
  case request.get_header(ctx.request, "host") {
    Ok(host) -> string.lowercase(host)
    Error(Nil) ->
      case ctx.request.port {
        Some(port) -> ctx.request.host <> ":" <> int.to_string(port)
        None -> ctx.request.host
      }
  }
}

/// `localhost:8787` becomes `localhost`; `[::1]:8787` becomes `[::1]`.
fn authority_host(authority: String) -> String {
  case string.ends_with(authority, "]") {
    True -> authority
    False ->
      case list.reverse(string.split(authority, ":")) {
        [_port, first, ..rest] ->
          string.join(list.reverse([first, ..rest]), ":")
        _ -> authority
      }
  }
}

/// Every value sent for a header, lowercased.
fn headers(ctx: controller.Context, name: String) -> List(String) {
  list.filter_map(ctx.request.headers, fn(header) {
    case string.lowercase(header.0) == name {
      True -> Ok(string.lowercase(header.1))
      False -> Error(Nil)
    }
  })
}

/// Drop the `howdy_admin_notify` function and triggers the grid installs on
/// PostgreSQL to hear about changes. They are harmless to leave, and
/// `howdy/migration` ignores them, but this puts a database back exactly as
/// it was. Does nothing on SQLite.
pub fn remove_notify_triggers(repo: Repo) -> service.Result(Nil) {
  notify.uninstall(repo)
}

/// Where the pages are, for linking to them.
pub fn prefix(admin: Admin) -> String {
  admin.config.prefix
}

/// Whether a database was registered.
pub fn has_database(admin: Admin) -> Bool {
  option.is_some(admin.config.database)
}

/// Whether authorization was registered.
pub fn has_authorization(admin: Admin) -> Bool {
  option.is_some(admin.config.authorization)
}

/// Whether an outbox was registered.
pub fn has_mail(admin: Admin) -> Bool {
  option.is_some(admin.config.outbox)
}

/// How many email previews were registered.
pub fn preview_count(admin: Admin) -> Int {
  list.length(admin.config.previews)
}

/// Whether a telemetry recorder was registered.
pub fn has_telemetry(admin: Admin) -> Bool {
  option.is_some(admin.config.recorder)
}

/// Whether feature flags were registered.
pub fn has_flags(admin: Admin) -> Bool {
  option.is_some(admin.config.flags)
}

/// Whether a jobs runner was registered.
pub fn has_jobs(admin: Admin) -> Bool {
  option.is_some(admin.config.jobs)
}

/// Whether auth was registered.
pub fn has_auth(admin: Admin) -> Bool {
  option.is_some(admin.config.identity)
}
