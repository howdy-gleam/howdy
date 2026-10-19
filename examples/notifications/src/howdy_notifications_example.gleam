//// Notifications in a Howdy app. Run with `gleam run` from
//// `examples/notifications`; it listens on 127.0.0.1:8792. Open
//// http://localhost:8792 and sign in as Ana, then open it again in another
//// browser, or a private window, and sign in as Bo.
////
//// - Sending a notification is a plain form post. The page it redirects
////   to shows a flash message, "Sent to Bo", as a toast.
//// - Bo's bell counts it straight away, a toast says what arrived, and
////   the live view below the form hears it too. Reading it in one tab
////   updates the count in every other.
//// - A mention is emailed as well, thirty seconds later, unless it was
////   read first. Mail goes to an outbox in `tmp/mail` as `.eml` files.
//// - The bell's panel offers to turn on browser notifications, which
////   arrive even with the tab closed. Set `VAPID_PUBLIC_KEY` and
////   `VAPID_PRIVATE_KEY` (make them with
////   `gleam run -m howdy/notifications/web_push`) so subscriptions survive
////   a restart.
////
//// Signing in is pretend: a cookie naming the user. A real app takes the
//// user from `howdy_auth`, as the comments on `identify` say.

import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gloo/adapter/sqlite
import gloo/repo.{type Repo}
import howdy
import howdy/content.{type Content}
import howdy/controller.{type Context}
import howdy/cookie
import howdy/csrf
import howdy/database
import howdy/env
import howdy/flash
import howdy/form
import howdy/jobs
import howdy/mail
import howdy/mail/outbox
import howdy/migration
import howdy/notifications.{Delivery, EmailNow, default_delivery}
import howdy/notifications/web_push
import howdy/service
import howdy/ui
import howdy/ui/bell
import howdy/ui/button.{Outline, Primary}
import howdy/ui/live
import howdy/ui/page
import howdy/ui/theme
import howdy/ui/toast
import howdy_notifications_example/feed
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html
import simplifile

pub const origin = "http://localhost:8792"

/// The pretend users, by ID.
const people = [#("ana", "Ana"), #("bo", "Bo"), #("cy", "Cy")]

pub type Services {
  Services(
    notifier: notifications.Notifier,
    push: web_push.WebPush,
    flash: flash.Flash,
  )
}

pub fn main() -> Nil {
  let assert Ok(Nil) = simplifile.create_directory_all("tmp")
  let assert Ok(repo) = sqlite.start(sqlite.file("tmp/notifications.db"))
  let assert Ok(Nil) = database.sqlite_defaults(repo)
  let assert Ok(Nil) =
    migration.run(repo, [jobs.schema(), notifications.schema()])
  let assert Ok(box) = outbox.start_in("tmp/mail")
  let services = services(repo, mail.mailer(outbox.adapter(box)), keys())

  // Supervised inside an OTP application: restarted on a crash, drained on
  // SIGTERM. The jobs runner sends email and push; the server comes last,
  // so it stops first. A local demo, so it listens on 127.0.0.1:8792 only.
  let runner = jobs.runner(repo) |> notifications.handle_jobs(services.notifier)
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(jobs.supervised(runner))
    |> supervisor.add(howdy.supervised(
      app(services) |> howdy.bind(to: "127.0.0.1") |> howdy.listening(on: 8792),
    ))
    |> howdy.start_application(name: "howdy_notifications_server")
  process.sleep_forever()
}

fn keys() -> web_push.Keys {
  case env.get("VAPID_PUBLIC_KEY"), env.get("VAPID_PRIVATE_KEY") {
    Ok(public), Ok(private) -> {
      let assert Ok(keys) = web_push.keys(public:, private:)
        as "VAPID_PUBLIC_KEY and VAPID_PRIVATE_KEY are not a key pair"
      keys
    }
    _, _ -> {
      io.println(
        "No VAPID keys in the environment, so browser notifications use new"
        <> " ones until the next restart.",
      )
      web_push.generate_keys()
    }
  }
}

pub fn services(repo: Repo, mailer: mail.Mailer, keys: web_push.Keys) {
  let mailer =
    mailer
    |> mail.default_from(mail.named("Howdy example", "hello@example.com"))
  let notifier =
    notifications.new(repo)
    |> notifications.with_base_url(origin)
    // Mentions are emailed too; everything else stays in the app.
    |> notifications.with_defaults(fn(kind) {
      case kind {
        "mention" -> Delivery(..default_delivery, email: EmailNow)
        _ -> default_delivery
      }
    })
    |> notifications.email_after(30)
    |> notifications.with_email(
      mailer,
      address: fn(user) {
        list.key_find(people, user)
        |> result.map(fn(name) { mail.named(name, user <> "@example.com") })
      },
      render: fn(notification) {
        mail.message()
        |> mail.subject(notification.title)
        |> mail.text(
          notification.body
          <> "\n\n"
          <> origin
          <> option.unwrap(notification.link, "/"),
        )
      },
    )
  let push = web_push.new(notifier, keys, contact: "mailto:hello@example.com")
  Services(
    notifier: notifications.with_push(notifier, web_push.deliver(push)),
    push:,
    flash: flash.new(secret: env.get_or("SECRET_KEY_BASE", demo_secret)),
  )
}

/// For the demo only: a real app reads its secret from the environment.
const demo_secret = "howdy-notifications-example-not-a-real-secret"

// -- Routes ------------------------------------------------------------------

pub fn app(services: Services) -> howdy.App {
  // With howdy_auth this is:
  //   auth.required(auth)(ctx) |> result.map(fn(p) { p.user.id })
  let identify = fn(ctx) {
    current_user(ctx) |> result.replace_error(service.Unauthorized)
  }
  howdy.new()
  |> howdy.middleware(
    csrf.middleware(csrf.new([origin, "http://127.0.0.1:8792"])),
  )
  |> howdy.controller(pages(services))
  |> howdy.controller(notifications.routes(
    services.notifier,
    at: "/notifications",
    identify:,
  ))
  |> howdy.controller(web_push.routes(services.push, at: "/push", identify:))
  |> howdy.controller(
    controller.new("/live")
    |> controller.get("/feed", fn(ctx) {
      case current_user(ctx) {
        Ok(user) -> {
          let unread =
            notifications.unread_count(services.notifier, user)
            |> result.unwrap(0)
          live.serve(ctx, feed.app(), with: #(user, unread))
        }
        Error(Nil) -> controller.status(ctx, 401)
      }
    }),
  )
  |> howdy.controller(ui.stylesheet(
    at: "/assets/ui.css",
    themes: theme.default_themes(),
  ))
}

fn pages(services: Services) {
  controller.new("/")
  |> controller.get("/", fn(ctx) { home(ctx, services) })
  |> controller.get("/inbox", fn(ctx) { inbox(ctx, services) })
  |> controller.post("/sign-in", fn(ctx) {
    use fields <- form.read(ctx)
    let user = form.value(fields, "user")
    case list.key_find(people, user) {
      Ok(name) ->
        see_other("/")
        |> cookie.set("demo_user", user, cookie.defaults())
        |> flash.put(services.flash, flash.Info, "Signed in as " <> name)
      Error(Nil) -> see_other("/")
    }
  })
  |> controller.post("/sign-out", fn(_ctx) {
    see_other("/")
    |> cookie.delete("demo_user", cookie.defaults())
    |> flash.put(services.flash, flash.Info, "Signed out")
  })
  |> controller.post("/send", fn(ctx) { send(ctx, services) })
}

/// Send what the form asks for, then redirect home with a flash message
/// saying how it went.
fn send(ctx: Context, services: Services) -> response.Response(Content) {
  use fields <- form.read(ctx)
  let back = see_other("/")
  case current_user(ctx) {
    Error(Nil) -> back
    Ok(user) -> {
      let to = form.value(fields, "to")
      let kind = form.value(fields, "kind")
      let message = form.value(fields, "message")
      let assert Ok(sender) = list.key_find(people, user)
      case list.key_find(people, to), message {
        Error(Nil), _ ->
          flash.put(back, services.flash, flash.Danger, "Choose who to notify")
        _, "" ->
          flash.put(back, services.flash, flash.Danger, "Write a message")
        Ok(name), _ -> {
          let title = case kind {
            "mention" -> sender <> " mentioned you"
            _ -> sender <> " commented"
          }
          let sent =
            notifications.draft(kind, title)
            |> notifications.body(message)
            |> notifications.link("/inbox")
            |> notifications.send(services.notifier, to:)
          case sent {
            Ok(_) ->
              flash.put(back, services.flash, flash.Success, "Sent to " <> name)
            Error(_) ->
              flash.put(back, services.flash, flash.Danger, "Could not send")
          }
        }
      }
    }
  }
}

fn see_other(location: String) -> response.Response(Content) {
  response.new(303)
  |> response.set_header("location", location)
  |> response.set_body(content.Empty)
}

/// The pretend session: the user the `demo_user` cookie names.
fn current_user(ctx: Context) -> Result(String, Nil) {
  use user <- result.try(
    request.get_cookies(ctx.request) |> list.key_find("demo_user"),
  )
  list.key_find(people, user) |> result.replace(user)
}

// -- Pages -------------------------------------------------------------------

fn home(ctx: Context, services: Services) -> response.Response(Content) {
  use messages <- flash.take(ctx, services.flash)
  let user = current_user(ctx) |> option.from_result
  let body = case user {
    None -> [sign_in()]
    Some(user) -> [
      ui.card([], [
        ui.card_header([], [
          ui.card_title([text("Send a notification")]),
          ui.card_description([
            text(
              "A mention is emailed thirty seconds later too, unless it is read first.",
            ),
          ]),
        ]),
        ui.card_content([], [send_form(user)]),
      ]),
      ui.card([], [
        ui.card_header([], [
          ui.card_title([text("Live")]),
          ui.card_description([
            text("A live view subscribed to your notifications."),
          ]),
        ]),
        ui.card_content([], [live.mount("/live/feed")]),
      ]),
    ]
  }
  layout(ctx, services, user, messages, body)
}

fn sign_in() -> Element(msg) {
  ui.card([], [
    ui.card_header([], [ui.card_title([text("Who are you?")])]),
    ui.card_content([], [
      html.form([attribute.method("post"), attribute.action("/sign-in")], [
        ui.row(
          [],
          list.map(people, fn(person) {
            ui.submit_button(
              Outline,
              [attribute.name("user"), attribute.value(person.0)],
              [text(person.1)],
            )
          }),
        ),
      ]),
    ]),
  ])
}

fn send_form(user: String) -> Element(msg) {
  let others = list.filter(people, fn(person) { person.0 != user })
  html.form([attribute.method("post"), attribute.action("/send")], [
    ui.stack([], [
      ui.label([attribute.for("to")], [text("To")]),
      ui.native_select(
        [attribute.id("to"), attribute.name("to")],
        list.map(others, fn(person) {
          html.option([attribute.value(person.0)], person.1)
        }),
      ),
      ui.label([attribute.for("kind")], [text("Kind")]),
      ui.native_select([attribute.id("kind"), attribute.name("kind")], [
        html.option([attribute.value("comment")], "Comment: in the app only"),
        html.option([attribute.value("mention")], "Mention: emailed too"),
      ]),
      ui.label([attribute.for("message")], [text("Message")]),
      ui.textarea([attribute.id("message"), attribute.name("message")], ""),
      ui.row([], [ui.submit_button(Primary, [], [text("Send")])]),
    ]),
  ])
}

fn inbox(ctx: Context, services: Services) -> response.Response(Content) {
  use messages <- flash.take(ctx, services.flash)
  case current_user(ctx) {
    Error(Nil) -> see_other("/")
    Ok(user) -> {
      let found =
        notifications.list(
          services.notifier,
          user,
          notifications.page() |> notifications.limit(100),
        )
        |> result.unwrap([])
      // Plain forms, so the inbox works without JavaScript; `next` brings
      // each post back here.
      let mark_all =
        html.form(
          [
            attribute.method("post"),
            attribute.action("/notifications/read?next=/inbox"),
          ],
          [ui.submit_button(Outline, [], [text("Mark all as read")])],
        )
      let rows =
        list.map(found, fn(n) {
          let state = case n.read_at {
            Some(_) -> #("unread", "Mark unread")
            None -> #("read", "Mark read")
          }
          ui.card([], [
            ui.card_header([], [
              ui.card_title([
                text(case n.read_at {
                  Some(_) -> n.title
                  None -> "● " <> n.title
                }),
              ]),
              ui.card_description([text(n.body)]),
            ]),
            ui.card_content([], [
              html.form(
                [
                  attribute.method("post"),
                  attribute.action(
                    "/notifications/"
                    <> n.id
                    <> "/"
                    <> state.0
                    <> "?next=/inbox",
                  ),
                ],
                [ui.submit_button(Outline, [], [text(state.1)])],
              ),
            ]),
          ])
        })
      layout(ctx, services, Some(user), messages, [
        ui.h2("Inbox"),
        mark_all,
        ..case rows {
          [] -> [ui.muted("Nothing here yet.")]
          _ -> rows
        }
      ])
    }
  }
}

fn layout(
  ctx: Context,
  services: Services,
  user: Option(String),
  messages: List(flash.Message),
  body: List(Element(msg)),
) -> response.Response(Content) {
  let header = case user {
    None -> [ui.h1("Notifications")]
    Some(user) -> {
      let unread =
        notifications.unread_count(services.notifier, user) |> result.unwrap(0)
      let assert Ok(name) = list.key_find(people, user)
      [
        ui.row([attribute.style("justify-content", "space-between")], [
          ui.h1("Notifications"),
          ui.row([], [
            ui.muted("Signed in as " <> name),
            ui.link("/", [text("Home")]),
            ui.link("/inbox", [text("Inbox")]),
            bell.new(id: "inbox-panel", source: "/notifications")
              |> bell.unread(unread)
              |> bell.inbox("/inbox")
              |> bell.push(at: "/push")
              |> bell.view,
            html.form(
              [attribute.method("post"), attribute.action("/sign-out")],
              [ui.submit_button(Outline, [], [text("Sign out")])],
            ),
          ]),
        ]),
      ]
    }
  }
  page.new("Notifications · Howdy")
  |> page.themes(theme.default_themes())
  |> page.stylesheet(at: "/assets/ui.css")
  |> page.live
  |> page.body([
    ui.container([], [ui.stack([], list.append(header, body))]),
    toast.region([], toast.flashed(messages)),
  ])
  |> page.respond(ctx)
}
