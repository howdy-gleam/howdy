//// Groups: the three modes, management, and converting between modes.

import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/string
import howdy/auth
import howdy/auth/group
import howdy/auth/groups
import howdy/auth/secret
import howdy/auth/user
import howdy/service
import howdy/testing
import support.{count, fixture, signup}

fn redeem(identity: auth.Auth, mailbox: process.Subject(auth.Delivery)) {
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  auth.exchange(identity, secret.reveal(delivery.token))
}

fn join(
  identity: auth.Auth,
  mailbox: process.Subject(auth.Delivery),
  group_id: String,
  email: String,
) {
  let scoped = auth.in_group(identity, group_id)
  let assert Ok(Nil) = auth.request_token(scoped, email, auth.Register)
  let assert Ok(session) = redeem(identity, mailbox)
  session
}

pub fn single_is_the_default_and_everyone_shares_one_group_test() {
  use _, identity, _, mailbox <- fixture
  assert auth.group_mode(identity) == group.Single
  let session = signup(identity, mailbox, "ada@example.com")
  assert session.user.group_id == group.default_id
  let assert Ok([group.Group(id: "default", name: "Default", ..)]) =
    groups.list(identity)
  let assert Ok([member]) = groups.members(identity, group.default_id)
  assert member == session.user
  // There is nowhere else to be.
  let assert Error(service.Invalid(_)) =
    groups.create(identity, name: "Acme", by: user.System)
  assert auth.request_token(
      auth.in_group(identity, "elsewhere"),
      "bob@example.com",
      auth.Register,
    )
    == Error(service.NotFound("group"))
  let assert Ok(group.Group(id: "default", name: "Everyone", ..)) =
    groups.rename(identity, "default", to: " Everyone ", by: user.System)
  let assert Error(service.Invalid(_)) =
    groups.delete(identity, "default", by: user.System)
}

pub fn one_group_per_user_has_one_account_per_address_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_groups(identity, group.OneGroupPerUser)
  let assert Ok(acme) = groups.create(identity, name: "Acme", by: user.System)
  let assert Ok(globex) =
    groups.create_with_id(
      identity,
      id: "globex",
      name: "Globex",
      by: user.System,
    )
  assert globex.id == "globex"
  // Registration has to say which group.
  let assert Error(service.Coded(_, service.Invalid(_))) =
    auth.request_token(identity, "ada@example.com", auth.Register)
  assert auth.request_token(
      auth.in_group(identity, "missing"),
      "ada@example.com",
      auth.Register,
    )
    == Error(service.NotFound("group"))
  let ada = join(identity, mailbox, acme.id, "ada@example.com")
  assert ada.user.group_id == acme.id
  // The address is taken everywhere: the second group gets no account.
  let scoped = auth.in_group(identity, globex.id)
  let assert Ok(Nil) =
    auth.request_token(scoped, "ada@example.com", auth.Register)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert delivery.purpose == auth.AlreadyRegistered
  // As the email says, the token signs in the account that exists.
  let assert Ok(existing) =
    auth.exchange(identity, secret.reveal(delivery.token))
  assert existing.user == ada.user
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 1
  // Signing in needs no group, and a group's guard admits only its users.
  let assert Ok(Nil) =
    auth.request_token(identity, "ada@example.com", auth.Login)
  let assert Ok(session) = redeem(identity, mailbox)
  let token = secret.reveal(session.token)
  let assert Ok(principal) = auth.authenticate(identity, token)
  assert principal.user.group_id == acme.id
  let assert Ok(_) = auth.authenticate(auth.in_group(identity, acme.id), token)
  assert auth.authenticate(scoped, token) == Error(service.Unauthorized)
}

pub fn account_per_group_keeps_accounts_apart_test() {
  use _, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_groups(identity, group.AccountPerGroup)
  let assert Ok(identity) = auth.with_passwords(identity)
  let by = user.System
  let assert Ok(_) = groups.create_with_id(identity, id: "acme", name: "A", by:)
  let assert Ok(_) =
    groups.create_with_id(identity, id: "globex", name: "G", by:)
  let acme = auth.in_group(identity, "acme")
  let globex = auth.in_group(identity, "globex")
  // An address alone names no account.
  let assert Error(service.Coded(_, service.Invalid(_))) =
    auth.request_token(identity, "ada@example.com", auth.Login)
  let assert Error(service.Coded(_, service.Invalid(_))) =
    auth.login_password(identity, "ada@example.com", "whatever it may be")
  let in_acme = join(identity, mailbox, "acme", "ada@example.com")
  let password = "an uncommon orchard phrase 947!"
  let assert Ok(Nil) =
    auth.register_password(globex, "ada@example.com", password)
  let assert Ok(in_globex) = redeem(identity, mailbox)
  assert in_acme.user.id != in_globex.user.id
  assert in_acme.user.email == in_globex.user.email
  assert in_globex.user.group_id == "globex"
  // Within one group the address is still unique.
  let assert Ok(Nil) =
    auth.request_token(acme, "ada@example.com", auth.Register)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert delivery.purpose == auth.AlreadyRegistered
  let assert Ok(again) = auth.exchange(acme, secret.reveal(delivery.token))
  assert again.user == in_acme.user
  // Credentials belong to the account, not the address.
  let assert Ok(session) =
    auth.login_password(globex, "ada@example.com", password)
  assert session.user == in_globex.user
  assert auth.login_password(acme, "ada@example.com", password)
    == Error(service.Unauthorized)
  // A token redeems only in the group it was requested for.
  let assert Ok(Nil) = auth.request_token(globex, "ada@example.com", auth.Login)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert auth.exchange(acme, secret.reveal(delivery.token))
    == Error(service.Unauthorized)
  // Suspending one account leaves the other alone.
  let assert Ok(Nil) = auth.suspend(identity, in_acme.user.id, by:)
  let assert Ok(_) = auth.authenticate(identity, secret.reveal(in_globex.token))
}

pub fn moving_users_and_deleting_groups_test() {
  use _, identity, _, mailbox <- fixture
  let assert Ok(identity) = auth.with_groups(identity, group.AccountPerGroup)
  let by = user.System
  let assert Ok(_) = groups.create_with_id(identity, id: "acme", name: "A", by:)
  let assert Ok(_) =
    groups.create_with_id(identity, id: "globex", name: "G", by:)
  let assert Error(service.Conflict(_)) =
    groups.create_with_id(identity, id: "acme", name: "Again", by:)
  let assert Error(service.Invalid(_)) =
    groups.create_with_id(identity, id: "no:colons", name: "Bad", by:)
  let assert Error(service.Invalid(_)) = groups.create(identity, name: " ", by:)
  let ada = join(identity, mailbox, "acme", "ada@example.com")
  let twin = join(identity, mailbox, "globex", "ada@example.com")
  let bob = join(identity, mailbox, "acme", "bob@example.com")
  let assert Error(service.Conflict(_)) =
    groups.move(identity, ada.user.id, to: "globex", by:)
  assert groups.move(identity, "nobody", to: "globex", by:)
    == Error(service.NotFound("user"))
  assert groups.move(identity, bob.user.id, to: "missing", by:)
    == Error(service.NotFound("group"))
  let assert Ok(moved) = groups.move(identity, bob.user.id, to: "globex", by:)
  assert moved.group_id == "globex"
  // The session went with them, and they now sign in there.
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(bob.token))
  assert principal.user == moved
  let globex = auth.in_group(identity, "globex")
  let assert Ok(Nil) = auth.request_token(globex, "bob@example.com", auth.Login)
  let assert Ok(session) = redeem(identity, mailbox)
  assert session.user == moved
  let assert Ok(members) = groups.members(identity, "globex")
  assert list.map(members, fn(member) { member.id })
    == [twin.user.id, bob.user.id]
  let assert Error(service.Conflict(_)) = groups.delete(identity, "acme", by:)
  let assert Ok(_) =
    groups.create_with_id(identity, id: "empty", name: "E", by:)
  assert groups.delete(identity, "empty", by:) == Ok(Nil)
  assert groups.get(identity, "empty") == Error(service.NotFound("group"))
}

pub fn the_mode_is_recorded_and_converts_only_when_users_fit_test() {
  use database, identity, _, mailbox <- fixture
  let deliver = fn(delivery) {
    process.send(mailbox, delivery)
    Ok(Nil)
  }
  let assert Ok(per_group) = auth.with_groups(identity, group.AccountPerGroup)
  let by = user.System
  let assert Ok(_) =
    groups.create_with_id(per_group, id: "acme", name: "A", by:)
  let ada = join(per_group, mailbox, "acme", "ada@example.com")
  // A node that does not mention groups adopts what was recorded.
  let assert Ok(restarted) = auth.new(database, "https://example.test", deliver)
  assert auth.group_mode(restarted) == group.AccountPerGroup
  // Single needs everyone in the default group.
  let assert Error(service.Conflict(_)) =
    auth.with_groups(restarted, group.Single)
  let twin = join(per_group, mailbox, "default", "ada@example.com")
  // One account per address is impossible while an address has two.
  let assert Error(service.Conflict(_)) =
    auth.with_groups(restarted, group.OneGroupPerUser)
  assert auth.group_mode(restarted) == group.AccountPerGroup
  let assert Ok(Nil) = auth.suspend(per_group, twin.user.id, by:)
  support.exec(
    database,
    "DELETE FROM howdy_auth_users WHERE id = '" <> twin.user.id <> "'",
  )
  let assert Ok(exclusive) =
    auth.with_groups(auth.allow_registration(restarted), group.OneGroupPerUser)
  // Sessions survive, and the address is now unique everywhere.
  let assert Ok(_) = auth.authenticate(exclusive, secret.reveal(ada.token))
  let assert Ok(Nil) =
    auth.request_token(
      auth.in_group(exclusive, "default"),
      "ada@example.com",
      auth.Register,
    )
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert delivery.purpose == auth.AlreadyRegistered
  let assert Ok(session) =
    auth.exchange(exclusive, secret.reveal(delivery.token))
  assert session.user == ada.user
  // And back again.
  let assert Ok(per_group) = auth.with_groups(exclusive, group.AccountPerGroup)
  let twin = join(per_group, mailbox, "default", "ada@example.com")
  assert twin.user.id != ada.user.id
}

pub fn the_json_api_takes_the_group_from_the_request_test() {
  use _, identity, permissions, mailbox <- fixture
  let assert Ok(identity) = auth.with_groups(identity, group.AccountPerGroup)
  let assert Ok(_) =
    groups.create_with_id(identity, id: "acme", name: "A", by: user.System)
  let app = support.app(identity, permissions)
  let register = fn(fields) {
    testing.post("/api/auth/register", json.object(fields))
    |> testing.send(app)
  }
  let email = #("email", json.string("ada@example.com"))
  assert register([email]).status == 400
  assert register([email, #("group", json.string("missing"))]).status == 404
  assert register([email, #("group", json.string("acme"))]).status == 202
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let session =
    testing.post(
      "/api/auth/token",
      json.object([#("token", json.string(secret.reveal(delivery.token)))]),
    )
    |> testing.send(app)
  assert session.status == 200
  assert string.contains(testing.text(session), "\"group_id\":\"acme\"")
}
