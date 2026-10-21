//// Token requests, audit attribution and the housekeeping around them.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import gloo/repo
import howdy
import howdy/auth
import howdy/auth/internal/token as auth_token
import howdy/auth/pages
import howdy/auth/policy
import howdy/auth/routes
import howdy/auth/secret
import howdy/auth/user
import howdy/authorization as access
import howdy/service
import howdy/testing
import support.{count, exec, fixture, signup}

fn strings(database, sql) -> List(String) {
  let assert Ok(rows) =
    repo.all(database, sql, [], decode.field(0, decode.string, decode.success))
  rows
}

// Whoever asks, the owner of the address ends up holding exactly one live
// token: a stranger can neither empty nor fill that inbox.
pub fn a_stranger_cannot_deny_the_owner_a_token_test() {
  use _, identity, _, mailbox <- fixture
  let stranger = fn(client) {
    assert auth.request_token_from(
        identity,
        "ada@example.com",
        auth.Register,
        client,
      )
      == Ok(Nil)
  }
  list.each(["a", "b", "c", "d", "e", "f", "g", "h"], stranger)
  // One email for eight requests from eight different clients.
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert process.receive(mailbox, 0) == Error(Nil)
  // The owner asks after all that and is not refused.
  assert auth.request_token_from(
      identity,
      "ada@example.com",
      auth.Register,
      "the-owner",
    )
    == Ok(Nil)
  // What arrived in their inbox is a token that works.
  let assert Ok(session) =
    auth.exchange(identity, secret.reveal(delivery.token))
  assert session.user.email == "ada@example.com"
}

pub fn token_requests_are_attributed_to_the_account_test() {
  use database, identity, _, mailbox <- fixture
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(Nil) =
    auth.request_token_from(
      identity,
      "ada@example.com",
      auth.Login,
      "203.0.113.7",
    )
  let assert Ok(_) = process.receive(mailbox, 1000)
  let row = {
    use client <- decode.field(0, decode.string)
    use detail <- decode.field(1, decode.string)
    decode.success(#(client, detail))
  }
  let assert Ok([#(client, detail)]) =
    repo.all(
      database,
      "SELECT client, detail FROM howdy_auth_events WHERE action = 'token.requested'",
      [],
      row,
    )
  assert client == "203.0.113.7"
  assert detail == "sign-in"
  assert session.user.email == "ada@example.com"
  // An address with no account has nothing to attribute the request to.
  let assert Ok(Nil) =
    auth.request_token_from(
      identity,
      "nobody@example.com",
      auth.Login,
      "203.0.113.7",
    )
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'token.requested'",
    )
    == 1
}

pub fn sessions_and_events_record_where_a_request_came_from_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(Nil) =
    auth.request_token(identity, "ada@example.com", auth.Register)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let assert Ok(session) =
    auth.exchange_from(identity, secret.reveal(delivery.token), "198.51.100.4")
  let assert Ok(principal) =
    auth.authenticate_from(
      identity,
      secret.reveal(session.token),
      "198.51.100.9",
    )
  let assert Ok([info]) = auth.sessions(identity, principal)
  // The session remembers where it was created, not where it is being used.
  assert info.client == "198.51.100.4"
  // An operation records the client of the request that performed it.
  let assert Ok(Nil) =
    auth.revoke_sessions(
      identity,
      principal.user.id,
      by: user.Acting(principal),
    )
  assert strings(
      database,
      "SELECT client FROM howdy_auth_events WHERE action = 'sessions.revoked'",
    )
    == ["198.51.100.9"]
  assert strings(
      database,
      "SELECT client FROM howdy_auth_events WHERE action = 'session.created'",
    )
    == ["198.51.100.4"]
  // A system actor can still say where an operator request arrived from.
  let assert Ok(Nil) =
    auth.suspend(
      identity,
      principal.user.id,
      by: user.SystemFrom("ops-console"),
    )
  assert strings(
      database,
      "SELECT actor_id || '/' || client FROM howdy_auth_events WHERE action = 'user.suspended'",
    )
    == ["/ops-console"]
}

pub fn http_routes_record_the_configured_client_identity_test() {
  use database, identity, permissions, mailbox <- fixture
  let app =
    howdy.new()
    |> howdy.controller(routes.api(identity, at: "/api/auth"))
  let _ = permissions
  let session = signup(identity, mailbox, "ada@example.com")
  assert testing.post("/api/auth/logout", json.null())
    |> testing.from_ip("192.0.2.33")
    |> testing.header(
      "authorization",
      "Bearer " <> secret.reveal(session.token),
    )
    |> testing.send(app)
    |> fn(r) { r.status }
    == 204
  assert strings(
      database,
      "SELECT client FROM howdy_auth_events WHERE action = 'session.revoked'",
    )
    == ["192.0.2.33"]
}

// The rows that record which addresses have been asking are keyed with a
// secret of this installation, so they cannot be matched against a guess.
pub fn throttle_rows_do_not_reveal_which_addresses_asked_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let assert Ok(Nil) =
    auth.register_password(
      identity,
      "ada@example.com",
      "an uncommon orchard phrase 947!",
    )
  let assert Ok(_) = process.receive(mailbox, 1000)
  let keys = strings(database, "SELECT key FROM howdy_auth_throttles")
  assert keys != []
  assert !list.contains(keys, auth_token.digest("ada@example.com"))
  assert !list.any(keys, string.contains(_, "ada"))
  let assert Ok([secret]) =
    repo.all(
      database,
      "SELECT secret FROM howdy_auth_keys WHERE name = 'throttle'",
      [],
      decode.field(0, decode.string, decode.success),
    )
  assert list.contains(keys, auth_token.keyed_digest(secret, "ada@example.com"))
}

// The sweep that runs while an account is locked must not grow without bound.
pub fn expired_session_sweep_is_bounded_and_prune_finishes_it_test() {
  use database, identity, _, mailbox <- fixture
  let session = signup(identity, mailbox, "ada@example.com")
  let rows =
    list.map(list.repeat(Nil, 150), fn(_) {
      "('"
      <> auth_token.new()
      <> "', '"
      <> session.user.id
      <> "', 0, 0, 0, 'email', '')"
    })
  exec(
    database,
    "INSERT INTO howdy_auth_sessions(digest, user_id, expires_at, created_at, last_seen_at, method, client) VALUES "
      <> string.join(rows, ", "),
  )
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_sessions") == 151
  let assert Ok(Nil) =
    auth.request_token(identity, "ada@example.com", auth.Login)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let assert Ok(_) = auth.exchange(identity, secret.reveal(delivery.token))
  // One login clears a bounded slice, never the whole backlog.
  let remaining = count(database, "SELECT COUNT(*) FROM howdy_auth_sessions")
  assert remaining > 2 && remaining < 152
  let assert Ok(Nil) = auth.prune_expired(identity)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_sessions") == 2
}

pub fn a_role_can_hold_many_permissions_test() {
  use _, identity, permissions, mailbox <- fixture
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let names =
    list.map(list.repeat(Nil, 250), fn(_) { auth_token.new() })
    |> list.index_map(fn(name, index) { "p" <> int.to_string(index) <> name })
  let assert Ok(Nil) =
    access.define_role(
      permissions,
      access.Global,
      "wide",
      names,
      by: user.System,
    )
  let assert Ok(Nil) =
    access.assign(
      permissions,
      principal.user.id,
      "wide",
      access.Global,
      by: user.System,
    )
  let assert [first, ..] = names
  let assert Ok(last) = list.last(names)
  assert access.allowed(permissions, principal, first, access.Global)
    == Ok(True)
  assert access.allowed(permissions, principal, last, access.Global) == Ok(True)
  assert access.allowed(permissions, principal, "absent", access.Global)
    == Ok(False)
  // Replacing the set removes every one of them.
  let assert Ok(Nil) =
    access.define_role(
      permissions,
      access.Global,
      "wide",
      ["only"],
      by: user.System,
    )
  assert access.allowed(permissions, principal, first, access.Global)
    == Ok(False)
  assert access.allowed(permissions, principal, "only", access.Global)
    == Ok(True)
}

// The address on the account is the one thing sign-in reads, so a stale
// identity row cannot become a second, disagreeing answer.
pub fn the_account_address_is_the_only_one_that_signs_in_test() {
  use database, identity, _, mailbox <- fixture
  let session = signup(identity, mailbox, "ada@example.com")
  exec(
    database,
    "UPDATE howdy_auth_identities SET subject = 'stale@example.com'",
  )
  let assert Ok(Nil) =
    auth.request_token(identity, "ada@example.com", auth.Login)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let assert Ok(signed_in) =
    auth.exchange(identity, secret.reveal(delivery.token))
  assert signed_in.user.id == session.user.id
  // The stale value is not a way in.
  let assert Ok(Nil) =
    auth.request_token(identity, "stale@example.com", auth.Login)
  let assert Ok(stale) = process.receive(mailbox, 1000)
  assert auth.exchange(identity, secret.reveal(stale.token))
    == Error(service.Unauthorized)
}

pub fn the_page_script_is_revalidated_rather_than_refetched_test() {
  use _, identity, _, _ <- fixture
  let app =
    howdy.new()
    |> howdy.controller(pages.routes(identity, at: "/auth", api_at: "/api/auth"))
  let first = testing.get("/auth/client.js") |> testing.send(app)
  assert first.status == 200
  let assert Ok(tag) = response.get_header(first, "etag")
  assert response.get_header(first, "cache-control") == Ok("no-cache")
  let again =
    testing.get("/auth/client.js")
    |> testing.header("if-none-match", tag)
    |> testing.send(app)
  assert again.status == 304
  assert testing.text(again) == ""
  // Pages themselves are still never stored.
  let page = testing.get("/auth/login") |> testing.send(app)
  assert response.get_header(page, "cache-control") == Ok("no-store")
}

pub fn policy_rejects_a_coalescing_window_longer_than_the_token_test() {
  use _, identity, _, _ <- fixture
  let assert Error(service.Invalid(_)) =
    auth.with_policy(
      identity,
      policy.Policy(
        ..policy.default(),
        email_coalesce_margin_seconds: policy.default().challenge_seconds + 1,
      ),
    )
}
