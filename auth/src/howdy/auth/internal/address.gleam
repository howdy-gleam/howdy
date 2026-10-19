//// Canonical forms for the two addresses this package is configured with and
//// authenticates on. Both are pure: given the same text they always give the
//// same answer, whatever the database or the request contains.

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import howdy/service

@external(erlang, "howdy_auth_ffi", "canonical_host")
fn canonical_host(host: String) -> Result(String, Nil)

pub fn canonical_origin(origin: String) -> service.Result(String) {
  use parsed <- result.try(
    uri.parse(origin)
    |> result.map_error(fn(_) { service.Invalid("invalid auth origin") }),
  )
  use host <- result.try(case parsed.host {
    Some(host) ->
      canonical_host(host)
      |> result.map_error(fn(_) {
        service.Invalid(
          "invalid auth origin host; use an ASCII hostname or IP address",
        )
      })
    None -> Error(service.Invalid("auth origin needs a host"))
  })
  let parsed =
    uri.Uri(
      ..parsed,
      scheme: option.map(parsed.scheme, string.lowercase),
      host: Some(host),
    )
  let parsed =
    uri.Uri(..parsed, port: case parsed.scheme, parsed.port {
      Some("https"), Some(443) | Some("http"), Some(80) -> None
      _, port -> port
    })
  let scheme_ok = case parsed.scheme, parsed.host {
    Some("https"), Some(host) -> host != ""
    Some("http"), Some("localhost")
    | Some("http"), Some("127.0.0.1")
    | Some("http"), Some("::1")
    -> True
    _, _ -> False
  }
  case
    scheme_ok
    && parsed.path == ""
    && parsed.query == None
    && parsed.fragment == None
    && parsed.userinfo == None
    && case parsed.port {
      None -> True
      Some(port) -> port > 0 && port <= 65_535
    }
  {
    True -> {
      // Gleam parses IPv6 without brackets; its serializer does not add them.
      let parsed =
        uri.Uri(
          ..parsed,
          host: option.map(parsed.host, fn(host) {
            case string.contains(host, ":") {
              True -> "[" <> host <> "]"
              False -> host
            }
          }),
        )
      Ok(uri.to_string(parsed))
    }
    False ->
      Error(service.Invalid(
        "auth origin must be an HTTPS origin (HTTP allowed on loopback only)",
      ))
  }
}

pub fn normalize_email(email: String) -> service.Result(String) {
  let email = string.lowercase(string.trim(email))
  let shape = case string.split(email, "@") {
    [local, domain] ->
      local != "" && domain != "" && string.contains(domain, ".")
    _ -> False
  }
  case
    shape
    && string.byte_size(email) <= 254
    && list.all(string.to_utf_codepoints(email), fn(c) {
      let n = string.utf_codepoint_to_int(c)
      n > 32 && n != 127
    })
  {
    True -> Ok(email)
    False ->
      Error(service.Coded(
        "email_invalid",
        service.Invalid("invalid email address"),
      ))
  }
}
