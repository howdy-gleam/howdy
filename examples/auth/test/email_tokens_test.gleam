import flows/email_tokens
import howdy/auth
import howdy/testing
import support.{bearer, email_field, from_browser, object}

pub fn a_browser_registers_and_gets_a_session_cookie_test() {
  use db <- support.with_database
  let #(inbox, deliver) = support.mailbox()
  let identity = email_tokens.configure(db, deliver)
  let app = email_tokens.app(identity)

  let requested =
    testing.post("/api/auth/register", object([#("email", "ada@example.com")]))
    |> from_browser
    |> testing.send(app)
  assert requested.status == 202
  let email = support.next_email(inbox)
  assert email.email == "ada@example.com"
  assert email.purpose == auth.Registration

  // The browser exchanges the token for an HttpOnly cookie; no Origin, no cookie.
  let exchange = object([#("token", support.token(email))])
  assert { testing.post("/api/auth/session", exchange) |> testing.send(app) }.status
    == 403
  let signed_in =
    testing.post("/api/auth/session", exchange)
    |> from_browser
    |> testing.send(app)
  assert signed_in.status == 200
  let assert [#(name, session), ..] = testing.cookies(signed_in)
  assert name == auth.cookie_name(identity)

  let me =
    testing.get("/account/me")
    |> testing.cookie(name, session)
    |> testing.send(app)
  assert me.status == 200
  assert testing.json(me, email_field()) == Ok("ada@example.com")
}

pub fn a_native_client_gets_a_bearer_token_test() {
  use db <- support.with_database
  let #(inbox, deliver) = support.mailbox()
  let app = email_tokens.configure(db, deliver) |> email_tokens.app

  // Native clients send no Origin, and receive the token in the body instead.
  let requested =
    testing.post("/api/auth/register", object([#("email", "ada@example.com")]))
    |> testing.send(app)
  assert requested.status == 202
  let email = support.next_email(inbox)
  let exchanged =
    testing.post("/api/auth/token", object([#("token", support.token(email))]))
    |> testing.send(app)
  assert exchanged.status == 200
  assert testing.cookies(exchanged) == []
  let assert Ok(access_token) =
    testing.json(exchanged, support.string_at(["access_token"]))

  let me =
    testing.get("/account/me") |> bearer(access_token) |> testing.send(app)
  assert testing.json(me, email_field()) == Ok("ada@example.com")
}

pub fn tokens_are_single_use_test() {
  use db <- support.with_database
  let #(inbox, deliver) = support.mailbox()
  let app = email_tokens.configure(db, deliver) |> email_tokens.app

  let _ =
    testing.post("/api/auth/register", object([#("email", "ada@example.com")]))
    |> testing.send(app)
  let exchange = object([#("token", support.token(support.next_email(inbox)))])
  assert { testing.post("/api/auth/token", exchange) |> testing.send(app) }.status
    == 200
  assert { testing.post("/api/auth/token", exchange) |> testing.send(app) }.status
    == 401
}

pub fn registering_an_existing_address_tells_its_owner_test() {
  use db <- support.with_database
  let #(inbox, deliver) = support.mailbox()
  let identity = email_tokens.configure(db, deliver)
  let assert Ok(Nil) =
    auth.request_token(identity, "ada@example.com", auth.Register)
  let assert Ok(_) =
    auth.exchange(identity, support.token(support.next_email(inbox)))

  // The reply is the same 202 either way; only the inbox owner learns more.
  let app = email_tokens.app(identity)
  let again =
    testing.post("/api/auth/register", object([#("email", "ada@example.com")]))
    |> testing.send(app)
  assert again.status == 202
  assert support.next_email(inbox).purpose == auth.AlreadyRegistered
}

pub fn signed_out_requests_are_refused_test() {
  use db <- support.with_database
  let #(_, deliver) = support.mailbox()
  let app = email_tokens.configure(db, deliver) |> email_tokens.app

  let res = testing.get("/account/me") |> testing.send(app)
  assert res.status == 401
  assert testing.error(res) == Ok("unauthorized")
}
