import gleam/http/response
import gleam/list
import gleam/string
import gleeunit
import gloo/adapter/sqlite
import howdy/database
import howdy/jobs
import howdy/mail
import howdy/mail/outbox
import howdy/migration
import howdy/notifications
import howdy/notifications/web_push
import howdy/testing
import howdy_notifications_example as example

pub fn main() {
  gleeunit.main()
}

fn services() -> example.Services {
  let assert Ok(repo) = sqlite.start(sqlite.memory())
  let assert Ok(Nil) = database.sqlite_defaults(repo)
  let assert Ok(Nil) =
    migration.run(repo, [jobs.schema(), notifications.schema()])
  example.services(
    repo,
    mail.mailer(outbox.adapter(outbox.start())),
    web_push.generate_keys(),
  )
}

/// Follow a response's cookies into the next request, as a browser would.
fn with_cookies(req, res) {
  list.fold(testing.cookies(res), req, fn(req, cookie) {
    case cookie.1 {
      "" -> req
      value -> testing.cookie(req, cookie.0, value)
    }
  })
}

fn same_origin(req) {
  testing.header(req, "origin", example.origin)
}

pub fn sending_flashes_and_reaches_the_inbox_test() {
  let services = services()
  let app = example.app(services)

  let signed_in =
    testing.post_form("/sign-in", [#("user", "ana")])
    |> same_origin
    |> testing.send(app)
  assert signed_in.status == 303
  let home = testing.get("/") |> with_cookies(signed_in) |> testing.send(app)
  assert string.contains(testing.text(home), "Signed in as Ana")
  assert string.contains(testing.text(home), "data-howdy-bell")

  let sent =
    testing.post_form("/send", [
      #("to", "bo"),
      #("kind", "mention"),
      #("message", "See the plan?"),
    ])
    |> testing.cookie("demo_user", "ana")
    |> same_origin
    |> testing.send(app)
  assert sent.status == 303
  assert response.get_header(sent, "location") == Ok("/")
  let home =
    testing.get("/")
    |> testing.cookie("demo_user", "ana")
    |> with_cookies(sent)
    |> testing.send(app)
  assert string.contains(testing.text(home), "Sent to Bo")

  assert notifications.unread_count(services.notifier, "bo") == Ok(1)
  let inbox =
    testing.get("/inbox")
    |> testing.cookie("demo_user", "bo")
    |> testing.send(app)
  assert string.contains(testing.text(inbox), "Ana mentioned you")
  assert string.contains(testing.text(inbox), "See the plan?")
}

pub fn an_empty_message_is_refused_with_a_flash_test() {
  let services = services()
  let app = example.app(services)
  let sent =
    testing.post_form("/send", [#("to", "bo"), #("message", "")])
    |> testing.cookie("demo_user", "ana")
    |> same_origin
    |> testing.send(app)
  let home =
    testing.get("/")
    |> testing.cookie("demo_user", "ana")
    |> with_cookies(sent)
    |> testing.send(app)
  assert string.contains(testing.text(home), "Write a message")
  assert notifications.unread_count(services.notifier, "bo") == Ok(0)
}

pub fn cross_site_posts_are_refused_test() {
  let app = example.app(services())
  let res =
    testing.post_form("/send", [#("to", "bo"), #("message", "hi")])
    |> testing.cookie("demo_user", "ana")
    |> testing.header("origin", "https://evil.example")
    |> testing.send(app)
  assert res.status == 403
}
