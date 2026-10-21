//// Operator tooling: listing users, reading suspension, and issuing a
//// session for a user without a credential.

import gleam/erlang/process
import gleam/list
import gleam/string
import howdy/auth
import howdy/auth/secret
import howdy/auth/user
import howdy/auth/users
import howdy/service
import support.{count, fixture, signup}

pub fn impersonation_issues_an_audited_session_test() {
  use database, identity, _, mailbox <- fixture
  let ada = signup(identity, mailbox, "ada@example.com")
  let assert Ok(session) =
    auth.impersonate(identity, ada.user.id, by: user.SystemFrom("admin"))
  assert session.user.id == ada.user.id
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  assert principal.user.email == "ada@example.com"
  let assert Ok(listed) = auth.sessions(identity, principal)
  let assert [current] = list.filter(listed, fn(s) { s.current })
  assert current.method == auth.Impersonation
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'session.impersonated' AND client = 'admin'",
    )
    == 1
}

pub fn impersonation_refuses_unknown_and_suspended_users_test() {
  use _, identity, _, mailbox <- fixture
  let ada = signup(identity, mailbox, "ada@example.com")
  assert auth.impersonate(identity, "nobody", by: user.System)
    == Error(service.NotFound("user"))
  let assert Ok(Nil) = auth.suspend(identity, ada.user.id, by: user.System)
  assert auth.impersonate(identity, ada.user.id, by: user.System)
    == Error(service.NotFound("user"))
}

pub fn users_are_listed_with_their_suspension_test() {
  use _, identity, _, mailbox <- fixture
  let grace = signup(identity, mailbox, "grace@example.com")
  let ada = signup(identity, mailbox, "ada@example.com")
  let assert Ok(listed) = users.list(identity)
  assert list.map(listed, fn(u) { u.email })
    == ["ada@example.com", "grace@example.com"]
  assert users.suspended(identity, ada.user.id) == Ok(False)
  let assert Ok(Nil) = auth.suspend(identity, grace.user.id, by: user.System)
  assert users.suspended(identity, grace.user.id) == Ok(True)
  assert users.suspended(identity, "nobody") == Error(service.NotFound("user"))
}

pub fn operators_list_and_revoke_a_users_sessions_test() {
  use database, identity, _, mailbox <- fixture
  let ada = signup(identity, mailbox, "ada@example.com")
  let grace = signup(identity, mailbox, "grace@example.com")
  let assert Ok(other) =
    auth.impersonate(identity, ada.user.id, by: user.SystemFrom("admin"))
  let assert Ok(listed) = auth.sessions_of(identity, ada.user.id)
  assert list.length(listed) == 2
  assert list.all(listed, fn(s) { !s.current })
  // Both were created in the same second, so their order is by digest.
  assert list.sort(
      list.map(listed, fn(s) { string.inspect(s.method) }),
      string.compare,
    )
    == ["EmailToken", "Impersonation"]
  let assert [impersonated] =
    list.filter(listed, fn(s) { s.method == auth.Impersonation })

  // Grace's session cannot be revoked through Ada's id.
  let assert Ok(grace_principal) =
    auth.authenticate(identity, secret.reveal(grace.token))
  let assert Ok(Nil) =
    auth.revoke_session_of(
      identity,
      ada.user.id,
      grace_principal.session_id,
      by: user.SystemFrom("admin"),
    )
  let assert Ok(_) = auth.authenticate(identity, secret.reveal(grace.token))

  let assert Ok(Nil) =
    auth.revoke_session_of(
      identity,
      ada.user.id,
      impersonated.id,
      by: user.SystemFrom("admin"),
    )
  assert auth.authenticate(identity, secret.reveal(other.token))
    == Error(service.Unauthorized)
  let assert Ok(_) = auth.authenticate(identity, secret.reveal(ada.token))
  assert auth.revoke_session_of(identity, "nobody", "x", by: user.System)
    == Error(service.NotFound("user"))
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'session.revoked' AND client = 'admin'",
    )
    == 2
}

pub fn operators_delete_accounts_only_with_a_cleanup_callback_test() {
  use database, identity, _, mailbox <- fixture
  let ada = signup(identity, mailbox, "ada@example.com")
  assert auth.delete_user(identity, ada.user.id, by: user.System)
    == Error(service.Forbidden)

  let cleaned = process.new_subject()
  let identity =
    auth.with_account_deletion(identity, fn(_, deleted) {
      process.send(cleaned, deleted.email)
      Ok(Nil)
    })
  let assert Ok(Nil) = auth.suspend(identity, ada.user.id, by: user.System)
  let assert Ok(Nil) =
    auth.delete_user(identity, ada.user.id, by: user.SystemFrom("admin"))
  assert process.receive(cleaned, 100) == Ok("ada@example.com")
  assert auth.authenticate(identity, secret.reveal(ada.token))
    == Error(service.Unauthorized)
  assert users.get(identity, ada.user.id) == Error(service.NotFound("user"))
  assert auth.delete_user(identity, ada.user.id, by: user.System)
    == Error(service.NotFound("user"))
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'user.deleted' AND client = 'admin'",
    )
    == 1

  // A vetoing callback keeps the account.
  let grace = signup(identity, mailbox, "grace@example.com")
  let identity =
    auth.with_account_deletion(identity, fn(_, _) {
      Error(service.Conflict("has open invoices"))
    })
  assert auth.delete_user(identity, grace.user.id, by: user.System)
    == Error(service.Conflict("has open invoices"))
  let assert Ok(_) = users.get(identity, grace.user.id)
}
