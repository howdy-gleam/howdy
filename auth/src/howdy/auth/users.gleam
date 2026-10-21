//// Looking users up and keeping fields about them. Every operation here is
//// privileged: authorize the caller first, as with `auth.suspend`. None is
//// exposed over HTTP. Through `auth.in_group` they see only that group's
//// users. Create users with `auth.provision`, or let them register.

import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import howdy/auth.{type Auth}
import howdy/auth/field.{type Change, type Field, type Fields}
import howdy/auth/internal/database as db
import howdy/auth/internal/store
import howdy/auth/user.{type Actor, type User}
import howdy/service

/// Every user, by email then id. Through `auth.in_group` only that group's.
pub fn list(identity: Auth) -> service.Result(List(User)) {
  use conn <- db.connect(auth.repo(identity))
  store.users(conn, auth.bound_group(identity))
}

/// Whether the user is suspended; see `auth.suspend`.
pub fn suspended(identity: Auth, id: String) -> service.Result(Bool) {
  use conn <- db.connect(auth.repo(identity))
  use _ <- result.try(require(conn, identity, id))
  use flags <- result.try(store.suspended(conn, id))
  case flags {
    [flag] -> Ok(flag)
    _ -> Error(service.NotFound("user"))
  }
}

pub fn get(identity: Auth, id: String) -> service.Result(User) {
  use conn <- db.connect(auth.repo(identity))
  require(conn, identity, id)
}

/// The fields the user holds; read them with `field.get`.
pub fn fields(identity: Auth, id: String) -> service.Result(Fields) {
  use conn <- db.connect(auth.repo(identity))
  use _ <- result.try(require(conn, identity, id))
  store.fields(conn, store.of_user, id) |> result.map(field.from_rows)
}

/// Set and clear fields on a user, all or nothing. Conflict when a unique
/// value is held by another user. The audit event names the fields changed
/// and never their values.
pub fn update(
  identity: Auth,
  id: String,
  changes: List(Change),
  by actor: Actor,
) -> service.Result(User) {
  use conn <- db.write_transaction(
    auth.repo(identity),
    touching: "howdy_auth_users",
  )
  use found <- result.try(require(conn, identity, id))
  use writes <- result.try(field.writes(changes, Some(found.group_id)))
  use _ <- result.try(store.write_fields(conn, store.of_user, id, writes))
  let names = list.map(writes, fn(write) { write.name }) |> string.join(",")
  use _ <- result.try(auth.event(conn, id, "user.fields_changed", actor, names))
  require(conn, identity, id)
}

/// The users holding `value` in a field, by email address: at most one when
/// the field is unique, and at most one per group when it is unique in a
/// group.
pub fn find(
  identity: Auth,
  where field: Field(a),
  is value: a,
) -> service.Result(List(User)) {
  use conn <- db.connect(auth.repo(identity))
  store.users_with_field(
    conn,
    field.name(field),
    field.encoded(field, value),
    auth.bound_group(identity),
  )
}

/// The user, row-locked inside a transaction.
fn require(conn, identity: Auth, id: String) -> service.Result(User) {
  use found <- result.try(store.find_user(conn, id))
  case found, auth.bound_group(identity) {
    [value], Some(group_id) if value.group_id != group_id ->
      Error(service.NotFound("user"))
    [value], _ -> Ok(value)
    _, _ -> Error(service.NotFound("user"))
  }
}
