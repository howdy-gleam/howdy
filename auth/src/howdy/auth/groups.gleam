//// Group management. Every operation here is privileged: authorize the
//// caller first, as with `auth.suspend`. None is exposed over HTTP. Choose
//// how users relate to groups with `auth.with_groups`.

import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import howdy/auth.{type Auth}
import howdy/auth/field.{type Change, type Field, type Fields}
import howdy/auth/group.{type Group, AccountPerGroup, Single}
import howdy/auth/internal/cache
import howdy/auth/internal/database as db
import howdy/auth/internal/store
import howdy/auth/internal/token
import howdy/auth/user.{type Actor, type User}
import howdy/service

/// Create a group with a generated id.
pub fn create(
  identity: Auth,
  name name: String,
  by actor: Actor,
) -> service.Result(Group) {
  create_with(identity, id: token.new(), name:, fields: [], by: actor)
}

/// Create a group under an id of your choosing, such as a tenant's slug: 1 to
/// 64 of letters, digits, hyphen and underscore. Conflict if it is taken.
pub fn create_with_id(
  identity: Auth,
  id id: String,
  name name: String,
  by actor: Actor,
) -> service.Result(Group) {
  create_with(identity, id:, name:, fields: [], by: actor)
}

/// As `create_with_id`, setting fields on the new group in the same
/// transaction; see `howdy/auth/field`. Pass `token.new`-style ids of your
/// own, or use `create` and `update` when the id should be generated.
pub fn create_with(
  identity: Auth,
  id id: String,
  name name: String,
  fields changes: List(Change),
  by actor: Actor,
) -> service.Result(Group) {
  use _ <- result.try(case auth.group_mode(identity) {
    Single ->
      Error(service.Invalid(
        "every user shares the default group; choose another mode with auth.with_groups",
      ))
    _ -> Ok(Nil)
  })
  use _ <- result.try(valid_id(id))
  use name <- result.try(valid_name(name))
  use writes <- result.try(field.writes(changes, None))
  use conn <- db.write_transaction(
    auth.repo(identity),
    touching: "howdy_auth_groups",
  )
  use taken <- result.try(store.find_group(conn, id))
  use _ <- result.try(case taken {
    [] -> Ok(Nil)
    _ -> Error(service.Conflict("a group with this id already exists"))
  })
  use created <- result.try(store.insert_group(conn, id, name))
  use _ <- result.try(case writes {
    [] -> Ok(Nil)
    _ ->
      store.write_fields(conn, store.of_group, id, writes)
      |> result.replace(Nil)
  })
  use _ <- result.try(auth.event(conn, "", "group.created", actor, id))
  Ok(created)
}

pub fn get(identity: Auth, id: String) -> service.Result(Group) {
  use conn <- db.connect(auth.repo(identity))
  use found <- result.try(store.find_group(conn, id))
  case found {
    [value] -> Ok(value)
    _ -> Error(service.NotFound("group"))
  }
}

/// Every group, by name.
pub fn list(identity: Auth) -> service.Result(List(Group)) {
  db.connect(auth.repo(identity), store.groups)
}

pub fn rename(
  identity: Auth,
  id: String,
  to name: String,
  by actor: Actor,
) -> service.Result(Group) {
  use name <- result.try(valid_name(name))
  use conn <- db.write_transaction(
    auth.repo(identity),
    touching: "howdy_auth_groups",
  )
  use _ <- result.try(require(conn, id))
  use _ <- result.try(store.rename_group(conn, id, name))
  use _ <- result.try(auth.event(conn, "", "group.renamed", actor, id))
  require(conn, id)
}

/// The fields the group holds; read them with `field.get`.
pub fn fields(identity: Auth, id: String) -> service.Result(Fields) {
  use conn <- db.connect(auth.repo(identity))
  use _ <- result.try(require(conn, id))
  store.fields(conn, store.of_group, id) |> result.map(field.from_rows)
}

/// Set and clear fields on a group, all or nothing. Conflict when a unique
/// value is held by another group.
pub fn update(
  identity: Auth,
  id: String,
  changes: List(Change),
  by actor: Actor,
) -> service.Result(Group) {
  use writes <- result.try(field.writes(changes, None))
  use conn <- db.write_transaction(
    auth.repo(identity),
    touching: "howdy_auth_groups",
  )
  use _ <- result.try(require(conn, id))
  use _ <- result.try(store.write_fields(conn, store.of_group, id, writes))
  use _ <- result.try(auth.event(conn, "", "group.fields_changed", actor, id))
  require(conn, id)
}

/// The groups holding `value` in a field, by name: at most one when the
/// field is unique.
pub fn find(
  identity: Auth,
  where field: Field(a),
  is value: a,
) -> service.Result(List(Group)) {
  use conn <- db.connect(auth.repo(identity))
  store.groups_with_field(conn, field.name(field), field.encoded(field, value))
}

/// Delete an empty group. Conflict while it has users: move them first. The
/// default group cannot be deleted.
pub fn delete(
  identity: Auth,
  id: String,
  by actor: Actor,
) -> service.Result(Nil) {
  use _ <- result.try(case id == group.default_id {
    True -> Error(service.Invalid("the default group cannot be deleted"))
    False -> Ok(Nil)
  })
  use conn <- db.write_transaction(
    auth.repo(identity),
    touching: "howdy_auth_groups",
  )
  use _ <- result.try(require(conn, id))
  use users <- result.try(store.group_members(conn, id))
  use _ <- result.try(case users {
    [] -> Ok(Nil)
    _ -> Error(service.Conflict("the group still has users"))
  })
  use _ <- result.try(store.delete_group(conn, id))
  auth.event(conn, "", "group.deleted", actor, id)
}

/// The group's users, by email address.
pub fn members(identity: Auth, id: String) -> service.Result(List(User)) {
  use conn <- db.connect(auth.repo(identity))
  use _ <- result.try(require(conn, id))
  store.group_members(conn, id)
}

/// Put a user in another group; they leave the one they were in. Their
/// sessions and credentials go with them. Invalid under `Single`, and
/// Conflict under `AccountPerGroup` when the destination already has an
/// account for their address. Role assignments are untouched: revoke any
/// scoped to the old group yourself.
pub fn move(
  identity: Auth,
  user_id: String,
  to id: String,
  by actor: Actor,
) -> service.Result(User) {
  let mode = auth.group_mode(identity)
  use _ <- result.try(case mode {
    Single -> Error(service.Invalid("every user shares the default group"))
    _ -> Ok(Nil)
  })
  // Runs in the process holding the transaction: the dirty flag is
  // process-local (see `cache.changing`).
  use <- cache.changing
  use conn <- db.write_transaction(
    auth.repo(identity),
    touching: "howdy_auth_users",
  )
  use _ <- result.try(require(conn, id))
  use found <- result.try(store.find_user(conn, user_id))
  use member <- result.try(case found {
    [value] -> Ok(value)
    _ -> Error(service.NotFound("user"))
  })
  case member.group_id == id {
    True -> Ok(member)
    False -> {
      let login_key = group.login_key(mode, id, member.email)
      // Only per-group keys change with the group, so only they can collide.
      use taken <- result.try(case mode {
        AccountPerGroup -> store.login_key_taken(conn, login_key)
        _ -> Ok(False)
      })
      use _ <- result.try(case taken {
        False -> Ok(Nil)
        True ->
          Error(service.Conflict(
            "the group already has an account for this address",
          ))
      })
      use held <- result.try(store.fields_taken_in_group(conn, user_id, id))
      use _ <- result.try(case held {
        False -> Ok(Nil)
        True ->
          Error(service.Conflict(
            "the group already has a user holding one of this user's unique fields",
          ))
      })
      use _ <- result.try(store.move_user(conn, user_id, id, login_key))
      use _ <- result.try(auth.event(conn, user_id, "user.moved", actor, id))
      use moved <- result.try(store.find_user(conn, user_id))
      case moved {
        [value] -> Ok(value)
        _ -> Error(service.NotFound("user"))
      }
    }
  }
}

fn require(conn, id: String) -> service.Result(Group) {
  use found <- result.try(store.find_group(conn, id))
  case found {
    [value] -> Ok(value)
    _ -> Error(service.NotFound("group"))
  }
}

/// Ids appear in login keys and URLs, so keep them plain.
fn valid_id(id: String) -> service.Result(Nil) {
  let allowed =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
  case
    id != ""
    && string.byte_size(id) <= 64
    && list.all(string.to_graphemes(id), string.contains(allowed, _))
  {
    True -> Ok(Nil)
    False ->
      Error(service.Invalid(
        "group ids are 1 to 64 letters, digits, hyphens and underscores",
      ))
  }
}

fn valid_name(name: String) -> service.Result(String) {
  let name = string.trim(name)
  case name != "" && string.byte_size(name) <= 200 {
    True -> Ok(name)
    False ->
      Error(service.Invalid(
        "group names must be nonempty and at most 200 bytes",
      ))
  }
}
