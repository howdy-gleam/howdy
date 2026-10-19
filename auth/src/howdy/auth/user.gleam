//// Small facts about a user, such as a username, fit `howdy/auth/field`.
//// Anything relational belongs in application tables keyed by user ID.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option}
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}

/// `group_id` is the one group the user belongs to; see `howdy/auth/group`.
/// `updated_at` moves when the user is suspended or resumed, changes group,
/// or has a field changed; credentials and sessions do not move it. Both are
/// whole seconds. `created_at` is the epoch for a user who predates it and
/// whose registration has been pruned from the audit trail. `locale` is
/// the BCP 47 tag pages and emails use for the user, such as `de`: the
/// locale they registered in, or one they chose; `None` for a user who
/// predates it or was provisioned without one.
pub type User {
  User(
    id: String,
    email: String,
    group_id: String,
    created_at: Timestamp,
    updated_at: Timestamp,
    locale: Option(String),
  )
}

/// A verified session. Roles are intentionally absent: authorization reads
/// current grants rather than retaining stale permissions in a session.
/// `client` is where this request came from, as the caller identified it; it
/// is recorded with the audit events the principal causes. It is empty when
/// the transport did not supply one.
pub type Principal {
  Principal(user: User, session_id: String, client: String)
}

/// Who performed a privileged operation, recorded with its audit event.
/// `System` is trusted code acting for nobody: provisioning, scheduled jobs.
/// `SystemFrom` is the same, with a client to record for an operator request
/// that arrived over some transport of the application's own.
pub type Actor {
  System
  Acting(Principal)
  SystemFrom(client: String)
}

/// The user id to record for an actor, empty for system operations.
@internal
pub fn actor_id(actor: Actor) -> String {
  case actor {
    System | SystemFrom(_) -> ""
    Acting(principal) -> principal.user.id
  }
}

/// Where an actor's request came from, empty when unknown.
@internal
pub fn actor_client(actor: Actor) -> String {
  case actor {
    System -> ""
    SystemFrom(client) -> client
    Acting(principal) -> principal.client
  }
}

pub fn to_json(user: User) -> json.Json {
  json.object([
    #("id", json.string(user.id)),
    #("email", json.string(user.email)),
    #("group_id", json.string(user.group_id)),
    #("created_at", time_to_json(user.created_at)),
    #("updated_at", time_to_json(user.updated_at)),
    #("locale", json.nullable(user.locale, json.string)),
  ])
}

/// An instant as JSON: an RFC 3339 string in UTC.
@internal
pub fn time_to_json(time: Timestamp) -> json.Json {
  json.string(timestamp.to_rfc3339(time, calendar.utc_offset))
}

@internal
pub fn row() -> decode.Decoder(User) {
  use id <- decode.field(0, decode.string)
  use email <- decode.field(1, decode.string)
  use group_id <- decode.field(2, decode.string)
  use created_at <- decode.field(3, decode.int)
  use updated_at <- decode.field(4, decode.int)
  use locale <- decode.field(5, decode.optional(decode.string))
  decode.success(User(
    id,
    email,
    group_id,
    timestamp.from_unix_seconds(created_at),
    timestamp.from_unix_seconds(updated_at),
    locale,
  ))
}
