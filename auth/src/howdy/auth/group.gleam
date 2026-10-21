//// Groups partition users: a workspace, a tenant, an organization. Every
//// user belongs to exactly one. Manage them with `howdy/auth/groups`.

import gleam/dynamic/decode
import gleam/json
import gleam/time/timestamp.{type Timestamp}
import howdy/auth/user

/// The least a group is. Small facts about it, such as a billing id, fit
/// `howdy/auth/field`; anything relational belongs in application tables
/// keyed by its id. `updated_at` moves when the group is renamed or has a
/// field changed, not when its membership does. Both are whole seconds, and
/// `created_at` is the epoch for a group that predates it.
pub type Group {
  Group(id: String, name: String, created_at: Timestamp, updated_at: Timestamp)
}

/// How users relate to groups. Choose one with `auth.with_groups`.
pub type Mode {
  /// Every user is in the one group, `default_id`. This is what an
  /// installation that never mentions groups gets.
  Single
  /// There are many groups and each user is in exactly one of them. An email
  /// address has one account across the whole installation.
  OneGroupPerUser
  /// There are many groups and an email address may have a separate account
  /// in each: separate user ids, credentials and sessions. Within one group
  /// an address still has at most one account.
  AccountPerGroup
}

/// The group every user is in under `Single`. It always exists.
pub const default_id = "default"

pub fn to_json(group: Group) -> json.Json {
  json.object([
    #("id", json.string(group.id)),
    #("name", json.string(group.name)),
    #("created_at", user.time_to_json(group.created_at)),
    #("updated_at", user.time_to_json(group.updated_at)),
  ])
}

@internal
pub fn row() -> decode.Decoder(Group) {
  use id <- decode.field(0, decode.string)
  use name <- decode.field(1, decode.string)
  use created_at <- decode.field(2, decode.int)
  use updated_at <- decode.field(3, decode.int)
  decode.success(Group(
    id,
    name,
    timestamp.from_unix_seconds(created_at),
    timestamp.from_unix_seconds(updated_at),
  ))
}

@internal
pub fn mode_name(mode: Mode) -> String {
  case mode {
    Single -> "single"
    OneGroupPerUser -> "one-group-per-user"
    AccountPerGroup -> "account-per-group"
  }
}

@internal
pub fn mode_from(name: String) -> Result(Mode, Nil) {
  case name {
    "single" -> Ok(Single)
    "one-group-per-user" -> Ok(OneGroupPerUser)
    "account-per-group" -> Ok(AccountPerGroup)
    _ -> Error(Nil)
  }
}

/// What the unique `login_key` column holds for an account. Under
/// `AccountPerGroup` it is qualified by the group, so the database enforces
/// one account per address per group; otherwise it is the address, so the
/// database enforces one account per address. Group ids cannot contain ':'.
@internal
pub fn login_key(mode: Mode, group_id: String, email: String) -> String {
  case mode {
    AccountPerGroup -> group_id <> ":" <> email
    Single | OneGroupPerUser -> email
  }
}
