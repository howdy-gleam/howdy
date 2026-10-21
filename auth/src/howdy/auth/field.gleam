//// Small facts an application keeps about a user or a group: a username, a
//// plan, a billing id. Declare a field once and use it to write and to read:
////
//// ```gleam
//// pub fn username() { field.text("username") |> field.unique }
////
//// users.update(identity, id, [field.set(username(), "mike")], by: actor)
//// use data <- result.try(users.fields(identity, id))
//// field.get(data, username())
//// ```
////
//// Write them with `howdy/auth/users` and `howdy/auth/groups`. A value is at
//// most 1024 bytes once encoded. Anything relational, or that you query by
//// range, belongs in application tables keyed by the id.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}
import howdy/service

const value_bytes = 1024

pub opaque type Field(value) {
  Field(
    name: String,
    encode: fn(value) -> String,
    decode: fn(String) -> Result(value, Nil),
    scope: Scope,
    check: fn(value) -> Result(Nil, String),
  )
}

type Scope {
  Shared
  Unique
  UniqueInGroup
}

/// A field under `name`: 1 to 64 lowercase letters, digits and underscores.
/// User fields and group fields are named separately.
pub fn text(name: String) -> Field(String) {
  custom(name, encode: fn(value) { value }, decode: Ok)
}

pub fn int(name: String) -> Field(Int) {
  custom(name, encode: int.to_string, decode: int.parse)
}

pub fn bool(name: String) -> Field(Bool) {
  custom(
    name,
    encode: fn(value) {
      case value {
        True -> "true"
        False -> "false"
      }
    },
    decode: fn(text) {
      case text {
        "true" -> Ok(True)
        "false" -> Ok(False)
        _ -> Error(Nil)
      }
    },
  )
}

/// An instant, kept as RFC 3339 text in UTC.
pub fn time(name: String) -> Field(Timestamp) {
  custom(
    name,
    encode: timestamp.to_rfc3339(_, calendar.utc_offset),
    decode: timestamp.parse_rfc3339,
  )
}

/// A field of your own type. Uniqueness and `find` compare the encoded text,
/// so equal values must encode the same.
pub fn custom(
  name: String,
  encode encode: fn(a) -> String,
  decode decode: fn(String) -> Result(a, Nil),
) -> Field(a) {
  Field(name:, encode:, decode:, scope: Shared, check: fn(_) { Ok(Nil) })
}

/// At most one holder of each value across the installation, enforced by the
/// database. Declare it before the field is first written: values stored
/// while it was not unique are not checked against.
pub fn unique(field: Field(a)) -> Field(a) {
  Field(..field, scope: Unique)
}

/// At most one holder of each value within a group. User fields only.
pub fn unique_in_group(field: Field(a)) -> Field(a) {
  Field(..field, scope: UniqueInGroup)
}

/// Refuse values `with` rejects; its message reaches the caller as Invalid.
pub fn check(
  field: Field(a),
  with check: fn(a) -> Result(Nil, String),
) -> Field(a) {
  Field(..field, check:)
}

pub fn name(field: Field(a)) -> String {
  field.name
}

/// A write, for `users.update`, `groups.update` and the `_with` constructors.
pub opaque type Change {
  Set(name: String, value: Result(String, String), scope: Scope)
  Clear(name: String)
}

pub fn set(field: Field(a), value: a) -> Change {
  Set(
    field.name,
    field.check(value) |> result.map(fn(_) { field.encode(value) }),
    field.scope,
  )
}

pub fn clear(field: Field(a)) -> Change {
  Clear(field.name)
}

/// The fields one user or group holds.
pub opaque type Fields {
  Fields(values: Dict(String, String))
}

/// The value held, or an error when the field is unset or what is stored no
/// longer decodes.
pub fn get(from: Fields, field: Field(a)) -> Result(a, Nil) {
  dict.get(from.values, field.name) |> result.try(field.decode)
}

/// Every field held as encoded text, by name: for an export or a debug page.
pub fn to_list(fields: Fields) -> List(#(String, String)) {
  dict.to_list(fields.values)
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

@internal
pub fn from_rows(rows: List(#(String, String))) -> Fields {
  Fields(dict.from_list(rows))
}

/// A validated change, with the key the unique index sees.
@internal
pub type Write {
  Put(name: String, value: String, key: Option(String))
  Remove(name: String)
}

/// Validate changes for an owner. `within` is the user's group, or `None`
/// for a group's own fields.
@internal
pub fn writes(
  changes: List(Change),
  within: Option(String),
) -> service.Result(List(Write)) {
  list.try_map(changes, fn(change) {
    use _ <- result.try(valid_name(change.name))
    case change {
      Clear(name) -> Ok(Remove(name))
      Set(name, Error(problem), _) ->
        Error(service.Invalid(name <> ": " <> problem))
      Set(name, Ok(value), scope) -> {
        use _ <- result.try(case string.byte_size(value) <= value_bytes {
          True -> Ok(Nil)
          False ->
            Error(service.Invalid(
              name
              <> " is longer than "
              <> int.to_string(value_bytes)
              <> " bytes",
            ))
        })
        case scope, within {
          Shared, _ -> Ok(Put(name, value, None))
          Unique, _ -> Ok(Put(name, value, Some("v:" <> value)))
          UniqueInGroup, Some(group_id) ->
            Ok(Put(name, value, Some(group_key(group_id, value))))
          UniqueInGroup, None ->
            Error(service.Invalid(
              name <> ": unique_in_group applies to user fields",
            ))
        }
      }
    }
  })
}

/// The unique key of a value held once per group. Group ids cannot contain
/// ':', so the value starts after the second one.
@internal
pub fn group_key(group_id: String, value: String) -> String {
  "g:" <> group_id <> ":" <> value
}

/// The value to search stored text for.
@internal
pub fn encoded(field: Field(a), value: a) -> String {
  field.encode(value)
}

fn valid_name(name: String) -> service.Result(Nil) {
  let allowed = "abcdefghijklmnopqrstuvwxyz0123456789_"
  case
    name != ""
    && string.byte_size(name) <= 64
    && list.all(string.to_graphemes(name), string.contains(allowed, _))
  {
    True -> Ok(Nil)
    False ->
      Error(service.Invalid(
        "field names are 1 to 64 lowercase letters, digits and underscores",
      ))
  }
}
