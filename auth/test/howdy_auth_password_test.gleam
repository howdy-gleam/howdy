//// Password registration, login and storage.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gloo/repo
import howdy/auth
import howdy/auth/internal/token as auth_token
import howdy/auth/password_hasher
import howdy/auth/secret
import howdy/auth/user
import howdy/service
import howdy/testing
import support.{app, count, exec, fixture, signup}

// Registering with a password cannot be answered from the inbox, so that path
// keeps its own per-address cooldown, and the cooldown doubles.
pub fn password_registration_cooldown_is_persistent_and_doubles_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let assert Ok(Nil) =
    auth.register_password(identity, "new@example.com", strong_password)
  let assert Ok(_) = process.receive(mailbox, 1000)
  let assert Error(service.TooManyRequests(wait)) =
    auth.register_password(identity, "NEW@example.com", strong_password)
  assert wait > 0 && wait <= 60
  assert process.receive(mailbox, 0) == Error(Nil)
  exec(
    database,
    "UPDATE howdy_auth_throttles SET next_at = "
      <> int.to_string(auth_token.now()),
  )
  let assert Ok(Nil) =
    auth.register_password(identity, "new@example.com", strong_password)
  let assert Error(service.TooManyRequests(wait)) =
    auth.register_password(identity, "new@example.com", strong_password)
  assert wait > 60 && wait <= 120
  exec(database, "UPDATE howdy_auth_throttles SET next_at = 0")
  let assert Ok(Nil) =
    auth.register_password(identity, "new@example.com", strong_password)
  let assert Error(service.TooManyRequests(wait)) =
    auth.register_password(identity, "new@example.com", strong_password)
  assert wait <= 60
}

const strong_password = "an uncommon orchard phrase 947!"

fn password_signup(
  identity: auth.Auth,
  mailbox: process.Subject(auth.Delivery),
  email: String,
  password: String,
) {
  let assert Ok(Nil) = auth.register_password(identity, email, password)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let assert Ok(session) =
    auth.exchange(identity, secret.reveal(delivery.token))
  session
}

pub fn password_registration_requires_email_and_stores_only_a_salted_hash_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let assert Ok(Nil) =
    auth.register_password(identity, "ada@example.com", strong_password)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 0
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_passwords") == 0
  let assert Ok([encoded]) =
    repo.all(
      database,
      "SELECT password_hash FROM howdy_auth_challenges",
      [],
      decode.field(0, decode.string, decode.success),
    )
  assert string.starts_with(encoded, "$pbkdf2-sha256$i=600000,l=32$")
  assert !string.contains(encoded, strong_password)
  assert password_hasher.pbkdf2_sha256().verify(encoded, strong_password)
    == Ok(True)
  assert auth.login_password(identity, "ada@example.com", strong_password)
    == Error(service.Unauthorized)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let assert Ok(session) =
    auth.exchange(identity, secret.reveal(delivery.token))
  let assert Ok([stored]) =
    repo.all(
      database,
      "SELECT encoded_hash FROM howdy_auth_passwords",
      [],
      decode.field(0, decode.string, decode.success),
    )
  assert stored == encoded
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_challenges") == 0
  let assert Ok(login) =
    auth.login_password(identity, " ADA@example.com ", strong_password)
  assert login.user == session.user
  assert secret.reveal(login.token) != secret.reveal(session.token)
  assert auth.login_password(identity, "ada@example.com", "wrong password")
    == Error(service.Unauthorized)
  let second =
    password_signup(identity, mailbox, "other@example.com", strong_password)
  let assert Ok(hashes) =
    repo.all(
      database,
      "SELECT encoded_hash FROM howdy_auth_passwords",
      [],
      decode.field(0, decode.string, decode.success),
    )
  assert list.length(list.unique(hashes)) == 2
  assert second.user.id != session.user.id
}

pub fn password_method_and_registration_are_explicitly_enabled_test() {
  use database, identity, permissions, mailbox <- fixture
  assert auth.register_password(identity, "ada@example.com", strong_password)
    == Error(service.Forbidden)
  assert auth.login_password(identity, "ada@example.com", strong_password)
    == Error(service.Forbidden)
  assert testing.get("/auth/password/login")
    |> testing.send(app(identity, permissions))
    |> fn(r) { r.status }
    == 404
  let assert Ok(enabled) = auth.with_passwords(identity)
  let assert Ok(Nil) =
    auth.register_password(enabled, "ada@example.com", strong_password)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert auth.exchange(identity, secret.reveal(delivery.token))
    == Error(service.Forbidden)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 0
  let assert Ok(closed) =
    auth.new(database, "https://example.test", fn(_) { Ok(Nil) })
  let assert Ok(closed) = auth.with_passwords(closed)
  assert auth.register_password(closed, "other@example.com", strong_password)
    == Error(service.Forbidden)
}

pub fn password_policy_and_exact_input_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let assert Error(service.Coded(_, service.Invalid(_))) =
    auth.register_password(identity, "short@example.com", "short")
  let assert Error(service.Coded(_, service.Invalid(_))) =
    auth.register_password(
      identity,
      "large@example.com",
      string.repeat("a", 1025),
    )
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_challenges") == 0
  let exact = "  a long passphrase with spaces  "
  let _ = password_signup(identity, mailbox, "ada@example.com", exact)
  let assert Ok(_) = auth.login_password(identity, "ada@example.com", exact)
  assert auth.login_password(identity, "ada@example.com", string.trim(exact))
    == Error(service.Unauthorized)
  assert auth.login_password(
      identity,
      "ada@example.com",
      string.repeat("a", 1025),
    )
    == Error(service.Unauthorized)
}

pub fn password_registration_never_overwrites_existing_credentials_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let first =
    password_signup(identity, mailbox, "ada@example.com", strong_password)
  exec(database, "DELETE FROM howdy_auth_throttles")
  let assert Ok(Nil) =
    auth.register_password(
      identity,
      "ada@example.com",
      "a totally different password",
    )
  // The address already has an account, so the password in that request is
  // discarded and the token only offers to sign the account in.
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert delivery.purpose == auth.AlreadyRegistered
  let assert Ok(signed_in) =
    auth.exchange(identity, secret.reveal(delivery.token))
  assert signed_in.user.id == first.user.id
  let assert Ok(session) =
    auth.login_password(identity, "ada@example.com", strong_password)
  assert session.user.id == first.user.id
  assert auth.login_password(
      identity,
      "ada@example.com",
      "a totally different password",
    )
    == Error(service.Unauthorized)
  // The same holds for an account that has never had a password: registering
  // one for it does not attach the credential.
  let _ = signup(identity, mailbox, "email-only@example.com")
  exec(database, "DELETE FROM howdy_auth_throttles")
  let assert Ok(Nil) =
    auth.register_password(identity, "email-only@example.com", strong_password)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert delivery.purpose == auth.AlreadyRegistered
  let assert Ok(_) = auth.exchange(identity, secret.reveal(delivery.token))
  assert auth.login_password(
      identity,
      "email-only@example.com",
      strong_password,
    )
    == Error(service.Unauthorized)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_passwords") == 1
}

pub fn password_login_is_throttled_and_suspension_is_enforced_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let session =
    password_signup(identity, mailbox, "ada@example.com", strong_password)
  list.each(list.repeat(Nil, 5), fn(_) {
    assert auth.login_password(identity, "ada@example.com", "wrong")
      == Error(service.Unauthorized)
  })
  let assert Error(service.TooManyRequests(wait)) =
    auth.login_password(identity, "ADA@example.com", strong_password)
  assert wait > 0 && wait <= 60
  exec(database, "UPDATE howdy_auth_password_attempts SET window_start = 0")
  exec(database, "UPDATE howdy_auth_password_clients SET next_at = 0")
  let assert Ok(_) =
    auth.login_password(identity, "ada@example.com", strong_password)
  let assert Ok(Nil) = auth.suspend(identity, session.user.id, by: user.System)
  assert auth.login_password(identity, "ada@example.com", strong_password)
    == Error(service.Unauthorized)
  assert auth.authenticate(identity, secret.reveal(session.token))
    == Error(service.Unauthorized)
  assert auth.login_password(identity, "missing@example.com", strong_password)
    == Error(service.Unauthorized)
}

pub fn password_corrupt_hash_fails_closed_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let _ = password_signup(identity, mailbox, "ada@example.com", strong_password)
  exec(database, "UPDATE howdy_auth_passwords SET encoded_hash = 'invalid'")
  let assert Error(service.Internal(_)) =
    auth.login_password(identity, "ada@example.com", strong_password)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_sessions") == 1
}

// RFC 7914 section 11 publishes this PBKDF2-HMAC-SHA256 vector.
pub fn pbkdf2_matches_rfc_7914_test() {
  let assert Ok(expected) =
    bit_array.base16_decode(
      "55AC046E56E3089FEC1691C22544B605F94185216DDE0465E68B9D57C20DACBC49CA9CCCF179B645991664B39D77EF317C71B845B1E30BD509112041D3A19783",
    )
  assert password_hasher.encode("passwd", <<"salt":utf8>>, 1, 64)
    == "$pbkdf2-sha256$i=1,l=64$c2FsdA$"
    <> bit_array.base64_encode(expected, False)
}

// Independent vector at the production cost, from Python's
// hashlib.pbkdf2_hmac("sha256", password, b"howdy-test-salt!", 600000, 32).
pub fn pbkdf2_matches_independent_production_cost_vector_test() {
  let hasher = password_hasher.pbkdf2_sha256()
  let encoded =
    "$pbkdf2-sha256$i=600000,l=32$aG93ZHktdGVzdC1zYWx0IQ$Q1xdrHPFCPNbbmkCF5W1ZRzJrl5Dua7D+Wf98ZKNNUM"
  assert password_hasher.encode(
      "correct horse battery staple",
      <<"howdy-test-salt!":utf8>>,
      600_000,
      32,
    )
    == encoded
  assert hasher.verify(encoded, "correct horse battery staple") == Ok(True)
  assert hasher.verify(encoded, "correct horse battery stapler") == Ok(False)
  assert !hasher.needs_rehash(encoded)
}

pub fn pbkdf2_rejects_malformed_and_foreign_hashes_test() {
  let hasher = password_hasher.pbkdf2_sha256()
  let argon2 =
    "$argon2id$v=19$m=19456,t=2,p=1$aG93ZHktdGVzdC1zYWx0IQ$vFOYm5GpcreowRemt/3tyMf0N3iLaaJXBzBA8LCaaXM"
  let salt =
    "$aG93ZHktdGVzdC1zYWx0IQ$Q1xdrHPFCPNbbmkCF5W1ZRzJrl5Dua7D+Wf98ZKNNUM"
  list.each(
    [
      argon2,
      "invalid",
      "",
      // Declared length disagrees with the hash.
      "$pbkdf2-sha256$i=600000,l=31" <> salt,
      // Unbounded or absent work.
      "$pbkdf2-sha256$i=0,l=32" <> salt,
      "$pbkdf2-sha256$i=99999999,l=32" <> salt,
      "$pbkdf2-sha256$i=600000,l=32$aG93ZHk$Q1xdrHPFCPNbbmkCF5W1ZRzJrl5Dua7D+Wf98ZKNNUM",
      "$pbkdf2-sha512$i=600000,l=32" <> salt,
    ],
    fn(encoded) {
      assert hasher.verify(encoded, "correct horse battery staple")
        == Error(Nil)
      assert hasher.needs_rehash(encoded)
    },
  )
}

const replacement = "a second unlikely harbour phrase 512!"

fn principal(identity, session: auth.Session) {
  let assert Ok(p) = auth.authenticate(identity, secret.reveal(session.token))
  p
}

pub fn current_password_changes_the_password_without_a_fresh_email_login_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let _ = password_signup(identity, mailbox, "ada@example.com", strong_password)
  let assert Ok(other) =
    auth.login_password(identity, "ada@example.com", strong_password)
  let assert Ok(session) =
    auth.login_password(identity, "ada@example.com", strong_password)
  // A password session is no fresh email login, so set_password refuses it.
  exec(
    database,
    "UPDATE howdy_auth_sessions SET created_at = created_at - 9000",
  )
  let p = principal(identity, session)
  assert auth.set_password(identity, p, replacement) == Error(service.Forbidden)

  assert auth.change_password(identity, p, current: "wrong", new: replacement)
    == Error(service.Coded(
      "password_incorrect",
      service.Invalid("current password is incorrect"),
    ))
  assert auth.change_password(identity, p, current: "", new: replacement)
    == Error(service.Coded(
      "password_incorrect",
      service.Invalid("current password is incorrect"),
    ))
  assert auth.change_password(
      identity,
      p,
      current: strong_password,
      new: strong_password,
    )
    == Error(service.Coded(
      "password_unchanged",
      service.Invalid("new password must differ from the current"),
    ))
  assert result.is_error(auth.change_password(
    identity,
    p,
    current: strong_password,
    new: "short",
  ))
  assert process.receive(mailbox, 0) == Error(Nil)
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'password.change_failed'",
    )
    == 1

  assert auth.change_password(
      identity,
      p,
      current: strong_password,
      new: replacement,
    )
    == Ok(Nil)
  let assert Ok(notice) = process.receive(mailbox, 1000)
  assert notice.purpose == auth.PasswordChanged
  assert notice.email == "ada@example.com"
  assert secret.reveal(notice.token) == ""
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'password.changed'",
    )
    == 1
  // This session survives; every other one is gone, as is the old password.
  assert result.is_ok(auth.authenticate(identity, secret.reveal(session.token)))
  assert auth.authenticate(identity, secret.reveal(other.token))
    == Error(service.Unauthorized)
  assert auth.login_password(identity, "ada@example.com", strong_password)
    == Error(service.Unauthorized)
  assert result.is_ok(auth.login_password(
    identity,
    "ada@example.com",
    replacement,
  ))
}

pub fn current_password_guesses_share_the_login_budget_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let session =
    password_signup(identity, mailbox, "ada@example.com", strong_password)
  let p = principal(identity, session)
  list.each(list.repeat(Nil, 5), fn(_) {
    assert auth.change_password(identity, p, current: "wrong", new: replacement)
      == Error(service.Coded(
        "password_incorrect",
        service.Invalid("current password is incorrect"),
      ))
  })
  let assert Error(service.TooManyRequests(wait)) =
    auth.change_password(
      identity,
      p,
      current: strong_password,
      new: replacement,
    )
  assert wait > 0 && wait <= 60
  // The same budget: the login form is closed to this client as well.
  let assert Error(service.TooManyRequests(_)) =
    auth.login_password(identity, "ada@example.com", strong_password)
  exec(database, "UPDATE howdy_auth_password_attempts SET window_start = 0")
  exec(database, "UPDATE howdy_auth_password_clients SET next_at = 0")
  assert auth.change_password(
      identity,
      p,
      current: strong_password,
      new: replacement,
    )
    == Ok(Nil)
  // Success clears the back-off, as a successful login does.
  assert result.is_ok(auth.login_password(
    identity,
    "ada@example.com",
    replacement,
  ))
}

pub fn password_change_needs_a_password_a_live_session_and_the_method_test() {
  use _, identity, _, mailbox <- fixture
  let session = signup(identity, mailbox, "ada@example.com")
  assert auth.change_password(
      identity,
      principal(identity, session),
      current: strong_password,
      new: replacement,
    )
    == Error(service.Forbidden)
  let assert Ok(identity) = auth.with_passwords(identity)
  // An email-only account has no current password to prove.
  let p = principal(identity, session)
  assert auth.change_password(
      identity,
      p,
      current: strong_password,
      new: replacement,
    )
    == Error(service.Forbidden)
  assert auth.set_password(identity, p, strong_password) == Ok(Nil)
  assert auth.logout(identity, p) == Ok(Nil)
  assert auth.change_password(
      identity,
      p,
      current: strong_password,
      new: replacement,
    )
    == Error(service.Unauthorized)
  assert result.is_ok(auth.login_password(
    identity,
    "ada@example.com",
    strong_password,
  ))
}

pub fn password_change_endpoint_requires_session_origin_and_both_fields_test() {
  use _, identity, permissions, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let session =
    password_signup(identity, mailbox, "ada@example.com", strong_password)
  let app = app(identity, permissions)
  let body =
    json.object([
      #("current", json.string(strong_password)),
      #("password", json.string(replacement)),
    ])
  let send = fn(request) {
    request
    |> testing.header("origin", "https://example.test")
    |> testing.send(app)
    |> fn(r) { r.status }
  }
  assert send(testing.post("/api/auth/password/change", body)) == 401
  let signed_in = fn(body) {
    testing.post("/api/auth/password/change", body)
    |> testing.cookie("__Host-howdy_session", secret.reveal(session.token))
  }
  assert signed_in(body) |> testing.send(app) |> fn(r) { r.status } == 403
  assert send(signed_in(json.object([#("password", json.string(replacement))])))
    != 204
  assert send(
      signed_in(
        json.object([
          #("current", json.string("wrong")),
          #("password", json.string(replacement)),
        ]),
      ),
    )
    == 400
  assert send(signed_in(body)) == 204
  assert result.is_ok(auth.login_password(
    identity,
    "ada@example.com",
    replacement,
  ))
}
