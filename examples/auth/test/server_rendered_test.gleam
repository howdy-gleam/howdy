import flows/server_rendered
import gleam/http/response
import gleam/list
import gleam/result
import gleam/string
import howdy/auth
import howdy/testing
import support.{from_browser}

pub fn signing_in_with_forms_sets_the_session_cookie_test() {
  use db <- support.with_database
  let #(inbox, deliver) = support.mailbox()
  let identity = server_rendered.configure(db, deliver)
  let app = server_rendered.app(identity)

  let start = testing.get("/") |> testing.send(app)
  assert string.contains(testing.text(start), "action=\"/login\"")

  let requested =
    testing.post_form("/login", [
      #("email", "ada@example.com"),
      #("intent", "register"),
    ])
    |> from_browser
    |> testing.send(app)
  assert requested.status == 200
  assert string.contains(testing.text(requested), "Check your email")
  let email = support.next_email(inbox)
  assert email.purpose == auth.Registration

  let exchanged =
    testing.post_form("/login/token", [#("token", support.token(email))])
    |> from_browser
    |> testing.send(app)
  assert exchanged.status == 303
  assert response.get_header(exchanged, "location") == Ok("/")
  let assert Ok(#(name, session)) =
    list.find(testing.cookies(exchanged), fn(cookie) {
      cookie.0 == auth.cookie_name(identity)
    })

  // The cookie is the same one `auth.required` reads, so the bundled guards
  // and this module's pages agree about who is signed in.
  let home =
    testing.get("/") |> testing.cookie(name, session) |> testing.send(app)
  assert string.contains(testing.text(home), "Signed in as ada@example.com")
  let sessions =
    testing.get("/account/sessions")
    |> testing.cookie(name, session)
    |> testing.send(app)
  assert string.contains(testing.text(sessions), "(this browser)")
}

pub fn a_bad_token_shows_the_form_again_test() {
  use db <- support.with_database
  let #(_, deliver) = support.mailbox()
  let app = server_rendered.configure(db, deliver) |> server_rendered.app

  let res =
    testing.post_form("/login/token", [#("token", "not-a-real-token")])
    |> from_browser
    |> testing.send(app)
  assert res.status == 200
  assert string.contains(testing.text(res), "That token did not work")
  assert testing.cookies(res) == []
}

pub fn cross_site_forms_are_refused_test() {
  use db <- support.with_database
  let #(inbox, deliver) = support.mailbox()
  let app = server_rendered.configure(db, deliver) |> server_rendered.app

  let forged =
    testing.post_form("/login", [#("email", "ada@example.com")])
    |> testing.header("origin", "https://attacker.example")
    |> testing.send(app)
  assert forged.status == 403
  assert support.no_email(inbox)
}

pub fn signing_out_ends_the_session_test() {
  use db <- support.with_database
  let #(inbox, deliver) = support.mailbox()
  let identity = server_rendered.configure(db, deliver)
  let app = server_rendered.app(identity)
  let session = support.signed_up(identity, inbox, "ada@example.com")
  let name = auth.cookie_name(identity)

  // A signed-in write without Origin is refused before it does anything.
  let forged =
    testing.post_form("/account/logout", [])
    |> testing.cookie(name, session)
    |> testing.send(app)
  assert forged.status == 403

  let signed_out =
    testing.post_form("/account/logout", [])
    |> testing.cookie(name, session)
    |> from_browser
    |> testing.send(app)
  assert signed_out.status == 303
  assert result.is_error(auth.authenticate(identity, session))
  let after =
    testing.get("/") |> testing.cookie(name, session) |> testing.send(app)
  assert string.contains(testing.text(after), "<h1>Sign in</h1>")
}
