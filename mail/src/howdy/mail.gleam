//// Email for Howdy apps. Build a `Message`, then `send` it with a `Mailer`,
//// which hands it to an `Adapter`: SMTP, an HTTP provider, or the
//// development outbox.
////
//// ```gleam
//// import howdy/mail
//// import howdy/mail/smtp
//// import smail/email
//// import smail/html
////
//// let assert Ok(config) = smtp.from_env()
//// let mailer =
////   mail.mailer(smtp.adapter(config))
////   |> mail.default_from(mail.named("Acme", "hello@acme.test"))
////
//// mail.message()
//// |> mail.to([mail.address(user.email)])
//// |> mail.subject("Welcome to Acme")
//// |> mail.template(
////   email.html([], [
////     email.head([], []),
////     email.body([], [email.paragraph([], [html.text("Hi!")])]),
////   ]),
//// )
//// |> mail.send(mailer, _)
//// ```
////
//// A message is checked before any adapter sees it: it needs a sender (its
//// own or the mailer's default), at least one recipient, a subject, and an
//// HTML or text body. Addresses, the subject and headers may not contain
//// line breaks, so user input placed in them cannot add headers.
////
//// ## Sending is synchronous
////
//// `send` delivers in the calling process and returns when the adapter has
//// an answer: it opens the SMTP connection or makes the HTTP request, and
//// waits for the provider to accept or refuse the message. A request
//// handler that sends mail is held for that long, up to the adapter's
//// timeout, and an `Unavailable` error is returned rather than tried again.
//// There is no queue in this package. Where the wait matters, or a
//// temporary failure must not lose the message, either:
////
//// - let the SMTP adapter try again itself, with `smtp.retries` and
////   `smtp.backoff`, which still holds the caller for the whole time; or
//// - send it from a background job with
////   [howdy_jobs](https://hexdocs.pm/howdy_jobs/howdy/jobs.html), queued
////   in the same transaction as the change the email is about, using
////   `retryable` to decide what to try again. `message_to_json` and
////   `message_decoder` store the message as the job's arguments:
////
//// ```gleam
//// pub fn send_email() -> jobs.Job(mail.Message) {
////   jobs.define("send_email",
////     encode: mail.message_to_json,
////     decoder: mail.message_decoder(),
////   )
////   |> jobs.on_queue("mail")
//// }
////
//// // Queued: jobs.new(send_email(), message) |> jobs.insert(conn)
//// // Done, by the app's runner:
//// jobs.handle(runner, send_email(), fn(message, _) {
////   case mail.send(mailer, message) {
////     Ok(_) -> jobs.Done
////     Error(error) ->
////       case mail.retryable(error) {
////         True -> jobs.Retry(mail.error_to_string(error))
////         False -> jobs.GiveUp(mail.error_to_string(error))
////       }
////   }
//// })
//// ```
////
//// The development `outbox` is only a sink for reading mail in
//// development and tests, not a queue.

import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import howdy/service
import howdy/trace
import smail/email
import smail/html

// -- Addresses ---------------------------------------------------------------

/// A mailbox, with an optional display name.
pub type Address {
  Address(name: Option(String), email: String)
}

/// An address without a display name.
pub fn address(email: String) -> Address {
  Address(None, email)
}

/// An address shown with a name, such as `Acme <hello@acme.test>`.
pub fn named(name: String, email: String) -> Address {
  Address(Some(name), email)
}

/// Read `someone@example.com`, `Someone <someone@example.com>` or
/// `"Someone, Esq." <someone@example.com>`.
pub fn parse_address(text: String) -> Result(Address, Nil) {
  let text = string.trim(text)
  case string.ends_with(text, ">"), string.split_once(text, "<") {
    True, Ok(#(name, rest)) -> {
      let email = string.drop_end(rest, 1) |> string.trim
      let name = string.trim(name) |> unquote
      use <- bool.guard(!valid_email(email), Error(Nil))
      case name {
        "" -> Ok(Address(None, email))
        name -> Ok(Address(Some(name), email))
      }
    }
    _, _ ->
      case valid_email(text) {
        True -> Ok(Address(None, text))
        False -> Error(Nil)
      }
  }
}

fn unquote(name: String) -> String {
  case string.starts_with(name, "\""), string.ends_with(name, "\"") {
    True, True ->
      name
      |> string.drop_start(1)
      |> string.drop_end(1)
      |> string.replace("\\\"", "\"")
      |> string.replace("\\\\", "\\")
    _, _ -> name
  }
}

/// The address as a person would write it.
pub fn address_to_string(address: Address) -> String {
  case address.name {
    None -> address.email
    Some(name) -> name <> " <" <> address.email <> ">"
  }
}

/// Whether `email` looks like an ASCII `local@domain` mailbox. It does not
/// check that the mailbox exists. Addresses with non-ASCII characters need
/// SMTPUTF8, which not every server offers, so they are refused for now.
pub fn valid_email(email: String) -> Bool {
  case string.split(email, "@") {
    [local, domain] ->
      local != ""
      && string.length(email) <= 254
      && printable_ascii(bit_array.from_string(email))
      && { string.contains(domain, ".") || domain == "localhost" }
      && !string.starts_with(domain, ".")
      && !string.ends_with(domain, ".")
      && !string.contains(domain, "..")
    _ -> False
  }
}

/// ASCII from `!` to `~`, without `<`, `>`, `(`, `)`, `,`, `;`, `:`, `\`,
/// `"`, `[` or `]`: nothing that would change the meaning of a header.
fn printable_ascii(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bytes>> ->
      byte > 32
      && byte < 127
      && !list.contains([60, 62, 40, 41, 44, 59, 58, 92, 34, 91, 93], byte)
      && printable_ascii(rest)
    _ -> False
  }
}

// -- Attachments -------------------------------------------------------------

/// A file sent with a message.
pub type Attachment {
  Attachment(
    filename: String,
    /// A MIME type such as `application/pdf`.
    content_type: String,
    content: BitArray,
    /// Set by `inline`: the id an HTML body refers to as `cid:<id>`.
    content_id: Option(String),
  )
}

pub fn attachment(
  filename filename: String,
  content_type content_type: String,
  content content: BitArray,
) -> Attachment {
  Attachment(filename:, content_type:, content:, content_id: None)
}

/// Show an attachment inside the HTML body, where `<img src="cid:logo">`
/// refers to it, instead of listing it as a download.
pub fn inline(attachment: Attachment, content_id: String) -> Attachment {
  Attachment(..attachment, content_id: Some(content_id))
}

// -- Messages ----------------------------------------------------------------

/// An email being written. Every function that takes a list adds to what
/// was there.
pub opaque type Message {
  Message(
    from: Option(Address),
    to: List(Address),
    cc: List(Address),
    bcc: List(Address),
    reply_to: Option(Address),
    subject: String,
    html: Option(String),
    /// Set by `text`, and preferred over `generated`.
    text: Option(String),
    /// The plain text `template` made from its element.
    generated: Option(String),
    headers: List(#(String, String)),
    attachments: List(Attachment),
    tags: List(String),
  )
}

/// An empty message.
pub fn message() -> Message {
  Message(
    from: None,
    to: [],
    cc: [],
    bcc: [],
    reply_to: None,
    subject: "",
    html: None,
    text: None,
    generated: None,
    headers: [],
    attachments: [],
    tags: [],
  )
}

/// Send from this address instead of the mailer's default.
pub fn from(message: Message, address: Address) -> Message {
  Message(..message, from: Some(address))
}

pub fn to(message: Message, addresses: List(Address)) -> Message {
  Message(..message, to: list.append(message.to, addresses))
}

pub fn cc(message: Message, addresses: List(Address)) -> Message {
  Message(..message, cc: list.append(message.cc, addresses))
}

/// Recipients the others do not see.
pub fn bcc(message: Message, addresses: List(Address)) -> Message {
  Message(..message, bcc: list.append(message.bcc, addresses))
}

pub fn reply_to(message: Message, address: Address) -> Message {
  Message(..message, reply_to: Some(address))
}

pub fn subject(message: Message, subject: String) -> Message {
  Message(..message, subject:)
}

/// Render a [smail](https://hexdocs.pm/smail) email to HTML, and to plain
/// text for mail clients that do not show HTML. `text` overrides the
/// generated text.
///
/// Check the generated text in the admin's previews: smail can run the
/// block after an `email.button` into the button's URL, which breaks the
/// link for text readers. Write the text with `text` when it carries a link
/// that matters, as `howdy/auth/emails` does.
pub fn template(message: Message, element: html.Element) -> Message {
  Message(
    ..message,
    html: Some(email.to_html(element)),
    generated: Some(email.to_plain_text(element)),
  )
}

/// Use this HTML as it is, without smail.
pub fn html(message: Message, html: String) -> Message {
  Message(..message, html: Some(html), generated: None)
}

/// The plain text body.
pub fn text(message: Message, text: String) -> Message {
  Message(..message, text: Some(text))
}

/// Add a header, such as `List-Unsubscribe`. The headers this module writes
/// itself (`From`, `To`, `Subject`, `Content-Type` and so on) are refused
/// when the message is sent: use their functions instead.
pub fn header(message: Message, name: String, value: String) -> Message {
  Message(..message, headers: list.append(message.headers, [#(name, value)]))
}

pub fn attach(message: Message, attachment: Attachment) -> Message {
  Message(
    ..message,
    attachments: list.append(message.attachments, [attachment]),
  )
}

/// Label the message, such as `auth.sign_in`. Providers that support tags
/// or categories receive them, and the development outbox shows them.
pub fn tag(message: Message, tag: String) -> Message {
  Message(..message, tags: list.append(message.tags, [tag]))
}

// -- Keeping messages -----------------------------------------------------------

/// The message as JSON, to keep it somewhere durable and send it later,
/// such as in a background job's arguments. `message_decoder` reads it
/// back. Attachments are included, base64-encoded, which makes the JSON a
/// third larger than the files: for big files, store them elsewhere and
/// attach them when the message is sent.
pub fn message_to_json(message: Message) -> Json {
  let address = fn(address: Address) {
    json.object([
      #("name", json.nullable(address.name, json.string)),
      #("email", json.string(address.email)),
    ])
  }
  json.object([
    #("format", json.int(1)),
    #("from", json.nullable(message.from, address)),
    #("to", json.array(message.to, address)),
    #("cc", json.array(message.cc, address)),
    #("bcc", json.array(message.bcc, address)),
    #("reply_to", json.nullable(message.reply_to, address)),
    #("subject", json.string(message.subject)),
    #("html", json.nullable(message.html, json.string)),
    #("text", json.nullable(message.text, json.string)),
    #("generated", json.nullable(message.generated, json.string)),
    #(
      "headers",
      json.array(message.headers, fn(header) {
        json.preprocessed_array([json.string(header.0), json.string(header.1)])
      }),
    ),
    #(
      "attachments",
      json.array(message.attachments, fn(attachment) {
        json.object([
          #("filename", json.string(attachment.filename)),
          #("content_type", json.string(attachment.content_type)),
          #(
            "content",
            json.string(bit_array.base64_encode(attachment.content, True)),
          ),
          #("content_id", json.nullable(attachment.content_id, json.string)),
        ])
      }),
    ),
    #("tags", json.array(message.tags, json.string)),
  ])
}

/// Read a message `message_to_json` wrote.
pub fn message_decoder() -> Decoder(Message) {
  let address = {
    use name <- decode.field("name", decode.optional(decode.string))
    use email <- decode.field("email", decode.string)
    decode.success(Address(name:, email:))
  }
  let header = {
    use name <- decode.field(0, decode.string)
    use value <- decode.field(1, decode.string)
    decode.success(#(name, value))
  }
  let attachment = {
    use filename <- decode.field("filename", decode.string)
    use content_type <- decode.field("content_type", decode.string)
    use content <- decode.field("content", base64())
    use content_id <- decode.field("content_id", decode.optional(decode.string))
    decode.success(Attachment(filename:, content_type:, content:, content_id:))
  }
  use format <- decode.field("format", decode.int)
  use <- bool.lazy_guard(format != 1, fn() {
    decode.failure(message(), "a message in format 1")
  })
  use from <- decode.field("from", decode.optional(address))
  use to <- decode.field("to", decode.list(address))
  use cc <- decode.field("cc", decode.list(address))
  use bcc <- decode.field("bcc", decode.list(address))
  use reply_to <- decode.field("reply_to", decode.optional(address))
  use subject <- decode.field("subject", decode.string)
  use html <- decode.field("html", decode.optional(decode.string))
  use text <- decode.field("text", decode.optional(decode.string))
  use generated <- decode.field("generated", decode.optional(decode.string))
  use headers <- decode.field("headers", decode.list(header))
  use attachments <- decode.field("attachments", decode.list(attachment))
  use tags <- decode.field("tags", decode.list(decode.string))
  decode.success(Message(
    from:,
    to:,
    cc:,
    bcc:,
    reply_to:,
    subject:,
    html:,
    text:,
    generated:,
    headers:,
    attachments:,
    tags:,
  ))
}

fn base64() -> Decoder(BitArray) {
  use encoded <- decode.then(decode.string)
  case bit_array.base64_decode(encoded) {
    Ok(content) -> decode.success(content)
    Error(Nil) -> decode.failure(<<>>, "base64")
  }
}

// -- What adapters receive -----------------------------------------------------

/// A message that passed the checks, with the mailer's defaults applied.
/// This is what an adapter sends.
pub type Outgoing {
  Outgoing(
    /// Unique to this send, and used in the `Message-ID` header. Providers
    /// that take an idempotency key receive it, so a retry of the same
    /// `Outgoing` is not delivered twice.
    id: String,
    date: Timestamp,
    from: Address,
    to: List(Address),
    cc: List(Address),
    bcc: List(Address),
    reply_to: Option(Address),
    subject: String,
    html: Option(String),
    text: Option(String),
    headers: List(#(String, String)),
    attachments: List(Attachment),
    tags: List(String),
  )
}

/// Every recipient, for the SMTP envelope.
pub fn recipients(outgoing: Outgoing) -> List(Address) {
  list.flatten([outgoing.to, outgoing.cc, outgoing.bcc])
}

/// What happened to a sent message.
pub type Receipt {
  Receipt(
    /// The `Outgoing` id.
    id: String,
    /// The provider's own id for it, if it gave one.
    provider_id: Option(String),
  )
}

/// Why a message was not sent.
pub type Error {
  /// The message itself is wrong: a missing sender, recipient or subject,
  /// an address that is not one, or a line break in a header. Sending it
  /// again will not help.
  Invalid(String)
  /// The provider could not be reached or asked to be tried later: a
  /// timeout, an SMTP `4xx`, or an HTTP `429` or `5xx`. Worth retrying.
  Unavailable(String)
  /// The provider refused it for good: bad credentials, an unverified
  /// sender, or an SMTP `5xx`.
  Refused(String)
}

/// Whether trying again later might work.
pub fn retryable(error: Error) -> Bool {
  case error {
    Unavailable(_) -> True
    Invalid(_) | Refused(_) -> False
  }
}

pub fn error_to_string(error: Error) -> String {
  case error {
    Invalid(reason) -> "invalid message: " <> reason
    Unavailable(reason) -> "mail provider unavailable: " <> reason
    Refused(reason) -> "mail provider refused the message: " <> reason
  }
}

/// A service error for a failed send. Only `Invalid` explains itself to
/// the client; provider failures become `Internal`, which is logged and
/// not shown.
pub fn to_service_error(error: Error) -> service.Error {
  case error {
    Invalid(reason) -> service.Invalid(reason)
    Unavailable(_) | Refused(_) -> service.Internal(error_to_string(error))
  }
}

// -- Adapters ----------------------------------------------------------------

/// Something that delivers mail: `howdy/mail/smtp`, `howdy/mail/resend`,
/// `howdy/mail/sendgrid`, `howdy/mail/outbox`, or one of your own.
pub opaque type Adapter {
  Adapter(name: String, send: fn(Outgoing) -> Result(Receipt, Error))
}

/// An adapter for a provider this package does not cover. `send` receives a
/// checked `Outgoing`, and returns `Receipt(outgoing.id, provider_id)`.
/// `howdy/mail/mime` builds the raw message for providers that take one.
pub fn adapter(
  named name: String,
  send send: fn(Outgoing) -> Result(Receipt, Error),
) -> Adapter {
  Adapter(name:, send:)
}

pub fn adapter_name(adapter: Adapter) -> String {
  adapter.name
}

/// Hand an `Outgoing` to an adapter directly, as a wrapping adapter does.
pub fn deliver(adapter: Adapter, outgoing: Outgoing) -> Result(Receipt, Error) {
  adapter.send(outgoing)
}

/// Send everything to one address instead, for a staging server that must
/// not mail real people. `Cc` and `Bcc` are dropped, and the intended
/// recipients are kept in an `X-Original-To` header.
pub fn redirect_all(adapter: Adapter, to address: Address) -> Adapter {
  Adapter(name: adapter.name <> " (redirected)", send: fn(outgoing) {
    let original =
      recipients(outgoing)
      |> list.map(fn(recipient) { recipient.email })
      |> string.join(", ")
    adapter.send(
      Outgoing(
        ..outgoing,
        to: [address],
        cc: [],
        bcc: [],
        headers: list.append(outgoing.headers, [#("X-Original-To", original)]),
      ),
    )
  })
}

/// Try `secondary` when `primary` is `Unavailable`. A message `primary`
/// refused is not retried, since the second provider would refuse it too.
pub fn fallback(primary: Adapter, secondary: Adapter) -> Adapter {
  Adapter(name: primary.name <> ", then " <> secondary.name, send: fn(outgoing) {
    case primary.send(outgoing) {
      Error(Unavailable(_)) -> secondary.send(outgoing)
      result -> result
    }
  })
}

// -- Sending -----------------------------------------------------------------

/// An adapter and the defaults applied to every message.
pub opaque type Mailer {
  Mailer(adapter: Adapter, from: Option(Address))
}

pub fn mailer(adapter: Adapter) -> Mailer {
  Mailer(adapter:, from: None)
}

/// The sender of messages that do not name their own.
pub fn default_from(mailer: Mailer, address: Address) -> Mailer {
  Mailer(..mailer, from: Some(address))
}

pub fn mailer_adapter(mailer: Mailer) -> Adapter {
  mailer.adapter
}

/// Check a message and apply the mailer's defaults, without sending it.
/// `send` does this first; previews use it to show a message as it would
/// go out.
pub fn prepare(mailer: Mailer, message: Message) -> Result(Outgoing, Error) {
  let from = option.or(message.from, mailer.from)
  use from <- result.try(option.to_result(
    from,
    Invalid("no sender: use mail.from or mail.default_from"),
  ))
  use _ <- result.try(check_address("from", from))
  use <- bool.guard(
    message.to == [] && message.cc == [] && message.bcc == [],
    Error(Invalid("no recipients")),
  )
  use _ <- result.try(
    list.try_each(recipients_of(message), check_address("recipient", _)),
  )
  use _ <- result.try(case message.reply_to {
    Some(address) -> check_address("reply-to", address)
    None -> Ok(Nil)
  })
  use <- bool.guard(
    string.trim(message.subject) == "",
    Error(Invalid("no subject")),
  )
  use _ <- result.try(single_line("subject", message.subject))
  let text = option.or(message.text, message.generated)
  use <- bool.guard(
    message.html == None && text == None,
    Error(Invalid("no body: use mail.template, mail.html or mail.text")),
  )
  use _ <- result.try(list.try_each(message.headers, check_header))
  use _ <- result.try(list.try_each(message.attachments, check_attachment))
  use _ <- result.try(
    list.try_each(message.tags, fn(tag) {
      case tag {
        "" -> Error(Invalid("empty tag"))
        _ -> single_line("tag", tag)
      }
    }),
  )
  Ok(Outgoing(
    id: new_id(),
    date: timestamp.system_time(),
    from:,
    to: message.to,
    cc: message.cc,
    bcc: message.bcc,
    reply_to: message.reply_to,
    subject: message.subject,
    html: message.html,
    text:,
    headers: message.headers,
    attachments: message.attachments,
    tags: message.tags,
  ))
}

/// Check the message, then give it to the mailer's adapter. Waits for the
/// provider to accept or refuse it.
///
/// Sending is a `mail.send` span, with the adapter, the message id, its
/// tags and how many recipients it has, but not their addresses or the
/// subject.
pub fn send(mailer: Mailer, message: Message) -> Result(Receipt, Error) {
  use <- trace.run(
    trace.new("mail.send")
    |> trace.kind(trace.Client)
    |> trace.attributes([
      trace.string("mail.adapter", mailer.adapter.name),
      trace.int("mail.recipients", list.length(recipients_of(message))),
      trace.strings("mail.tags", message.tags),
    ]),
  )
  let sent = {
    use outgoing <- result.try(prepare(mailer, message))
    trace.set_attributes([trace.string("mail.id", outgoing.id)])
    mailer.adapter.send(outgoing)
  }
  case sent {
    Ok(_) -> Nil
    // The error's text can name an address, so only its kind is recorded.
    Error(error) -> {
      let kind = case error {
        Invalid(_) -> "invalid"
        Unavailable(_) -> "unavailable"
        Refused(_) -> "refused"
      }
      trace.set_attributes([trace.string("error.type", kind)])
      trace.set_error("mail " <> kind)
    }
  }
  sent
}

fn recipients_of(message: Message) -> List(Address) {
  list.flatten([message.to, message.cc, message.bcc])
}

fn check_address(role: String, address: Address) -> Result(Nil, Error) {
  use <- bool.guard(
    !valid_email(address.email),
    Error(Invalid(
      role <> " " <> string.inspect(address.email) <> " is not an email address",
    )),
  )
  case address.name {
    Some(name) -> single_line(role <> " name", name)
    None -> Ok(Nil)
  }
}

fn single_line(what: String, value: String) -> Result(Nil, Error) {
  case string.contains(value, "\r") || string.contains(value, "\n") {
    True -> Error(Invalid(what <> " contains a line break"))
    False -> Ok(Nil)
  }
}

/// Headers `howdy/mail/mime` writes itself.
const reserved = [
  "from", "to", "cc", "bcc", "reply-to", "subject", "date", "message-id",
  "mime-version", "content-type", "content-transfer-encoding",
  "content-disposition", "content-id", "sender", "return-path",
]

fn check_header(header: #(String, String)) -> Result(Nil, Error) {
  let #(name, value) = header
  use <- bool.guard(
    name == "" || !token(bit_array.from_string(name)),
    Error(Invalid("header name " <> string.inspect(name) <> " is not valid")),
  )
  use <- bool.guard(
    list.contains(reserved, string.lowercase(name)),
    Error(Invalid(
      "header " <> name <> " is set by howdy/mail; use its own function",
    )),
  )
  single_line("header " <> name, value)
}

/// RFC 7230 token characters, which header names are made of.
fn token(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bytes>> ->
      {
        { byte >= 48 && byte <= 57 }
        || { byte >= 65 && byte <= 90 }
        || { byte >= 97 && byte <= 122 }
        || list.contains(
          [33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126],
          byte,
        )
      }
      && token(rest)
    _ -> False
  }
}

fn check_attachment(attachment: Attachment) -> Result(Nil, Error) {
  use _ <- result.try(single_line("attachment filename", attachment.filename))
  use <- bool.guard(
    string.trim(attachment.filename) == "",
    Error(Invalid("attachment has no filename")),
  )
  use _ <- result.try(
    case string.split(attachment.content_type, "/") {
      [kind, subtype] ->
        case
          kind != ""
          && subtype != ""
          && token(bit_array.from_string(kind))
          && token(bit_array.from_string(subtype))
        {
          True -> Ok(Nil)
          False -> Error(Nil)
        }
      _ -> Error(Nil)
    }
    |> result.replace_error(Invalid(
      "attachment content type "
      <> string.inspect(attachment.content_type)
      <> " is not a MIME type",
    )),
  )
  case attachment.content_id {
    Some(id) ->
      case id != "" && printable_ascii(bit_array.from_string(id)) {
        True -> Ok(Nil)
        False ->
          Error(Invalid("content id " <> string.inspect(id) <> " is not valid"))
      }
    None -> Ok(Nil)
  }
}

fn new_id() -> String {
  crypto.strong_random_bytes(16)
  |> bit_array.base16_encode
  |> string.lowercase
}
