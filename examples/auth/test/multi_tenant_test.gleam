import flows/multi_tenant
import gleam/dynamic/decode
import gleam/list
import gleam/string
import howdy/auth
import howdy/auth/secret
import howdy/auth/user
import howdy/testing
import support.{bearer, object}

fn workspaces(db, deliver) {
  let #(identity, permissions) = multi_tenant.configure(db, deliver)
  let assert Ok(_) =
    multi_tenant.create_workspace(
      identity,
      permissions,
      id: "acme",
      name: "Acme",
      owner: "owner@acme.test",
      by: user.System,
    )
  let assert Ok(_) =
    multi_tenant.create_workspace(
      identity,
      permissions,
      id: "globex",
      name: "Globex",
      owner: "owner@globex.test",
      by: user.System,
    )
  #(identity, multi_tenant.app(identity, permissions))
}

/// Invited users sign in with an emailed token like anyone else.
fn sign_in(identity, inbox, email: String) -> String {
  let assert Ok(Nil) = auth.request_token(identity, email, auth.Login)
  let assert Ok(session) =
    auth.exchange(identity, support.token(support.next_email(inbox)))
  secret.reveal(session.token)
}

fn member_emails(res) {
  let assert Ok(emails) =
    testing.json(res, decode.list(decode.at(["email"], decode.string)))
  list.sort(emails, string.compare)
}

pub fn only_invited_addresses_can_sign_in_test() {
  use db <- support.with_database
  let #(inbox, deliver) = support.mailbox()
  let #(identity, app) = workspaces(db, deliver)

  // Registration is off: the API accepts the request and changes nothing.
  let _ =
    testing.post("/api/auth/register", object([#("email", "eve@example.com")]))
    |> testing.send(app)
  assert support.no_email(inbox)

  let owner = sign_in(identity, inbox, "owner@acme.test")
  let me = testing.get("/workspace") |> bearer(owner) |> testing.send(app)
  assert me.status == 200
  assert testing.json(me, support.string_at(["workspace", "name"]))
    == Ok("Acme")
  assert testing.json(me, support.string_at(["plan"])) == Ok("free")
}

pub fn owners_invite_and_members_cannot_test() {
  use db <- support.with_database
  let #(inbox, deliver) = support.mailbox()
  let #(identity, app) = workspaces(db, deliver)
  let owner = sign_in(identity, inbox, "owner@acme.test")

  let invited =
    testing.post("/workspace/members", object([#("email", "bob@acme.test")]))
    |> bearer(owner)
    |> testing.send(app)
  assert invited.status == 201
  // Inviting sends nothing: the invitee's first sign-in proves the address.
  assert support.no_email(inbox)

  let bob = sign_in(identity, inbox, "bob@acme.test")
  let members =
    testing.get("/workspace/members") |> bearer(bob) |> testing.send(app)
  assert members.status == 200
  assert member_emails(members) == ["bob@acme.test", "owner@acme.test"]

  let refused =
    testing.post("/workspace/members", object([#("email", "eve@acme.test")]))
    |> bearer(bob)
    |> testing.send(app)
  assert refused.status == 403
}

pub fn workspaces_are_isolated_test() {
  use db <- support.with_database
  let #(inbox, deliver) = support.mailbox()
  let #(identity, app) = workspaces(db, deliver)
  let globex = sign_in(identity, inbox, "owner@globex.test")

  // An owner sees only their own workspace; the scope comes from their
  // account, not from anything in the request.
  let members =
    testing.get("/workspace/members") |> bearer(globex) |> testing.send(app)
  assert member_emails(members) == ["owner@globex.test"]

  // One account per address: someone already in acme cannot be invited here.
  let taken =
    testing.post("/workspace/members", object([#("email", "owner@acme.test")]))
    |> bearer(globex)
    |> testing.send(app)
  assert taken.status == 409
}

pub fn display_names_are_unique_within_a_workspace_test() {
  use db <- support.with_database
  let #(inbox, deliver) = support.mailbox()
  let #(identity, app) = workspaces(db, deliver)
  let acme = sign_in(identity, inbox, "owner@acme.test")
  let globex = sign_in(identity, inbox, "owner@globex.test")
  let set_name = fn(token, name) {
    testing.post("/workspace/profile", object([#("display_name", name)]))
    |> bearer(token)
    |> testing.send(app)
  }

  assert { set_name(acme, "Road Runner") }.status == 200
  // Unique per workspace, so another workspace may use the same name.
  assert { set_name(globex, "Road Runner") }.status == 200
  assert { set_name(acme, "x") }.status == 400

  let _ =
    testing.post("/workspace/members", object([#("email", "wile@acme.test")]))
    |> bearer(acme)
    |> testing.send(app)
  let wile = sign_in(identity, inbox, "wile@acme.test")
  assert { set_name(wile, "Road Runner") }.status == 409

  let me = testing.get("/workspace") |> bearer(acme) |> testing.send(app)
  assert testing.json(me, support.string_at(["display_name"]))
    == Ok("Road Runner")
}
