//// Send mail through an SMTP server, such as your provider's relay or a
//// local [Mailpit](https://mailpit.axllent.org).
////
//// ```gleam
//// import howdy/mail
//// import howdy/mail/smtp
////
//// let assert Ok(config) = smtp.from_env()
//// let mailer = mail.mailer(smtp.adapter(config))
//// ```
////
//// Each send opens a connection, delivers one message and closes it. The
//// call waits for the server to accept the message, so a refusal comes
//// back as an error rather than a bounce. That wait happens in the calling
//// process: a request handler that sends mail is held until the server
//// answers, or the `timeout` passes. A failure the server calls temporary,
//// such as a `4xx` reply or an unreachable host, is tried again when
//// `retries` allows it, with `backoff` between attempts; by default it is
//// not, and the error is returned to the caller.

import gleam/bool
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import howdy/env
import howdy/mail.{type Adapter, type Outgoing}
import howdy/mail/mime
import howdy/url

/// How the connection is encrypted.
pub type Tls {
  /// Unencrypted. Only for a server on the same host or a private network,
  /// such as Mailpit in development.
  NoTls
  /// Connect in plain text and upgrade with `STARTTLS`, usually on port 587.
  /// A server that does not offer the upgrade is refused rather than used
  /// unencrypted. `verify` checks the certificate against the system's CAs
  /// and the host name.
  StartTls(verify: Bool)
  /// TLS from the first byte, usually on port 465.
  ImplicitTls(verify: Bool)
}

pub type Error {
  /// The environment variable is unset or empty.
  MissingUrl(variable: String)
  /// The URL is not `smtp://user:password@host:port` or `smtps://...`. It
  /// is not repeated here because it may contain a password.
  InvalidUrl
  /// A `tls` other than `none`, `starttls` or `implicit`.
  UnsupportedTls(mode: String)
}

pub opaque type Config {
  Config(
    host: String,
    port: Int,
    username: Option(String),
    password: Option(String),
    tls: Tls,
    timeout: Int,
    helo: Option(String),
    retries: Int,
    backoff: Int,
  )
}

/// A server at `host` on port 587 with verified `STARTTLS`, or no TLS for
/// loopback addresses and dotless names such as a Compose service called
/// `mailpit`.
pub fn new(host: String) -> Config {
  Config(
    host:,
    port: 587,
    username: None,
    password: None,
    tls: default_tls(host),
    timeout: 10_000,
    helo: None,
    retries: 0,
    backoff: 500,
  )
}

/// Read the server URL from `SMTP_URL`.
pub fn from_env() -> Result(Config, Error) {
  case env.get("SMTP_URL") {
    Ok(url) -> from_url(url)
    Error(Nil) -> Error(MissingUrl("SMTP_URL"))
  }
}

/// Parse `smtp://user:password@host:port` or `smtps://...`. Percent-encode
/// an `@` in the user name as `%40`.
///
/// `smtps` means TLS from the first byte, on port 465 unless another is
/// given. `smtp` means `STARTTLS` on port 587, except for loopback
/// addresses and dotless host names, where TLS is off. Certificates are
/// verified. `?tls=none`, `?tls=starttls` or `?tls=implicit` chooses
/// explicitly.
pub fn from_url(url: String) -> Result(Config, Error) {
  use parsed <- result.try(uri.parse(url) |> result.replace_error(InvalidUrl))
  use host <- result.try(case parsed.host {
    Some(host) if host != "" ->
      Ok(host |> string.replace("[", "") |> string.replace("]", ""))
    _ -> Error(InvalidUrl)
  })
  use <- bool.guard(parsed.path != "" && parsed.path != "/", Error(InvalidUrl))
  use query <- result.try(case parsed.query {
    None -> Ok([])
    Some(query) -> uri.parse_query(query) |> result.replace_error(InvalidUrl)
  })
  use #(scheme_tls, default_port) <- result.try(case parsed.scheme {
    Some("smtp") -> Ok(#(default_tls(host), 587))
    Some("smtps") -> Ok(#(ImplicitTls(verify: True), 465))
    _ -> Error(InvalidUrl)
  })
  use tls <- result.try(case list.key_find(query, "tls") {
    Error(Nil) -> Ok(scheme_tls)
    Ok("none") -> Ok(NoTls)
    Ok("starttls") -> Ok(StartTls(verify: True))
    Ok("implicit") -> Ok(ImplicitTls(verify: True))
    Ok(mode) -> Error(UnsupportedTls(mode))
  })
  // A user with no password still authenticates, with an empty one.
  use #(username, password) <- result.try(
    case url.credentials(parsed.userinfo) {
      Ok(None) -> Ok(#(None, None))
      Ok(Some(#(user, password))) ->
        Ok(#(Some(user), Some(option.unwrap(password, ""))))
      Error(Nil) -> Error(InvalidUrl)
    },
  )
  Ok(
    Config(
      ..new(host),
      port: option.unwrap(parsed.port, default_port),
      username:,
      password:,
      tls:,
    ),
  )
}

fn default_tls(host: String) -> Tls {
  case url.is_local(host) {
    True -> NoTls
    False -> StartTls(verify: True)
  }
}

pub fn port(config: Config, port: Int) -> Config {
  Config(..config, port:)
}

/// Authenticate with `AUTH`. Without credentials, none is attempted.
pub fn credentials(
  config: Config,
  username username: String,
  password password: String,
) -> Config {
  Config(..config, username: Some(username), password: Some(password))
}

pub fn tls(config: Config, tls: Tls) -> Config {
  Config(..config, tls:)
}

/// How long to wait for the connection to open. Default 10 seconds. Once
/// connected, each reply from the server is waited for up to gen_smtp's
/// own limit of twenty minutes.
pub fn timeout(config: Config, milliseconds: Int) -> Config {
  Config(..config, timeout: milliseconds)
}

/// The name this host gives in `EHLO`. Defaults to its fully qualified
/// domain name.
pub fn helo(config: Config, name: String) -> Config {
  Config(..config, helo: Some(name))
}

/// How many more times to try a send whose failure was temporary: the
/// server could not be reached, timed out, or answered `4xx`. Default 0,
/// so a temporary failure comes straight back as `Unavailable`. A refusal
/// is never tried again. Every attempt happens in the calling process, so
/// a send can take up to `retries + 1` times `timeout`, plus the backoff.
pub fn retries(config: Config, count: Int) -> Config {
  Config(..config, retries: int_max(count, 0))
}

/// How long to wait before the first retry, in milliseconds; each retry
/// after it waits twice as long as the one before. Default 500.
pub fn backoff(config: Config, milliseconds: Int) -> Config {
  Config(..config, backoff: int_max(milliseconds, 0))
}

fn int_max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}

pub fn host(config: Config) -> String {
  config.host
}

pub fn port_of(config: Config) -> Int {
  config.port
}

pub fn tls_of(config: Config) -> Tls {
  config.tls
}

pub fn username(config: Config) -> Option(String) {
  config.username
}

// -- Sending -----------------------------------------------------------------

/// How gen_smtp's outcome crosses from Erlang.
type Failure {
  Temporary(String)
  Permanent(String)
}

/// What the FFI understands as the TLS mode.
type Security {
  Plain
  StartTlsMode(Bool)
  ImplicitMode(Bool)
}

@external(erlang, "howdy_mail_ffi", "smtp_send")
fn smtp_send(
  host: String,
  port: Int,
  tls: Security,
  username: Option(String),
  password: Option(String),
  timeout: Int,
  helo: Option(String),
  from: String,
  to: List(String),
  body: String,
) -> Result(String, Failure)

pub fn adapter(config: Config) -> Adapter {
  mail.adapter(named: "SMTP " <> config.host, send: fn(outgoing) {
    send(config, outgoing)
  })
}

fn send(
  config: Config,
  outgoing: Outgoing,
) -> Result(mail.Receipt, mail.Error) {
  let security = case config.tls {
    NoTls -> Plain
    StartTls(verify) -> StartTlsMode(verify)
    ImplicitTls(verify) -> ImplicitMode(verify)
  }
  let recipients =
    mail.recipients(outgoing)
    |> list.map(fn(address) { "<" <> address.email <> ">" })
    |> list.unique
  let attempt = fn() {
    smtp_send(
      config.host,
      config.port,
      security,
      config.username,
      config.password,
      config.timeout,
      config.helo,
      "<" <> outgoing.from.email <> ">",
      recipients,
      mime.encode(outgoing),
    )
  }
  case attempts(attempt, config.retries, config.backoff) {
    Ok(reply) -> Ok(mail.Receipt(outgoing.id, queued_as(reply)))
    Error(Temporary(reason)) -> Error(mail.Unavailable(reason))
    Error(Permanent(reason)) -> Error(mail.Refused(reason))
  }
}

/// Try again after a temporary failure while retries remain, waiting
/// `wait` before the next attempt and twice that before the one after.
fn attempts(
  attempt: fn() -> Result(String, Failure),
  remaining: Int,
  wait: Int,
) -> Result(String, Failure) {
  case attempt() {
    Error(Temporary(_)) if remaining > 0 -> {
      process.sleep(wait)
      attempts(attempt, remaining - 1, wait * 2)
    }
    outcome -> outcome
  }
}

/// The id in a reply like `2.0.0 Ok: queued as 4ABC123`, or the whole reply.
fn queued_as(reply: String) -> Option(String) {
  case string.split_once(reply, "queued as ") {
    Ok(#(_, id)) -> Some(string.trim(id))
    Error(Nil) ->
      case reply {
        "" -> None
        reply -> Some(reply)
      }
  }
}
