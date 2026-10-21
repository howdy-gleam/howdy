//// Pieces of URL handling that connection strings share: the user and
//// password in a `scheme://user:password@host/...` URL, and the guess a
//// package makes about whether a host is local.

import gleam/bool
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

/// The user and password from a URL's userinfo, percent-decoded. A URL with
/// no userinfo has no credentials; one with `user` but no `:` has no
/// password. An empty user or an escape that does not decode is an error.
///
/// ```gleam
/// url.credentials(Some("ada:s%3Acret")) // -> Ok(Some(#("ada", Some("s:cret"))))
/// url.credentials(None)                 // -> Ok(None)
/// ```
pub fn credentials(
  userinfo: Option(String),
) -> Result(Option(#(String, Option(String))), Nil) {
  case userinfo {
    None -> Ok(None)
    Some(userinfo) ->
      case string.split_once(userinfo, ":") {
        Ok(#(user, password)) -> {
          use user <- result.try(uri.percent_decode(user))
          use password <- result.try(uri.percent_decode(password))
          use <- bool.guard(user == "", Error(Nil))
          Ok(Some(#(user, Some(password))))
        }
        Error(Nil) -> {
          use user <- result.try(uri.percent_decode(userinfo))
          use <- bool.guard(user == "", Error(Nil))
          Ok(Some(#(user, None)))
        }
      }
  }
}

/// Whether a host looks like it is on this machine or a private network:
/// a loopback address, or a name with no dot in it such as a Compose
/// service called `db`. Packages use this to pick a default of no TLS for
/// local connections and verified TLS for everything else.
pub fn is_local(host: String) -> Bool {
  case host {
    "localhost" | "127.0.0.1" | "::1" | "[::1]" -> True
    _ -> !{ string.contains(host, ".") || string.contains(host, ":") }
  }
}
