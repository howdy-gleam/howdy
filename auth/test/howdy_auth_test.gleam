//// Email-token sign-in and registration: the core of the package.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleeunit
import gloo/repo
import howdy/auth
import howdy/auth/internal/token as auth_token
import howdy/auth/secret
import howdy/auth/user
import howdy/service
import support.{count, exec, fixture, signup}

pub fn main() {
  gleeunit.main()
}

pub fn registration_verifies_email_and_never_persists_raw_tokens_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(Nil) =
    auth.request_token(identity, " ADA@Example.com ", auth.Register)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 0
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert delivery.email == "ada@example.com"
  let conn = database
  let assert Ok([digest]) =
    repo.all(
      conn,
      "SELECT digest FROM howdy_auth_challenges",
      [],
      decode.field(0, decode.string, decode.success),
    )
  assert digest != secret.reveal(delivery.token)
  let assert Ok(session) =
    auth.exchange(identity, secret.reveal(delivery.token))
  assert auth.exchange(identity, secret.reveal(delivery.token))
    == Error(service.Unauthorized)
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  assert principal.user == session.user
  assert principal.session_id != secret.reveal(session.token)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 1
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_identities") == 1
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_events") == 2
}

pub fn challenge_expiry_unknown_login_and_registration_disabled_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(Nil) =
    auth.request_token(identity, "missing@example.com", auth.Login)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert auth.exchange(identity, secret.reveal(delivery.token))
    == Error(service.Unauthorized)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 0
  let assert Ok(Nil) =
    auth.request_token(identity, "expired@example.com", auth.Register)
  let assert Ok(expired) = process.receive(mailbox, 1000)
  exec(database, "UPDATE howdy_auth_challenges SET expires_at = 0")
  assert auth.exchange(identity, secret.reveal(expired.token))
    == Error(service.Unauthorized)
  let assert Ok(closed) =
    auth.new(database, "https://example.test", fn(_) { Ok(Nil) })
  assert auth.request_token(closed, "new@example.com", auth.Register)
    == Error(service.Forbidden)
}

pub fn challenge_cannot_register_after_registration_is_disabled_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(Nil) =
    auth.request_token(identity, "new@example.com", auth.Register)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let assert Ok(closed) =
    auth.new(database, "https://example.test", fn(_) { Ok(Nil) })
  assert auth.exchange(closed, secret.reveal(delivery.token))
    == Error(service.Forbidden)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 0
}

// A token request that finds a usable token already waiting reports success
// and sends nothing: the owner of the inbox has one either way. Nobody is
// refused, so nobody can be locked out by someone else asking.
pub fn repeated_token_requests_send_one_email_and_never_refuse_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(Nil) =
    auth.request_token(identity, "new@example.com", auth.Register)
  let assert Ok(first) = process.receive(mailbox, 1000)
  // A stranger asking repeatedly, from anywhere, neither fills the inbox nor
  // stops the owner asking.
  list.each(["a", "b", "c", "d", "e"], fn(attempt) {
    assert auth.request_token_from(
        identity,
        "NEW@example.com",
        auth.Register,
        "attacker-" <> attempt,
      )
      == Ok(Nil)
  })
  assert auth.request_token_from(
      identity,
      "new@example.com",
      auth.Register,
      "the-owner",
    )
    == Ok(Nil)
  assert process.receive(mailbox, 0) == Error(Nil)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_challenges") == 1
  // The token that was sent is the one that works.
  let assert Ok(_) = auth.exchange(identity, secret.reveal(first.token))
  // Once too little of it is left to be useful, the next request sends again.
  let assert Ok(Nil) =
    auth.request_token(identity, "new@example.com", auth.Login)
  let assert Ok(_) = process.receive(mailbox, 1000)
  exec(
    database,
    "UPDATE howdy_auth_challenges SET expires_at = "
      <> int.to_string(auth_token.now() + 60),
  )
  let assert Ok(Nil) =
    auth.request_token(identity, "new@example.com", auth.Login)
  let assert Ok(_) = process.receive(mailbox, 1000)
}

pub fn new_request_keeps_earlier_tokens_up_to_the_limit_test() {
  use database, identity, _, mailbox <- fixture
  let _ = signup(identity, mailbox, "ada@example.com")
  let request = fn() {
    let assert Ok(Nil) =
      auth.request_token(identity, "ada@example.com", auth.Login)
    let assert Ok(delivery) = process.receive(mailbox, 1000)
    // Age the challenge past the coalescing margin so the next request sends
    // a new one, and order them without waiting for the clock.
    exec(
      database,
      "UPDATE howdy_auth_challenges SET created_at = created_at - 100, expires_at = "
        <> int.to_string(auth_token.now() + 60),
    )
    secret.reveal(delivery.token)
  }
  let first = request()
  let second = request()
  let third = request()
  let fourth = request()
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_challenges") == 3
  assert auth.exchange(identity, first) == Error(service.Unauthorized)
  let assert Ok(_) = auth.exchange(identity, second)
  let assert Ok(_) = auth.exchange(identity, third)
  let assert Ok(_) = auth.exchange(identity, fourth)
}

pub fn successful_exchange_ends_the_email_backoff_test() {
  use database, identity, _, mailbox <- fixture
  let _ = signup(identity, mailbox, "ada@example.com")
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_throttles") == 0
  let assert Ok(Nil) =
    auth.request_token(identity, "ada@example.com", auth.Login)
}

pub fn delivery_failure_invalidates_challenge_test() {
  use database, _, _, _ <- fixture
  let assert Ok(identity) =
    auth.new(database, "https://example.test", fn(_) { Error(Nil) })
  assert auth.request_token(identity, "new@example.com", auth.Login)
    == Error(service.Internal("auth email delivery failed"))
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_challenges") == 0
}

pub fn concurrent_exchange_issues_exactly_one_session_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(Nil) =
    auth.request_token(identity, "new@example.com", auth.Register)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let replies = process.new_subject()
  let _ =
    process.spawn(fn() {
      process.send(
        replies,
        auth.exchange(identity, secret.reveal(delivery.token)),
      )
    })
  let _ =
    process.spawn(fn() {
      process.send(
        replies,
        auth.exchange(identity, secret.reveal(delivery.token)),
      )
    })
  let assert Ok(first) = process.receive(replies, 10_000)
  let assert Ok(second) = process.receive(replies, 10_000)
  assert list.length(
      list.filter([first, second], fn(r) {
        case r {
          Ok(_) -> True
          Error(_) -> False
        }
      }),
    )
    == 1
  assert list.contains([first, second], Error(service.Unauthorized))
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_sessions") == 1
}

pub fn session_expiry_logout_and_suspension_test() {
  use database, identity, _, mailbox <- fixture
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let assert Ok(Nil) = auth.logout(identity, principal)
  assert auth.authenticate(identity, secret.reveal(session.token))
    == Error(service.Unauthorized)
  exec(database, "DELETE FROM howdy_auth_throttles")
  let assert Ok(Nil) =
    auth.request_token(identity, "ada@example.com", auth.Login)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let assert Ok(session) =
    auth.exchange(identity, secret.reveal(delivery.token))
  let assert Ok(Nil) = auth.suspend(identity, session.user.id, by: user.System)
  assert auth.authenticate(identity, secret.reveal(session.token))
    == Error(service.Unauthorized)
  let assert Ok(Nil) = auth.resume(identity, session.user.id, by: user.System)
  assert auth.authenticate(identity, secret.reveal(session.token))
    == Error(service.Unauthorized)
  exec(database, "DELETE FROM howdy_auth_throttles")
  let assert Ok(Nil) =
    auth.request_token(identity, "ada@example.com", auth.Login)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let assert Ok(session) =
    auth.exchange(identity, secret.reveal(delivery.token))
  exec(database, "UPDATE howdy_auth_sessions SET expires_at = 0")
  assert auth.authenticate(identity, secret.reveal(session.token))
    == Error(service.Unauthorized)
}

// Asking to register an address that already has an account sends that
// account a sign-in token and says so, rather than a registration token that
// could only fail. The reply to the caller is the same either way.
pub fn registering_an_existing_address_offers_sign_in_test() {
  use database, identity, _, mailbox <- fixture
  let first = signup(identity, mailbox, "ada@example.com")
  let assert Ok(Nil) =
    auth.request_token(identity, "ada@example.com", auth.Register)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert delivery.purpose == auth.AlreadyRegistered
  let assert Ok(session) =
    auth.exchange(identity, secret.reveal(delivery.token))
  assert session.user.id == first.user.id
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(first.token))
  assert principal.user.id == first.user.id
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 1
  // An address with no account still registers normally.
  let assert Ok(Nil) =
    auth.request_token(identity, "grace@example.com", auth.Register)
  let assert Ok(new_delivery) = process.receive(mailbox, 1000)
  assert new_delivery.purpose == auth.Registration
  let assert Ok(_) = auth.exchange(identity, secret.reveal(new_delivery.token))
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 2
}

pub fn origin_and_schema_validation_test() {
  use database, _, _, _ <- fixture
  let deliver = fn(_) { Ok(Nil) }
  let assert Error(_) = auth.new(database, "http://public.example", deliver)
  let assert Error(_) =
    auth.new(database, "https://example.com/database", deliver)
  let assert Error(_) = auth.new(database, "https://user@example.com", deliver)
  let assert Ok(local) = auth.new(database, "http://localhost:8787", deliver)
  assert auth.secure(local) == False
}

pub fn malformed_email_is_rejected_before_delivery_test() {
  use _, identity, _, mailbox <- fixture
  list.each(
    ["missing-at", "x@", "x@foo\nbar.com", "x@foo\u{0000}bar.com"],
    fn(email) {
      assert auth.request_token(identity, email, auth.Register)
        == Error(service.Coded(
          "email_invalid",
          service.Invalid("invalid email address"),
        ))
    },
  )
  assert process.receive(mailbox, 0) == Error(Nil)
}

pub fn concurrent_email_requests_send_a_single_token_test() {
  use database, identity, _, mailbox <- fixture
  let replies = process.new_subject()
  let request = fn(client) {
    process.spawn(fn() {
      process.send(
        replies,
        auth.request_token_from(
          identity,
          "race@example.com",
          auth.Register,
          client,
        ),
      )
    })
  }
  let _ = request("one")
  let _ = request("two")
  let assert Ok(a) = process.receive(replies, 10_000)
  let assert Ok(b) = process.receive(replies, 10_000)
  // Neither request is refused, and only one of them sends.
  assert [a, b] == [Ok(Nil), Ok(Nil)]
  let assert Ok(_) = process.receive(mailbox, 1000)
  assert process.receive(mailbox, 0) == Error(Nil)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_challenges") == 1
}
