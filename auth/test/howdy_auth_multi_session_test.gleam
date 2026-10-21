//// Several accounts signed in to one browser, over the cookie transport.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import howdy/auth
import howdy/auth/secret
import howdy/testing
import support.{app, fixture, signup}

const session_cookie = "__Host-howdy_session"

const accounts_cookie = "__Host-howdy_accounts"

/// What a browser would hold: the two cookies, updated from each response.
type Jar {
  Jar(session: String, accounts: String)
}

fn keep(jar: Jar, response) -> Jar {
  list.fold(testing.cookies(response), jar, fn(jar, pair) {
    case pair.0 {
      name if name == session_cookie -> Jar(..jar, session: pair.1)
      name if name == accounts_cookie -> Jar(..jar, accounts: pair.1)
      _ -> jar
    }
  })
}

fn send(application, jar: Jar, request) {
  let request = testing.header(request, "origin", "https://example.test")
  let request = case jar.session {
    "" -> request
    value -> testing.cookie(request, session_cookie, value)
  }
  case jar.accounts {
    "" -> request
    value -> testing.cookie(request, accounts_cookie, value)
  }
  |> testing.send(application)
}

fn sign_in(
  identity,
  application,
  mailbox: process.Subject(auth.Delivery),
  jar,
  email,
) {
  let assert Ok(_) = auth.request_token(identity, email, auth.Login)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let response =
    send(
      application,
      jar,
      testing.post(
        "/api/auth/session",
        json.object([#("token", json.string(secret.reveal(delivery.token)))]),
      ),
    )
  assert response.status == 200
  keep(jar, response)
}

fn accounts(application, jar) {
  let response =
    send(application, jar, testing.get("/api/auth/sessions/accounts"))
  assert response.status == 200
  let assert Ok(entries) =
    json.parse(
      testing.text(response),
      decode.list({
        use id <- decode.field("id", decode.string)
        use email <- decode.subfield(["user", "email"], decode.string)
        use current <- decode.field("current", decode.bool)
        decode.success(#(id, email, current))
      }),
    )
  entries
}

fn live(identity, token) {
  result.is_ok(auth.authenticate(identity, token))
}

pub fn a_browser_holds_switches_and_leaves_several_accounts_test() {
  use _, identity, permissions, mailbox <- fixture
  assert result.is_error(auth.with_multi_session(identity, 1))
  assert result.is_error(auth.with_multi_session(identity, 11))
  let assert Ok(identity) = auth.with_multi_session(identity, 2)
  let application = app(identity, permissions)
  list.each(["ada", "bob", "carol"], fn(name) {
    signup(identity, mailbox, name <> "@example.com")
  })

  let ada =
    sign_in(identity, application, mailbox, Jar("", ""), "ada@example.com")
  assert ada.accounts == ada.session
  // Signing in again adds an account; the first stays signed in.
  let both = sign_in(identity, application, mailbox, ada, "bob@example.com")
  assert both.session != ada.session
  assert both.accounts == ada.session <> "." <> both.session
  assert live(identity, ada.session)
  let assert [
    #(ada_id, "ada@example.com", False),
    #(_, "bob@example.com", True),
  ] = accounts(application, both)
  // The listing never discloses a token.
  assert !string.contains(
    send(application, both, testing.get("/api/auth/sessions/accounts"))
      |> testing.text,
    ada.session,
  )

  // Switching needs the Origin, and only reaches this browser's accounts.
  let switch = fn(id) {
    testing.post(
      "/api/auth/sessions/switch",
      json.object([#("id", json.string(id))]),
    )
  }
  assert testing.send(
      switch(ada_id)
        |> testing.cookie(session_cookie, both.session)
        |> testing.cookie(accounts_cookie, both.accounts),
      application,
    ).status
    == 403
  assert send(application, both, switch("not-in-this-browser")).status == 404
  let switched = send(application, both, switch(ada_id))
  assert switched.status == 200
  let as_ada = keep(both, switched)
  assert as_ada.session == ada.session
  let assert [#(_, _, True), #(_, _, False)] = accounts(application, as_ada)

  // A third account signs the oldest out, here and on the server.
  let full =
    sign_in(identity, application, mailbox, as_ada, "carol@example.com")
  assert full.accounts == both.session <> "." <> full.session
  assert !live(identity, ada.session)
  assert live(identity, both.session)

  // Signing in again as the same user replaces that account's session.
  let again = sign_in(identity, application, mailbox, full, "bob@example.com")
  assert !live(identity, both.session)
  assert again.accounts == full.session <> "." <> again.session

  // Signing out lands in the account that remains.
  let left =
    keep(
      again,
      send(
        application,
        again,
        testing.post("/api/auth/logout", json.object([])),
      ),
    )
  assert !live(identity, again.session)
  assert left.session == full.session
  assert left.accounts == full.session
  let assert [#(_, "carol@example.com", True)] = accounts(application, left)
}

pub fn signing_out_of_all_accounts_revokes_each_and_clears_both_cookies_test() {
  use _, identity, permissions, mailbox <- fixture
  let assert Ok(identity) = auth.with_multi_session(identity, 3)
  let application = app(identity, permissions)
  let _ = signup(identity, mailbox, "ada@example.com")
  let _ = signup(identity, mailbox, "bob@example.com")
  let ada =
    sign_in(identity, application, mailbox, Jar("", ""), "ada@example.com")
  let both = sign_in(identity, application, mailbox, ada, "bob@example.com")
  // A stale or forged entry is ignored rather than trusted or fatal.
  let padded = Jar(..both, accounts: "garbage." <> both.accounts <> ".")
  let assert [_, _] = accounts(application, padded)
  let response =
    send(
      application,
      padded,
      testing.post("/api/auth/logout", json.object([#("all", json.bool(True))])),
    )
  assert response.status == 204
  assert keep(padded, response) == Jar("", "")
  assert !live(identity, ada.session)
  assert !live(identity, both.session)
}

pub fn an_account_change_that_ends_the_session_falls_back_to_another_test() {
  use _, identity, permissions, mailbox <- fixture
  let assert Ok(identity) = auth.with_multi_session(identity, 3)
  let identity = auth.with_account_deletion(identity, fn(_, _) { Ok(Nil) })
  let application = app(identity, permissions)
  let _ = signup(identity, mailbox, "ada@example.com")
  let _ = signup(identity, mailbox, "bob@example.com")
  let ada =
    sign_in(identity, application, mailbox, Jar("", ""), "ada@example.com")
  let both = sign_in(identity, application, mailbox, ada, "bob@example.com")
  let deleted =
    send(
      application,
      both,
      testing.post(
        "/api/auth/account/delete",
        json.object([#("email", json.string("bob@example.com"))]),
      ),
    )
  assert deleted.status == 204
  assert keep(both, deleted) == Jar(ada.session, ada.session)
}

pub fn without_multi_session_a_new_sign_in_still_replaces_the_old_test() {
  use _, identity, permissions, mailbox <- fixture
  let application = app(identity, permissions)
  let _ = signup(identity, mailbox, "ada@example.com")
  let _ = signup(identity, mailbox, "bob@example.com")
  let ada =
    sign_in(identity, application, mailbox, Jar("", ""), "ada@example.com")
  assert ada.accounts == ""
  let bob = sign_in(identity, application, mailbox, ada, "bob@example.com")
  assert bob.accounts == ""
  assert !live(identity, ada.session)
  assert accounts(application, bob) == []
  assert send(
      application,
      bob,
      testing.post(
        "/api/auth/sessions/switch",
        json.object([#("id", json.string("anything"))]),
      ),
    ).status
    == 404
}
