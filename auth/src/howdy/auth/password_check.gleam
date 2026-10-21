//// Helpers for application-owned compromised-password screening.
//// Load the corpus once at startup; no password is sent to a remote service.

import gleam/dict
import gleam/list
import howdy/auth/internal/password
import howdy/auth/internal/token
import howdy/service

/// Build a checker for a local breach corpus or application-specific blocklist.
/// Store only SHA-256 digests in the lookup closure, and compare using the same
/// NFC normalization as password hashing. The list is case-sensitive and not
/// trimmed. This supplements the built-in common-password check.
///
/// ```gleam
/// let identity = auth.with_password_check(identity, password_check.blocklist(corpus))
/// ```
pub fn blocklist(passwords: List(String)) -> fn(String) -> service.Result(Nil) {
  let denied =
    passwords
    |> list.map(fn(value) { #(token.digest(password.normalize(value)), Nil) })
    |> dict.from_list
  fn(value) {
    case dict.has_key(denied, token.digest(password.normalize(value))) {
      True ->
        Error(service.Coded(
          "password_common",
          service.Invalid("choose a password that is not common or breached"),
        ))
      False -> Ok(Nil)
    }
  }
}
