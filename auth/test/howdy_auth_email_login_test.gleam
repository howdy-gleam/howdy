import gleam/erlang/process
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import howdy/auth
import howdy/auth/secret
import howdy/service
import howdy/testing
import support.{app, count, fixture, signup}

fn received(mailbox) -> auth.Delivery {
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  delivery
}

fn code(delivery: auth.Delivery) -> String {
  let assert Some(code) = delivery.code
  secret.reveal(code)
}

/// Another six-digit code, so a guess is never right by chance.
fn wrong(code: String) -> String {
  case code {
    "000000" -> "000001"
    _ -> "000000"
  }
}

pub fn emailed_links_carry_the_token_in_the_fragment_test() {
  use _, identity, _, mailbox <- fixture
  assert auth.with_email_links(identity, at: "auth") |> result_is_invalid
  assert auth.with_email_links(identity, at: "/auth/") |> result_is_invalid
  assert auth.with_email_links(identity, at: "/a\"b") |> result_is_invalid
  let assert Ok(Nil) =
    auth.request_token(identity, "plain@example.com", auth.Register)
  let plain = received(mailbox)
  assert plain.link == None
  assert plain.code == None

  let assert Ok(identity) = auth.with_email_links(identity, at: "/auth")
  let assert Ok(Nil) =
    auth.request_token(identity, "ada@example.com", auth.Register)
  let delivery = received(mailbox)
  let assert Some(link) = delivery.link
  assert secret.reveal(link)
    == "https://example.test/auth/login#token=" <> secret.reveal(delivery.token)
  let assert Ok(session) =
    auth.exchange(identity, secret.reveal(delivery.token))
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let assert Ok(Nil) =
    auth.request_email_change(identity, principal, "lovelace@example.com")
  let change = received(mailbox)
  assert change.purpose == auth.EmailChange
  let assert Some(link) = change.link
  assert secret.reveal(link)
    == "https://example.test/auth/account#email-confirm="
    <> secret.reveal(change.token)
}

fn result_is_invalid(result: Result(a, service.Error)) -> Bool {
  case result {
    Error(service.Invalid(_)) -> True
    _ -> False
  }
}

pub fn an_emailed_code_signs_in_once_with_its_address_test() {
  use _, identity, _, mailbox <- fixture
  let _ = signup(identity, mailbox, "ada@example.com")
  assert auth.exchange_code_step(identity, "ada@example.com", "123456", "t")
    == Error(service.Forbidden)
  let identity = auth.with_email_codes(identity)
  assert auth.email_codes_enabled(identity)
  let assert Ok(Nil) =
    auth.request_token(identity, "ada@example.com", auth.Login)
  let delivery = received(mailbox)
  let code = code(delivery)
  assert string.length(code) == 6
  assert auth.exchange_code_step(identity, "grace@example.com", code, "t")
    == Error(service.Unauthorized)
  assert auth.exchange_code_step(identity, "ada@example.com", "12345", "t")
    == Error(service.Unauthorized)
  let assert Ok(auth.SignedIn(session)) =
    auth.exchange_code_step(identity, " ADA@example.com ", " " <> code, "t")
  assert session.user.email == "ada@example.com"
  // The code and the token beside it are one credential, spent together.
  assert auth.exchange_code_step(identity, "ada@example.com", code, "t")
    == Error(service.Unauthorized)
  assert auth.exchange(identity, secret.reveal(delivery.token))
    == Error(service.Unauthorized)
}

pub fn a_code_registers_a_new_account_test() {
  use _, identity, _, mailbox <- fixture
  let identity = auth.with_email_codes(identity)
  let assert Ok(Nil) =
    auth.request_token(identity, "new@example.com", auth.Register)
  let delivery = received(mailbox)
  assert delivery.purpose == auth.Registration
  let assert Ok(auth.SignedIn(session)) =
    auth.exchange_code_step(identity, "new@example.com", code(delivery), "t")
  assert session.user.email == "new@example.com"
}

pub fn three_wrong_guesses_retire_a_code_but_not_its_token_test() {
  use database, identity, _, mailbox <- fixture
  let _ = signup(identity, mailbox, "ada@example.com")
  let identity = auth.with_email_codes(identity)
  let assert Ok(Nil) =
    auth.request_token(identity, "ada@example.com", auth.Login)
  let delivery = received(mailbox)
  let code = code(delivery)
  list.each([1, 2, 3], fn(_) {
    assert auth.exchange_code_step(
        identity,
        "ada@example.com",
        wrong(code),
        "t",
      )
      == Error(service.Unauthorized)
  })
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_challenges WHERE code_digest IS NOT NULL",
    )
    == 0
  assert auth.exchange_code_step(identity, "ada@example.com", code, "t")
    == Error(service.Unauthorized)
  let assert Ok(_) = auth.exchange(identity, secret.reveal(delivery.token))
}

pub fn code_guesses_share_the_password_limits_test() {
  use _, identity, _, mailbox <- fixture
  let _ = signup(identity, mailbox, "ada@example.com")
  let identity = auth.with_email_codes(identity)
  let limit = auth.policy(identity).password_account_attempts
  // Guesses at an address with no live code still count.
  let outcomes =
    list.map(
      int.range(from: 1, to: limit + 2, with: [], run: fn(acc, i) { [i, ..acc] }),
      fn(i) {
        auth.exchange_code_step(
          identity,
          "ada@example.com",
          "000000",
          "c" <> int.to_string(i),
        )
      },
    )
  let assert Ok(Error(service.TooManyRequests(_))) = list.last(outcomes)
}

pub fn the_session_endpoint_accepts_an_emailed_code_test() {
  use _, identity, permissions, mailbox <- fixture
  let _ = signup(identity, mailbox, "ada@example.com")
  let identity = auth.with_email_codes(identity)
  let app = app(identity, permissions)
  let assert Ok(Nil) =
    auth.request_token(identity, "ada@example.com", auth.Login)
  let delivery = received(mailbox)
  let answer =
    testing.post(
      "/api/auth/session",
      json.object([
        #("email", json.string("ada@example.com")),
        #("code", json.string(code(delivery))),
      ]),
    )
    |> testing.header("origin", "https://example.test")
    |> testing.send(app)
  assert answer.status == 200
  let assert Ok(_) = response.get_header(answer, "set-cookie")
}
