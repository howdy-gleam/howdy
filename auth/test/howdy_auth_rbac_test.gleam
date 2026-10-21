//// Roles, permissions and their scopes.

import howdy/auth
import howdy/auth/secret
import howdy/auth/user
import howdy/authorization as access
import howdy/service
import support.{exec, fixture, signup}

pub fn rbac_is_scoped_revocable_and_has_no_implicit_admin_bypass_test() {
  use _, identity, permissions, mailbox <- fixture
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let a = access.Organization("a")
  let b = access.Organization("b")
  let assert Ok(Nil) =
    access.define_role(
      permissions,
      a,
      "editor",
      [
        "invoices.read",
        "invoices.write",
      ],
      by: user.System,
    )
  let assert Ok(Nil) =
    access.define_role(
      permissions,
      b,
      "editor",
      [
        "invoices.read",
        "invoices.write",
      ],
      by: user.System,
    )
  let assert Ok(Nil) =
    access.define_role(permissions, access.Global, "admin", [], by: user.System)
  let assert Ok(Nil) =
    access.assign(
      permissions,
      principal.user.id,
      "admin",
      access.Global,
      by: user.System,
    )
  assert access.allowed(permissions, principal, "invoices.write", a)
    == Ok(False)
  let assert Ok(Nil) =
    access.assign(permissions, principal.user.id, "editor", a, by: user.System)
  assert access.has_role(permissions, principal, "editor", a) == Ok(True)
  assert access.allowed(permissions, principal, "invoices.write", a) == Ok(True)
  assert access.allowed(permissions, principal, "invoices.write", b)
    == Ok(False)
  assert access.allowed(permissions, principal, "unknown", a) == Ok(False)
  let assert Ok(Nil) =
    access.define_role(
      permissions,
      a,
      "editor",
      ["invoices.read"],
      by: user.System,
    )
  assert access.allowed(permissions, principal, "invoices.write", a)
    == Ok(False)
  let assert Ok(Nil) =
    access.revoke(permissions, principal.user.id, "editor", a, by: user.System)
  assert access.allowed(permissions, principal, "invoices.read", a) == Ok(False)
}

pub fn multiple_roles_union_permissions_and_suspension_denies_test() {
  use _, identity, permissions, mailbox <- fixture
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let assert Ok(Nil) =
    access.define_role(
      permissions,
      access.Global,
      "reader",
      ["read"],
      by: user.System,
    )
  let assert Ok(Nil) =
    access.define_role(
      permissions,
      access.Global,
      "writer",
      ["write"],
      by: user.System,
    )
  let assert Ok(Nil) =
    access.assign(
      permissions,
      principal.user.id,
      "reader",
      access.Global,
      by: user.System,
    )
  let assert Ok(Nil) =
    access.assign(
      permissions,
      principal.user.id,
      "writer",
      access.Global,
      by: user.System,
    )
  assert access.allowed(permissions, principal, "read", access.Global)
    == Ok(True)
  assert access.allowed(permissions, principal, "write", access.Global)
    == Ok(True)
  let assert Ok(Nil) =
    auth.suspend(identity, principal.user.id, by: user.System)
  assert access.allowed(permissions, principal, "write", access.Global)
    == Ok(False)
}

pub fn database_failure_never_becomes_permission_grant_test() {
  use database, identity, permissions, mailbox <- fixture
  let session = signup(identity, mailbox, "ada@example.com")
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(session.token))
  let assert Ok(Nil) =
    access.define_role(
      permissions,
      access.Global,
      "reader",
      ["read"],
      by: user.System,
    )
  let assert Ok(Nil) =
    access.assign(
      permissions,
      principal.user.id,
      "reader",
      access.Global,
      by: user.System,
    )
  exec(database, "DROP TABLE howdy_authz_permissions")
  let assert Error(service.Internal(_)) =
    access.allowed(permissions, principal, "read", access.Global)
}

pub fn roles_assignments_and_holders_are_listable_and_roles_deletable_test() {
  use _, identity, permissions, mailbox <- fixture
  let ada = signup(identity, mailbox, "ada@example.com")
  let acme = access.Organization("acme")
  let assert Ok(Nil) =
    access.define_role(permissions, access.Global, "admin", [], by: user.System)
  let assert Ok(Nil) =
    access.define_role(
      permissions,
      acme,
      "editor",
      ["invoices.write", "invoices.read"],
      by: user.System,
    )
  let assert Ok(Nil) =
    access.assign(permissions, ada.user.id, "editor", acme, by: user.System)
  assert access.roles(permissions)
    == Ok([
      access.Role(access.Global, "admin", []),
      access.Role(acme, "editor", ["invoices.read", "invoices.write"]),
    ])
  assert access.assignments(permissions, ada.user.id) == Ok([#(acme, "editor")])
  assert access.holders(permissions, acme, "editor") == Ok([ada.user.id])
  assert access.holders(permissions, access.Global, "admin") == Ok([])
  assert access.scope_from_string(access.scope_to_string(acme)) == Ok(acme)
  assert access.scope_from_string("org:") == Error(Nil)

  let assert Ok(Nil) =
    access.delete_role(permissions, acme, "editor", by: user.System)
  assert access.assignments(permissions, ada.user.id) == Ok([])
  assert access.delete_role(permissions, acme, "editor", by: user.System)
    == Error(service.NotFound("role"))
  let assert Ok(principal) =
    auth.authenticate(identity, secret.reveal(ada.token))
  assert access.allowed(permissions, principal, "invoices.read", acme)
    == Ok(False)
}
