//// Send mail with [SendGrid](https://sendgrid.com)'s v3 Mail Send API.
////
//// ```gleam
//// let assert Ok(config) = sendgrid.from_env()
//// let mailer = mail.mailer(sendgrid.adapter(config))
//// ```
////
//// SendGrid needs at least one `To` recipient, and refuses an address that
//// appears twice, so one already in `To` is dropped from `Cc` and `Bcc`.
//// Tags become categories (SendGrid keeps the first ten), and the message's
//// id is sent as the custom argument `howdy_id`. For the EU region, set
//// `base_url` to `https://api.eu.sendgrid.com`.

import gleam/bit_array
import gleam/bool
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import howdy/env
import howdy/mail.{type Adapter, type Address, type Outgoing}
import howdy/mail/internal/http as mail_http
import howdy/mail/internal/json as mail_json

pub opaque type Config {
  Config(api_key: String, base_url: String, timeout: Int)
}

pub fn new(api_key: String) -> Config {
  Config(api_key:, base_url: "https://api.sendgrid.com", timeout: 15_000)
}

/// Read the API key from `SENDGRID_API_KEY`.
pub fn from_env() -> Result(Config, Nil) {
  env.get("SENDGRID_API_KEY") |> result.map(new)
}

/// Where the API is, without a trailing slash. Default
/// `https://api.sendgrid.com`.
pub fn base_url(config: Config, url: String) -> Config {
  Config(..config, base_url: url)
}

/// How long to wait for SendGrid. Default 15 seconds.
pub fn timeout(config: Config, milliseconds: Int) -> Config {
  Config(..config, timeout: milliseconds)
}

pub fn adapter(config: Config) -> Adapter {
  mail.adapter(named: "SendGrid", send: fn(outgoing) {
    use request <- result.try(request(config, outgoing))
    use response <- result.try(mail_http.send(request, config.timeout))
    receipt(outgoing, response)
  })
}

/// The request `adapter` sends.
pub fn request(
  config: Config,
  outgoing: Outgoing,
) -> Result(Request(String), mail.Error) {
  use <- bool.guard(
    outgoing.to == [],
    Error(mail.Invalid("SendGrid needs at least one To recipient")),
  )
  use base <- result.try(
    request.to(config.base_url <> "/v3/mail/send")
    |> result.replace_error(mail.Refused("invalid SendGrid base URL")),
  )
  Ok(
    base
    |> request.set_method(http.Post)
    |> request.set_header("authorization", "Bearer " <> config.api_key)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("user-agent", "howdy_mail")
    |> request.set_body(json.to_string(body(outgoing))),
  )
}

/// The receipt for SendGrid's response to `request`: `202 Accepted`, with
/// its id in `X-Message-Id`.
pub fn receipt(
  outgoing: Outgoing,
  response: Response(String),
) -> Result(mail.Receipt, mail.Error) {
  case response.status {
    200 | 202 ->
      Ok(mail.Receipt(
        outgoing.id,
        response.get_header(response, "x-message-id") |> option.from_result,
      ))
    _ -> Error(mail_http.failure("SendGrid", response))
  }
}

fn body(outgoing: Outgoing) -> Json {
  let seen = fn(addresses: List(Address)) {
    list.map(addresses, fn(a) { string.lowercase(a.email) })
  }
  let to = unique(outgoing.to, [])
  let cc = unique(outgoing.cc, seen(to))
  let bcc = unique(outgoing.bcc, list.append(seen(to), seen(cc)))
  json.object(
    list.flatten([
      [
        #(
          "personalizations",
          json.preprocessed_array([
            json.object(
              list.flatten([
                [#("to", json.array(to, address))],
                mail_json.present("cc", cc, json.array(_, address)),
                mail_json.present("bcc", bcc, json.array(_, address)),
              ]),
            ),
          ]),
        ),
        #("from", address(outgoing.from)),
        #("subject", json.string(outgoing.subject)),
        #(
          "content",
          json.preprocessed_array(
            list.flatten([
              // SendGrid requires text/plain first.
              case outgoing.text {
                Some(text) -> [content("text/plain", text)]
                None -> []
              },
              case outgoing.html {
                Some(html) -> [content("text/html", html)]
                None -> []
              },
            ]),
          ),
        ),
        #("custom_args", json.object([#("howdy_id", json.string(outgoing.id))])),
      ],
      case outgoing.reply_to {
        Some(reply_to) -> [#("reply_to", address(reply_to))]
        None -> []
      },
      case outgoing.headers {
        [] -> []
        headers -> [
          #(
            "headers",
            json.object(list.map(headers, fn(h) { #(h.0, json.string(h.1)) })),
          ),
        ]
      },
      mail_json.present("attachments", outgoing.attachments, fn(attachments) {
        json.array(attachments, fn(attachment: mail.Attachment) {
          json.object(
            list.flatten([
              [
                #(
                  "content",
                  json.string(bit_array.base64_encode(attachment.content, True)),
                ),
                #("filename", json.string(attachment.filename)),
                #("type", json.string(attachment.content_type)),
              ],
              case attachment.content_id {
                Some(id) -> [
                  #("disposition", json.string("inline")),
                  #("content_id", json.string(id)),
                ]
                None -> [#("disposition", json.string("attachment"))]
              },
            ]),
          )
        })
      }),
      mail_json.present(
        "categories",
        list.take(outgoing.tags, 10),
        json.array(_, fn(tag) { json.string(string.slice(tag, 0, 255)) }),
      ),
    ]),
  )
}

fn address(address: Address) -> Json {
  json.object(
    list.flatten([
      [#("email", json.string(address.email))],
      case address.name {
        Some(name) -> [#("name", json.string(name))]
        None -> []
      },
    ]),
  )
}

fn content(kind: String, value: String) -> Json {
  json.object([#("type", json.string(kind)), #("value", json.string(value))])
}

/// Addresses not already in `seen`, each once, compared without case.
fn unique(addresses: List(Address), seen: List(String)) -> List(Address) {
  case addresses {
    [] -> []
    [first, ..rest] -> {
      let email = string.lowercase(first.email)
      case list.contains(seen, email) {
        True -> unique(rest, seen)
        False -> [first, ..unique(rest, [email, ..seen])]
      }
    }
  }
}
