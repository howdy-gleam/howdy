//// Encryption keys for secrets sealed at rest. The first key seals; every key
//// opens. Sealed values carry no key identifier: AES-GCM authenticates, so
//// opening tries each key in turn and only the right one succeeds. Values
//// sealed before rotation existed therefore open unchanged, and a node that
//// has not learned of a new key still reads everything its own keys sealed.

import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import howdy/auth/secret

pub opaque type Keyring {
  Keyring(seal: secret.Secret, open: List(secret.Secret))
}

pub fn new(key: String) -> Result(Keyring, Nil) {
  use key <- result.map(valid(key))
  Keyring(key, [])
}

/// Replace the keys that only open: earlier keys while their values are
/// resealed, or a new key before any node seals with it.
pub fn with_decryption_keys(
  keyring: Keyring,
  keys: List(String),
) -> Result(Keyring, Nil) {
  use keys <- result.map(list.try_map(keys, valid))
  Keyring(..keyring, open: keys)
}

fn valid(key: String) -> Result(secret.Secret, Nil) {
  use bytes <- result.try(bit_array.base64_url_decode(key))
  case bit_array.byte_size(bytes) == 32 {
    True -> Ok(secret.wrap(key))
    False -> Error(Nil)
  }
}

pub fn seal(
  keyring: Keyring,
  owner: String,
  plain: String,
) -> Result(String, Nil) {
  encrypt(secret.reveal(keyring.seal), owner, plain)
}

pub fn open(
  keyring: Keyring,
  owner: String,
  sealed: String,
) -> Result(String, Nil) {
  [keyring.seal, ..keyring.open]
  |> list.find_map(fn(key) { decrypt(secret.reveal(key), owner, sealed) })
}

/// The value sealed afresh with the sealing key, or `None` when it already is.
pub fn reseal(
  keyring: Keyring,
  owner: String,
  sealed: String,
) -> Result(Option(String), Nil) {
  case decrypt(secret.reveal(keyring.seal), owner, sealed) {
    Ok(_) -> Ok(None)
    Error(_) -> {
      use plain <- result.try(
        list.find_map(keyring.open, fn(key) {
          decrypt(secret.reveal(key), owner, sealed)
        }),
      )
      seal(keyring, owner, plain) |> result.map(Some)
    }
  }
}

@external(erlang, "howdy_auth_mfa_ffi", "seal")
fn encrypt(key: String, owner: String, value: String) -> Result(String, Nil)

@external(erlang, "howdy_auth_mfa_ffi", "open")
fn decrypt(key: String, owner: String, value: String) -> Result(String, Nil)

/// Reseal every row a store pages through, in `(cursor, owner, sealed)` order
/// after the cursor, returning how many needed it. `replace` receives the
/// cursor, the old value and the new one; it should only replace the old
/// value, so a row changed meanwhile keeps its newer, already current value.
pub fn reseal_all(
  keyring: Keyring,
  conn: conn,
  page page: fn(conn, String) -> Result(List(#(String, String, String)), e),
  replace replace: fn(conn, String, String, String) -> Result(Nil, e),
  unreadable unreadable: fn(String) -> e,
) -> Result(Int, e) {
  reseal_from(keyring, conn, "", 0, page, replace, unreadable)
}

fn reseal_from(
  keyring: Keyring,
  conn: conn,
  after: String,
  count: Int,
  page: fn(conn, String) -> Result(List(#(String, String, String)), e),
  replace: fn(conn, String, String, String) -> Result(Nil, e),
  unreadable: fn(String) -> e,
) -> Result(Int, e) {
  use rows <- result.try(page(conn, after))
  case list.last(rows) {
    Error(_) -> Ok(count)
    Ok(#(last, _, _)) -> {
      use count <- result.try(
        list.try_fold(rows, count, fn(count, row) {
          let #(cursor, owner, sealed) = row
          case reseal(keyring, owner, sealed) {
            Ok(None) -> Ok(count)
            Ok(Some(fresh)) ->
              replace(conn, cursor, sealed, fresh)
              |> result.replace(count + 1)
            Error(_) -> Error(unreadable(cursor))
          }
        }),
      )
      reseal_from(keyring, conn, last, count, page, replace, unreadable)
    }
  }
}
