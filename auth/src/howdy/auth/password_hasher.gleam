//// How password credentials are stored. `auth.with_passwords` uses
//// `pbkdf2_sha256`, which runs on OTP's `crypto` module and needs no native
//// code of its own. A different algorithm, such as Argon2id from a native
//// library, plugs in with `auth.with_password_hasher`.

import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/result
import gleam/string

/// The operations Howdy needs from a password hashing algorithm.
///
/// - `hash(password)` returns a self-describing encoded hash with a fresh
///   random salt.
/// - `verify(encoded, password)` reports whether the password matches,
///   comparing in constant time.
/// - `needs_rehash(encoded)` is `True` when a stored hash is weaker than this
///   hasher would produce now; Howdy then rehashes it after a successful login.
/// - `rehash(encoded, password)` hashes again without lowering any cost the
///   old hash already exceeds.
///
/// Howdy passes NFC-normalized passwords, except when checking a credential
/// stored before normalization was introduced. An `Error` means the hash could
/// not be produced or read: Howdy fails closed with an internal error and never
/// treats it as a wrong password. Hashing is expensive, so run it where it
/// cannot block a scheduler (a dirty NIF, or OTP's `crypto`).
pub type PasswordHasher {
  PasswordHasher(
    hash: fn(String) -> Result(String, Nil),
    verify: fn(String, String) -> Result(Bool, Nil),
    needs_rehash: fn(String) -> Bool,
    rehash: fn(String, String) -> Result(String, Nil),
  )
}

const iterations = 600_000

const hash_bytes = 32

const salt_bytes = 16

/// PBKDF2-HMAC-SHA256 with 600,000 iterations, a fresh 16 byte salt and a
/// 32 byte hash, OWASP's recommendation for this algorithm. Hashes are stored
/// in PHC string format:
///
/// ```text
/// $pbkdf2-sha256$i=600000,l=32$<salt>$<hash>
/// ```
///
/// with unpadded standard base64. It is not memory-hard: a leaked database
/// costs an attacker less to guess on GPUs than an Argon2id one would, which
/// the password length minimum and common-password check offset.
pub fn pbkdf2_sha256() -> PasswordHasher {
  PasswordHasher(
    hash: fn(password) {
      Ok(encode(
        password,
        crypto.strong_random_bytes(salt_bytes),
        iterations,
        hash_bytes,
      ))
    },
    verify: verify,
    needs_rehash: fn(encoded) {
      case parse(encoded) {
        Ok(stored) ->
          stored.iterations < iterations
          || bit_array.byte_size(stored.hash) < hash_bytes
        Error(_) -> True
      }
    },
    rehash: fn(encoded, password) {
      use stored <- result.map(parse(encoded))
      encode(
        password,
        crypto.strong_random_bytes(salt_bytes),
        int.max(stored.iterations, iterations),
        int.max(bit_array.byte_size(stored.hash), hash_bytes),
      )
    },
  )
}

fn verify(encoded: String, password: String) -> Result(Bool, Nil) {
  use stored <- result.map(parse(encoded))
  let length = bit_array.byte_size(stored.hash)
  crypto.secure_compare(
    pbkdf2(password, stored.salt, stored.iterations, length),
    stored.hash,
  )
}

/// Encode with a chosen salt and costs. For known-answer tests only.
@internal
pub fn encode(
  password: String,
  salt: BitArray,
  iterations: Int,
  length: Int,
) -> String {
  "$pbkdf2-sha256$i="
  <> int.to_string(iterations)
  <> ",l="
  <> int.to_string(length)
  <> "$"
  <> bit_array.base64_encode(salt, False)
  <> "$"
  <> bit_array.base64_encode(pbkdf2(password, salt, iterations, length), False)
}

type Stored {
  Stored(iterations: Int, salt: BitArray, hash: BitArray)
}

/// Bounds reject a corrupted row rather than spending unbounded time on it.
fn parse(encoded: String) -> Result(Stored, Nil) {
  case string.split(encoded, "$") {
    ["", "pbkdf2-sha256", "i=" <> costs, salt, hash] -> {
      use #(count, length) <- result.try(string.split_once(costs, ",l="))
      use count <- result.try(int.parse(count))
      use length <- result.try(int.parse(length))
      use salt <- result.try(bit_array.base64_decode(salt))
      use hash <- result.try(bit_array.base64_decode(hash))
      case
        count >= 1
        && count <= 10_000_000
        && bit_array.byte_size(salt) >= 8
        && bit_array.byte_size(hash) >= 16
        && bit_array.byte_size(hash) <= 64
        && bit_array.byte_size(hash) == length
      {
        True -> Ok(Stored(count, salt, hash))
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

@external(erlang, "howdy_auth_ffi", "pbkdf2_sha256")
fn pbkdf2(
  password: String,
  salt: BitArray,
  iterations: Int,
  length: Int,
) -> BitArray
