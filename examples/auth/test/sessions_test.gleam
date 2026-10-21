import flows/sessions
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string
import gloo/repo
import howdy/auth
import howdy/auth/session_store
import howdy/auth/user
import howdy/testing
import support.{email_field, from_browser, object}

fn quiet_store() {
  sessions.observed(session_store.memory(), fn(_) { Nil })
}

/// Sign in through the browser API, carrying whatever cookies the browser
/// already holds, and return the cookies it holds afterwards.
fn browser_sign_in(
  app,
  inbox,
  email: String,
  cookies: List(#(String, String)),
) {
  let _ =
    testing.post("/api/auth/register", object([#("email", email)]))
    |> from_browser
    |> testing.send(app)
  let exchange = object([#("token", support.token(support.next_email(inbox)))])
  let res =
    testing.post("/api/auth/session", exchange)
    |> from_browser
    |> with_cookies(cookies)
    |> testing.send(app)
  assert res.status == 200
  merge(cookies, testing.cookies(res))
}

fn with_cookies(req, cookies: List(#(String, String))) {
  list.fold(cookies, req, fn(req, cookie) {
    testing.cookie(req, cookie.0, cookie.1)
  })
}

/// Later Set-Cookie headers replace earlier cookies of the same name.
fn merge(held: List(#(String, String)), set: List(#(String, String))) {
  list.fold(set, held, fn(held, cookie) {
    [cookie, ..list.filter(held, fn(c) { c.0 != cookie.0 })]
  })
  |> list.filter(fn(c) { c.1 != "" })
}

fn signed_in_as(app, cookies) {
  testing.get("/account/me")
  |> with_cookies(cookies)
  |> testing.send(app)
  |> testing.json(email_field())
}

pub fn the_adapter_meets_the_store_contract_test() {
  assert session_store.check(quiet_store()) == Ok(Nil)
}

pub fn one_browser_holds_several_accounts_test() {
  use db <- support.with_database
  let #(inbox, deliver) = support.mailbox()
  let app = sessions.configure(db, deliver, quiet_store()) |> sessions.app

  let cookies = browser_sign_in(app, inbox, "ada@example.com", [])
  let cookies = browser_sign_in(app, inbox, "bob@example.com", cookies)
  // The newest sign-in is active; ada is still signed in, in the background.
  assert signed_in_as(app, cookies) == Ok("bob@example.com")

  let accounts =
    testing.get("/api/auth/sessions/accounts")
    |> with_cookies(cookies)
    |> testing.send(app)
  let assert Ok(listed) =
    testing.json(
      accounts,
      decode.list({
        use id <- decode.field("id", decode.string)
        use email <- decode.subfield(["user", "email"], decode.string)
        decode.success(#(email, id))
      }),
    )
  assert list.length(listed) == 2
  let assert Ok(ada) = list.key_find(listed, "ada@example.com")

  let switched =
    testing.post("/api/auth/sessions/switch", object([#("id", ada)]))
    |> from_browser
    |> with_cookies(cookies)
    |> testing.send(app)
  assert switched.status == 200
  let cookies = merge(cookies, testing.cookies(switched))
  assert signed_in_as(app, cookies) == Ok("ada@example.com")

  // Signing out falls back to the other account rather than to nobody.
  let signed_out =
    testing.post("/api/auth/logout", object([]))
    |> from_browser
    |> with_cookies(cookies)
    |> testing.send(app)
  assert signed_out.status == 204
  let cookies = merge(cookies, testing.cookies(signed_out))
  assert signed_in_as(app, cookies) == Ok("bob@example.com")
}

pub fn sessions_live_in_the_store_not_the_database_test() {
  use db <- support.with_database
  let #(inbox, deliver) = support.mailbox()
  let reports = process.new_subject()
  let store =
    sessions.observed(session_store.memory(), process.send(reports, _))
  let identity = sessions.configure(db, deliver, store)

  let _ = support.signed_up(identity, inbox, "ada@example.com")
  let assert Ok(report) = process.receive(reports, 1000)
  assert string.starts_with(report, "insert session for ")
  let assert Ok([0]) =
    repo.all(
      db,
      "SELECT COUNT(*) FROM howdy_auth_sessions",
      [],
      decode.field(0, decode.int, decode.success),
    )
}

pub fn a_suspended_user_is_refused_even_with_a_stored_session_test() {
  use db <- support.with_database
  let #(inbox, deliver) = support.mailbox()
  // A store whose cleanup silently fails, so the session outlives suspension.
  let store =
    session_store.SessionStore(..quiet_store(), delete_for_user: fn(_, _) {
      Ok(Nil)
    })
  let identity = sessions.configure(db, deliver, store)
  let token = support.signed_up(identity, inbox, "ada@example.com")
  let assert Ok(principal) = auth.authenticate(identity, token)

  // Users and suspension stay in the database, checked on every request.
  let assert Ok(_) = auth.suspend(identity, principal.user.id, by: user.System)
  assert result.is_error(auth.authenticate(identity, token))
}
