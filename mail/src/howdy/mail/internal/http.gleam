//// What the HTTP provider adapters share: sending with a timeout, and
//// sorting failures into retryable and not.

import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/option.{None, Some}
import gleam/string
import howdy/mail.{type Address}

pub fn send(
  request: Request(String),
  timeout: Int,
) -> Result(Response(String), mail.Error) {
  case httpc.configure() |> httpc.timeout(timeout) |> httpc.dispatch(request) {
    Ok(response) -> Ok(response)
    Error(httpc.ResponseTimeout) ->
      Error(mail.Unavailable(
        "no response within " <> string.inspect(timeout) <> "ms",
      ))
    Error(httpc.FailedToConnect(ip4, ip6)) ->
      Error(mail.Unavailable(
        "could not connect: "
        <> string.inspect(ip4)
        <> ", "
        <> string.inspect(ip6),
      ))
    Error(httpc.InvalidUtf8Response) ->
      Error(mail.Unavailable("the response was not UTF-8"))
  }
}

/// A failed response: throttling, timeouts and server errors are worth
/// retrying; anything else was refused.
pub fn failure(provider: String, response: Response(String)) -> mail.Error {
  let reason =
    provider
    <> " answered "
    <> string.inspect(response.status)
    <> ": "
    <> string.slice(response.body, 0, 300)
  case response.status {
    408 | 429 -> mail.Unavailable(reason)
    status if status >= 500 -> mail.Unavailable(reason)
    _ -> mail.Refused(reason)
  }
}

/// `Name <email>` for JSON APIs, quoting a name that has characters with a
/// meaning in addresses.
pub fn display(address: Address) -> String {
  case address.name {
    None -> address.email
    Some(name) ->
      case
        string.contains(name, "\"")
        || string.contains(name, ",")
        || string.contains(name, "<")
        || string.contains(name, ">")
        || string.contains(name, "@")
        || string.contains(name, ";")
        || string.contains(name, ":")
        || string.contains(name, "\\")
      {
        True ->
          "\""
          <> {
            name
            |> string.replace("\\", "\\\\")
            |> string.replace("\"", "\\\"")
          }
          <> "\" <"
          <> address.email
          <> ">"
        False -> name <> " <" <> address.email <> ">"
      }
  }
}
