import flows/passkeys_and_mfa
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import howdy/auth/secret
import howdy/auth/user.{type User}
import howdy/testing
import support.{bearer, email_field, object, strong_password}

/// A fresh key per test. A real deployment generates one and keeps it.
fn mfa_key() -> String {
  crypto.strong_random_bytes(32) |> bit_array.base64_url_encode(False)
}

/// Collects the codes `send_code` would text or push.
fn code_box() -> #(Subject(String), fn(User, secret.Secret) -> Result(Nil, Nil)) {
  let box = process.new_subject()
  #(box, fn(_user, code) {
    process.send(box, secret.reveal(code))
    Ok(Nil)
  })
}

fn next_code(box: Subject(String)) -> String {
  let assert Ok(code) = process.receive(box, 1000)
  code
}

fn password_login(app) {
  testing.post(
    "/api/auth/password/token",
    object([#("email", "ada@example.com"), #("password", strong_password)]),
  )
  |> testing.send(app)
}

pub fn a_second_factor_is_needed_after_enrolling_test() {
  use db <- support.with_database
  let #(inbox, deliver) = support.mailbox()
  let #(codes, send_code) = code_box()
  let app =
    passkeys_and_mfa.configure(db, deliver, mfa_key: mfa_key(), send_code:)
    |> passkeys_and_mfa.app

  // An account with a password.
  let _ =
    testing.post(
      "/api/auth/password/register",
      object([#("email", "ada@example.com"), #("password", strong_password)]),
    )
    |> testing.send(app)
  let verify = object([#("token", support.token(support.next_email(inbox)))])
  let _ = testing.post("/api/auth/token", verify) |> testing.send(app)
  let assert Ok(session) =
    password_login(app) |> testing.json(support.string_at(["access_token"]))

  // Enroll delivered codes. Nothing changes until a code proves delivery works.
  let started =
    testing.post("/api/auth/mfa/enroll", object([#("method", "otp")]))
    |> bearer(session)
    |> testing.send(app)
  assert started.status == 200
  let assert Ok(challenge) =
    testing.json(started, support.string_at(["challenge"]))
  let confirmed =
    testing.post(
      "/api/auth/mfa/enroll/confirm",
      object([#("challenge", challenge), #("code", next_code(codes))]),
    )
    |> bearer(session)
    |> testing.send(app)
  assert confirmed.status == 200
  // Recovery codes are shown once. Enrolling signs every session out.
  let assert Ok(recovery) =
    testing.json(
      confirmed,
      decode.at(["recovery_codes"], decode.list(decode.string)),
    )
  assert list.length(recovery) == 10
  assert { testing.get("/account/me") |> bearer(session) |> testing.send(app) }.status
    == 401

  // The password alone now yields a pending challenge, not a session.
  let pending = password_login(app)
  assert pending.status == 202
  let assert Ok(mfa_token) =
    testing.json(pending, support.string_at(["mfa_token"]))
  assert {
      testing.get("/account/me") |> bearer(mfa_token) |> testing.send(app)
    }.status
    == 401

  let sent =
    testing.post(
      "/api/auth/mfa/token/send",
      object([#("challenge", mfa_token)]),
    )
    |> testing.send(app)
  assert sent.status == 204
  let verified =
    testing.post(
      "/api/auth/mfa/token",
      json.object([
        #("challenge", json.string(mfa_token)),
        #("method", json.string("otp")),
        #("code", json.string(next_code(codes))),
      ]),
    )
    |> testing.send(app)
  assert verified.status == 200
  let assert Ok(access_token) =
    testing.json(verified, support.string_at(["session", "access_token"]))
  let me =
    testing.get("/account/me") |> bearer(access_token) |> testing.send(app)
  assert testing.json(me, email_field()) == Ok("ada@example.com")
}

pub fn a_recovery_code_works_once_test() {
  use db <- support.with_database
  let #(inbox, deliver) = support.mailbox()
  let #(codes, send_code) = code_box()
  let app =
    passkeys_and_mfa.configure(db, deliver, mfa_key: mfa_key(), send_code:)
    |> passkeys_and_mfa.app
  let _ =
    testing.post(
      "/api/auth/password/register",
      object([#("email", "ada@example.com"), #("password", strong_password)]),
    )
    |> testing.send(app)
  let verify = object([#("token", support.token(support.next_email(inbox)))])
  let _ = testing.post("/api/auth/token", verify) |> testing.send(app)
  let assert Ok(session) =
    password_login(app) |> testing.json(support.string_at(["access_token"]))
  let assert Ok(challenge) =
    testing.post("/api/auth/mfa/enroll", object([#("method", "otp")]))
    |> bearer(session)
    |> testing.send(app)
    |> testing.json(support.string_at(["challenge"]))
  let assert Ok([recovery, ..]) =
    testing.post(
      "/api/auth/mfa/enroll/confirm",
      object([#("challenge", challenge), #("code", next_code(codes))]),
    )
    |> bearer(session)
    |> testing.send(app)
    |> testing.json(decode.at(["recovery_codes"], decode.list(decode.string)))

  let verify_with = fn(code) {
    let assert Ok(mfa_token) =
      password_login(app) |> testing.json(support.string_at(["mfa_token"]))
    testing.post(
      "/api/auth/mfa/token",
      json.object([
        #("challenge", json.string(mfa_token)),
        #("method", json.string("recovery")),
        #("code", json.string(code)),
      ]),
    )
    |> testing.send(app)
  }
  assert { verify_with(recovery) }.status == 200
  assert { verify_with(recovery) }.status != 200
}

pub fn passkeys_are_offered_for_this_origin_test() {
  use db <- support.with_database
  let #(_, deliver) = support.mailbox()
  let #(_, send_code) = code_box()
  let app =
    passkeys_and_mfa.configure(db, deliver, mfa_key: mfa_key(), send_code:)
    |> passkeys_and_mfa.app

  // WebAuthn is a browser ceremony, so this needs the exact Origin too.
  // The browser hands these options to navigator.credentials.get(), then
  // posts the credential with the challenge to /api/auth/passkeys/session.
  let started =
    testing.post("/api/auth/passkeys/login", json.object([]))
    |> support.from_browser
    |> testing.send(app)
  assert started.status == 200
  assert testing.json(started, support.string_at(["options", "rpId"]))
    == Ok("localhost")
  assert testing.json(
      started,
      support.string_at(["options", "userVerification"]),
    )
    == Ok("required")
}
