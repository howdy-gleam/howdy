//// Send mail with [Resend](https://resend.com)'s HTTP API.
////
//// ```gleam
//// let assert Ok(config) = resend.from_env()
//// let mailer = mail.mailer(resend.adapter(config))
//// ```
////
//// The sender's domain must be verified with Resend. Each message's id is
//// sent as the `Idempotency-Key`, so retrying the same `Outgoing` after a
//// timeout does not send it twice. Resend allows only letters, digits, `_`
//// and `-` in tags, so other characters in `mail.tag` become `_`, and each
//// tag is sent as a name with the value `true`.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import howdy/env
import howdy/mail.{type Adapter, type Outgoing}
import howdy/mail/internal/http as mail_http
import howdy/mail/internal/json as mail_json

pub opaque type Config {
  Config(api_key: String, base_url: String, timeout: Int)
}

pub fn new(api_key: String) -> Config {
  Config(api_key:, base_url: "https://api.resend.com", timeout: 15_000)
}

/// Read the API key from `RESEND_API_KEY`.
pub fn from_env() -> Result(Config, Nil) {
  env.get("RESEND_API_KEY") |> result.map(new)
}

/// Where the API is, without a trailing slash. Default
/// `https://api.resend.com`.
pub fn base_url(config: Config, url: String) -> Config {
  Config(..config, base_url: url)
}

/// How long to wait for Resend. Default 15 seconds.
pub fn timeout(config: Config, milliseconds: Int) -> Config {
  Config(..config, timeout: milliseconds)
}

pub fn adapter(config: Config) -> Adapter {
  mail.adapter(named: "Resend", send: fn(outgoing) {
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
  use base <- result.try(
    request.to(config.base_url <> "/emails")
    |> result.replace_error(mail.Refused("invalid Resend base URL")),
  )
  Ok(
    base
    |> request.set_method(http.Post)
    |> request.set_header("authorization", "Bearer " <> config.api_key)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("idempotency-key", outgoing.id)
    |> request.set_header("user-agent", "howdy_mail")
    |> request.set_body(json.to_string(body(outgoing))),
  )
}

/// The receipt for Resend's response to `request`.
pub fn receipt(
  outgoing: Outgoing,
  response: Response(String),
) -> Result(mail.Receipt, mail.Error) {
  case response.status {
    200 | 201 | 202 -> {
      let id =
        json.parse(response.body, {
          use id <- decode.field("id", decode.string)
          decode.success(id)
        })
        |> option.from_result
      Ok(mail.Receipt(outgoing.id, id))
    }
    _ -> Error(mail_http.failure("Resend", response))
  }
}

fn body(outgoing: Outgoing) -> Json {
  let addresses = fn(list) {
    json.array(list, fn(a) { json.string(mail_http.display(a)) })
  }
  json.object(
    list.flatten([
      [
        #("from", json.string(mail_http.display(outgoing.from))),
        #("to", addresses(outgoing.to)),
        #("subject", json.string(outgoing.subject)),
      ],
      mail_json.present("cc", outgoing.cc, addresses),
      mail_json.present("bcc", outgoing.bcc, addresses),
      case outgoing.reply_to {
        Some(address) -> [#("reply_to", addresses([address]))]
        None -> []
      },
      case outgoing.html {
        Some(html) -> [#("html", json.string(html))]
        None -> []
      },
      case outgoing.text {
        Some(text) -> [#("text", json.string(text))]
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
                #("filename", json.string(attachment.filename)),
                #(
                  "content",
                  json.string(bit_array.base64_encode(attachment.content, True)),
                ),
                #("content_type", json.string(attachment.content_type)),
              ],
              case attachment.content_id {
                Some(id) -> [#("content_id", json.string(id))]
                None -> []
              },
            ]),
          )
        })
      }),
      mail_json.present("tags", outgoing.tags, fn(tags) {
        json.array(tags, fn(tag) {
          json.object([
            #("name", json.string(tag_name(tag))),
            #("value", json.string("true")),
          ])
        })
      }),
    ]),
  )
}

/// Letters, digits, `_` and `-`, at most 256 characters.
pub fn tag_name(tag: String) -> String {
  string.to_graphemes(tag)
  |> list.map(fn(c) {
    case
      string.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-",
        c,
      )
    {
      True -> c
      False -> "_"
    }
  })
  |> string.concat
  |> string.slice(0, 256)
}
