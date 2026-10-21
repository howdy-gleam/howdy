import flows/passwords
import gleam/json
import howdy/auth
import howdy/testing
import support.{bearer, email_field, object, strong_password}

fn credentials(email: String, password: String) -> json.Json {
  object([#("email", email), #("password", password)])
}

/// Register with a password, then verify the address to create the account.
fn register(app, inbox, email: String, password: String) -> Nil {
  let requested =
    testing.post("/api/auth/password/register", credentials(email, password))
    |> testing.send(app)
  assert requested.status == 202
  let verify = object([#("token", support.token(support.next_email(inbox)))])
  let verified = testing.post("/api/auth/token", verify) |> testing.send(app)
  assert verified.status == 200
}

fn login(app, email: String, password: String) {
  testing.post("/api/auth/password/token", credentials(email, password))
  |> testing.send(app)
}

pub fn registering_with_a_password_verifies_the_address_first_test() {
  use db <- support.with_database
  let #(inbox, deliver) = support.mailbox()
  let app = passwords.configure(db, deliver) |> passwords.app

  // Until the emailed token is exchanged there is no account to sign in to.
  let requested =
    testing.post(
      "/api/auth/password/register",
      credentials("ada@example.com", strong_password),
    )
    |> testing.send(app)
  assert requested.status == 202
  assert { login(app, "ada@example.com", strong_password) }.status == 401

  let email = support.next_email(inbox)
  assert email.purpose == auth.Registration
  let verify = object([#("token", support.token(email))])
  assert { testing.post("/api/auth/token", verify) |> testing.send(app) }.status
    == 200

  let signed_in = login(app, "ada@example.com", strong_password)
  assert signed_in.status == 200
  let assert Ok(token) =
    testing.json(signed_in, support.string_at(["access_token"]))
  let me = testing.get("/account/me") |> bearer(token) |> testing.send(app)
  assert testing.json(me, email_field()) == Ok("ada@example.com")
}

pub fn a_wrong_password_is_unauthorized_test() {
  use db <- support.with_database
  let #(inbox, deliver) = support.mailbox()
  let app = passwords.configure(db, deliver) |> passwords.app
  register(app, inbox, "ada@example.com", strong_password)

  // The same answer as for an address with no account at all.
  assert { login(app, "ada@example.com", "not the password at all!") }.status
    == 401
  assert { login(app, "nobody@example.com", strong_password) }.status == 401
}

pub fn weak_and_blocklisted_passwords_are_refused_test() {
  use db <- support.with_database
  let #(inbox, deliver) = support.mailbox()
  let app = passwords.configure(db, deliver) |> passwords.app

  let short =
    testing.post(
      "/api/auth/password/register",
      credentials("ada@example.com", "too short"),
    )
    |> testing.send(app)
  assert short.status == 400
  // Long enough, but on the application's blocklist.
  let denied =
    testing.post(
      "/api/auth/password/register",
      credentials("ada@example.com", "howdy password 2026!"),
    )
    |> testing.send(app)
  assert denied.status == 400
  assert support.no_email(inbox)
}

pub fn changing_the_password_needs_the_current_one_test() {
  use db <- support.with_database
  let #(inbox, deliver) = support.mailbox()
  let app = passwords.configure(db, deliver) |> passwords.app
  register(app, inbox, "ada@example.com", strong_password)
  let assert Ok(token) =
    login(app, "ada@example.com", strong_password)
    |> testing.json(support.string_at(["access_token"]))
  let replacement = "a different orchard phrase 318?"

  let wrong =
    testing.post(
      "/api/auth/password/change",
      object([
        #("current", "not the password at all!"),
        #("password", replacement),
      ]),
    )
    |> bearer(token)
    |> testing.send(app)
  // 400, not 401: the session is still good, the guess was not.
  assert wrong.status == 400

  let changed =
    testing.post(
      "/api/auth/password/change",
      object([#("current", strong_password), #("password", replacement)]),
    )
    |> bearer(token)
    |> testing.send(app)
  assert changed.status == 204
  // The owner hears about it, in case it was not them.
  assert support.next_email(inbox).purpose == auth.PasswordChanged
  assert { login(app, "ada@example.com", strong_password) }.status == 401
  assert { login(app, "ada@example.com", replacement) }.status == 200
}
