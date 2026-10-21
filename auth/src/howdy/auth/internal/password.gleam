//// Password storage through the configured `PasswordHasher`; token digests
//// remain SHA-256 elsewhere.

import gleam/int
import gleam/list
import gleam/result
import gleam/string
import howdy/auth/internal/token
import howdy/auth/password_hasher.{type PasswordHasher}
import howdy/auth/policy
import howdy/service

pub opaque type Passwords {
  Passwords(hasher: PasswordHasher, dummy_hash: String)
}

/// The dummy hash lets a login for a missing account do the same work as one
/// for a real account, so response time does not reveal which emails exist.
pub fn new(hasher: PasswordHasher) -> service.Result(Passwords) {
  use dummy <- result.try(hasher.hash(token.new()) |> result.map_error(failed))
  Ok(Passwords(hasher, dummy))
}

@external(erlang, "howdy_auth_ffi", "normalize_password")
pub fn normalize(password: String) -> String

/// Reject passwords that are weak in ways a length minimum does not catch.
/// With a 15 character minimum, the classic short passwords are already out;
/// what gets through is long and structured: a common word with a decorative
/// suffix, one unit repeated, a keyboard run, a handful of characters.
///
/// This is a shape check, not a breach corpus. It cannot know that a given
/// passphrase appeared in a public dump. Applications that need that supply
/// it with `auth.with_password_check`; see `howdy/auth/password_check`.
pub fn common_check(password: String) -> service.Result(Nil) {
  let lower = string.lowercase(password)
  let bare = undecorate(lower)
  case
    list.contains(common, lower)
    || list.contains(common, bare)
    || bare == ""
    || rooted(bare)
    || repeated_unit(lower)
    || thin_alphabet(lower)
    || run_of(bare)
  {
    True ->
      Error(service.Coded(
        "password_common",
        service.Invalid("choose a password that is not common or breached"),
      ))
    False -> Ok(Nil)
  }
}

const common = [
  "password", "password123", "passwordpassword", "123456789012345",
  "1234567890123456", "qwertyuiopasdfgh", "letmeinletmein",
  "correct horse battery staple", "iloveyouiloveyou", "administrator",
  "thisismypassword", "mypasswordis1234", "letmeinplease123",
  "welcometothejungle", "passwordispassword", "keyboardkeyboard",
]

/// Words that carry no strength however they are dressed up.
const roots = [
  "password", "passwort", "passphrase", "letmein", "welcome", "qwerty",
  "iloveyou", "princess", "monkey", "dragon", "football", "baseball", "sunshine",
  "trustno", "admin", "administrator", "changeme", "secret", "master", "shadow",
  "superman", "batman", "starwars", "whatever", "freedom", "hello", "login",
  "abc", "test", "qwertyuiop", "asdfghjkl",
]

/// Rows and alphabets people walk along instead of choosing something.
const runs = [
  "1234567890123456789012345678901234567890", "qwertyuiop", "qwertzuiop",
  "azertyuiop", "asdfghjkl", "zxcvbnm", "abcdefghijklmnopqrstuvwxyz",
  "!@#$%^&*()", "qazwsxedcrfvtgbyhnujmikolp",
]

/// Decoration people add to reach a length minimum, at either end.
const decoration = "0123456789!@#$%^&*._-+= "

fn undecorate(value: String) -> String {
  value
  |> string.to_graphemes
  |> list.drop_while(string.contains(decoration, _))
  |> list.reverse
  |> list.drop_while(string.contains(decoration, _))
  |> list.reverse
  |> string.concat
}

/// A weak word, alone or simply repeated, is still that weak word.
fn rooted(bare: String) -> Bool {
  list.any(roots, fn(root) {
    bare == root || { root != "" && bare == repeat_to(root, bare) }
  })
}

/// True when `value` is some prefix of itself repeated three times or more:
/// "abcabcabcabcabc" has the strength of "abc".
fn repeated_unit(value: String) -> Bool {
  let graphemes = string.to_graphemes(value)
  let length = list.length(graphemes)
  // Every unit length that could tile the password at least three times.
  list.index_map(graphemes, fn(_, index) { index + 1 })
  |> list.take(length / 3)
  |> list.any(fn(size) {
    let unit = graphemes |> list.take(size) |> string.concat
    unit != "" && repeat_to(unit, value) == value
  })
}

fn repeat_to(unit: String, target: String) -> String {
  let needed = string.length(target) / string.length(unit) + 1
  string.repeat(unit, needed)
  |> string.to_graphemes
  |> list.take(string.length(target))
  |> string.concat
}

/// Length bought with very few different characters buys little.
fn thin_alphabet(value: String) -> Bool {
  list.length(list.unique(string.to_graphemes(value))) <= 4
}

/// The whole password is a walk along one keyboard row or alphabet.
fn run_of(bare: String) -> Bool {
  list.any(runs, fn(run) {
    string.contains(run, bare) || string.contains(reverse(run), bare)
  })
}

fn reverse(value: String) -> String {
  value |> string.to_graphemes |> list.reverse |> string.concat
}

pub fn validate(password: String, min_length: Int) -> service.Result(Nil) {
  use _ <- result.try(
    case string.byte_size(password) > policy.password_max_bytes {
      True ->
        Error(service.Coded(
          "password_too_long",
          service.Invalid(
            "password must contain at most "
            <> int.to_string(policy.password_max_bytes)
            <> " UTF-8 bytes",
          ),
        ))
      False -> Ok(Nil)
    },
  )
  case list.length(string.to_utf_codepoints(password)) >= min_length {
    True -> Ok(Nil)
    False ->
      Error(service.Coded(
        "password_length",
        service.Invalid(
          "password must contain at least "
          <> int.to_string(min_length)
          <> " characters and at most "
          <> int.to_string(policy.password_max_bytes)
          <> " UTF-8 bytes",
        ),
      ))
  }
}

/// Callers validate the password against their policy first.
pub fn hash(passwords: Passwords, password: String) -> service.Result(String) {
  passwords.hasher.hash(normalize(password)) |> result.map_error(failed)
}

/// Accept legacy hashes made before normalization; the caller rehashes them
/// after success, under the same credential lock used for issuing a session.
/// Only unknown legacy hashes may use the second, exact-input verification.
pub fn verify(
  passwords: Passwords,
  encoded: String,
  password: String,
  normalized: Bool,
) -> service.Result(#(Bool, Bool)) {
  let check = passwords.hasher.verify
  use valid <- result.try(
    check(encoded, normalize(password)) |> result.map_error(failed),
  )
  case normalized || valid || normalize(password) == password {
    True -> Ok(#(valid, False))
    False ->
      check(encoded, password)
      |> result.map(fn(valid) { #(valid, valid) })
      |> result.map_error(failed)
  }
}

pub fn needs_rehash(passwords: Passwords, encoded: String) -> Bool {
  passwords.hasher.needs_rehash(encoded)
}

/// Upgrade without reducing any existing cost or output length. Keep stronger
/// stored hashes intact when only the application's minimum has changed.
pub fn rehash(
  passwords: Passwords,
  encoded: String,
  password: String,
) -> service.Result(String) {
  passwords.hasher.rehash(encoded, normalize(password))
  |> result.map_error(failed)
}

pub fn dummy(passwords: Passwords) -> String {
  passwords.dummy_hash
}

fn failed(_error: Nil) -> service.Error {
  service.Internal("password hashing operation failed")
}
