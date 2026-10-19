//// Notifications: telling someone that something happened, kept in an
//// inbox until they have read it, and pushed to every page they have open.
////
//// ```gleam
//// import howdy/notifications
////
//// let notifier = notifications.new(repo)
////
//// notifications.draft("comment.created", "Ana commented on your post")
//// |> notifications.body("Looks good to me!")
//// |> notifications.link("/posts/42#comment-7")
//// |> notifications.send(notifier, to: post.author_id)
//// ```
////
//// A notification is saved first, then announced to the recipient's open
//// pages. The saved row is what counts: a page that was closed, or lost its
//// connection, reads the inbox when it next connects, so nothing is missed.
////
//// Pages hear about notifications through `routes`, which serves the inbox
//// as JSON and as a stream of server-sent events, and `howdy/ui/bell`
//// shows them. A live view, or any other process, can `subscribe`.
////
//// Each kind of notification can also go out by email, straight away or
//// gathered into a digest, and to the browser's own notifications with
//// `howdy/notifications/web_push`. Users choose per kind with
//// `set_preference`, and the app sets the defaults with `with_defaults`.
//// Email and push are sent by a worker the app runs under its supervisor
//// (`supervised`), which retries what fails.
////
//// Recipients are user IDs as strings, such as `howdy_auth` user IDs. The
//// package does not check them against any table, so it works with any
//// account system.

import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import gloo/migration as gloo_migration
import gloo/repo.{type Repo}
import gloo/sql
import howdy/content.{type Content}
import howdy/controller.{type Context, type Controller}
import howdy/database
import howdy/mail
import howdy/migration
import howdy/param
import howdy/query
import howdy/service
import howdy/sse
import logging

// -- Notifications -----------------------------------------------------------

/// A notification as it was saved. Times are unix milliseconds.
pub type Notification {
  Notification(
    id: String,
    /// The user it is for.
    recipient: String,
    /// What happened, in the app's own terms, such as `comment.created`.
    /// Preferences are chosen per kind.
    kind: String,
    title: String,
    body: String,
    /// Where to go to see what happened.
    link: Option(String),
    /// Anything else the app wants to keep with it, such as IDs.
    data: Dict(String, String),
    created_at: Int,
    read_at: Option(Int),
  )
}

/// A notification about to be sent. Start one with `draft`.
pub opaque type Draft {
  Draft(
    kind: String,
    title: String,
    body: String,
    link: Option(String),
    data: List(#(String, String)),
  )
}

/// A notification of `kind` with `title`, its one line summary.
pub fn draft(kind: String, title: String) -> Draft {
  Draft(kind:, title:, body: "", link: None, data: [])
}

/// More detail, shown under the title.
pub fn body(draft: Draft, body: String) -> Draft {
  Draft(..draft, body:)
}

/// Where opening the notification goes, as a path such as `/posts/42`.
/// Email and push need a full URL; see `with_base_url`.
pub fn link(draft: Draft, link: String) -> Draft {
  Draft(..draft, link: Some(link))
}

/// Values to keep with the notification, such as the IDs the app needs to
/// act on it. They are sent to the browser with it.
pub fn data(draft: Draft, data: List(#(String, String))) -> Draft {
  Draft(..draft, data:)
}

pub fn to_json(notification: Notification) -> Json {
  json.object([
    #("id", json.string(notification.id)),
    #("kind", json.string(notification.kind)),
    #("title", json.string(notification.title)),
    #("body", json.string(notification.body)),
    #("link", json.nullable(notification.link, json.string)),
    #("data", json.dict(notification.data, fn(key) { key }, json.string)),
    #("created_at", json.int(notification.created_at)),
    #("read_at", json.nullable(notification.read_at, json.int)),
  ])
}

// -- Delivery preferences ----------------------------------------------------

/// How one kind of notification reaches a user.
pub type Delivery {
  Delivery(
    /// Shown in the inbox and on open pages.
    inbox: Bool,
    email: Email,
    /// Sent to the browsers the user turned on with `web_push`.
    push: Bool,
  )
}

pub type Email {
  NoEmail
  /// Emailed on its own, unless it was read in the inbox first; see
  /// `email_after`.
  EmailNow
  /// Gathered with others into one email; see `with_digest`.
  EmailDigest
}

/// What happens to a kind nobody chose for: shown in the inbox and pushed
/// to browsers that asked for it, and not emailed.
pub const default_delivery = Delivery(inbox: True, email: NoEmail, push: True)

/// Nothing at all: the notification is not even saved.
pub const muted = Delivery(inbox: False, email: NoEmail, push: False)

/// The kind a preference applies to when it is set for every kind.
pub const every_kind = "*"

// -- Setting up --------------------------------------------------------------

/// Everything sending needs. Build with `new` and the `with_` functions,
/// and keep one for the life of the app.
pub opaque type Notifier {
  Notifier(
    repo: Repo,
    defaults: fn(String) -> Delivery,
    email: Option(EmailSetup),
    digest: Option(DigestSetup),
    push: Option(fn(Notification) -> Outcome),
    base_url: String,
    email_after: Int,
    interval: Int,
    worker: Name(WorkerMessage),
    clock: fn() -> Int,
  )
}

type EmailSetup {
  EmailSetup(
    mailer: mail.Mailer,
    address: fn(String) -> Result(mail.Address, Nil),
    render: fn(Notification) -> mail.Message,
  )
}

type DigestSetup {
  DigestSetup(every: Int, render: fn(List(Notification)) -> mail.Message)
}

/// What became of one attempt to deliver a notification by email or push.
pub type Outcome {
  Delivered
  /// It may work later, such as when the provider is down. It is tried
  /// again with a growing delay, five times in all.
  Retry(reason: String)
  /// It never will, such as when the user has no email address.
  GiveUp(reason: String)
}

/// Notifications kept in `repo`, which must have had `schema` applied.
pub fn new(repo: Repo) -> Notifier {
  Notifier(
    repo:,
    defaults: fn(_) { default_delivery },
    email: None,
    digest: None,
    push: None,
    base_url: "",
    email_after: 0,
    interval: 10_000,
    worker: process.new_name("howdy_notifications"),
    clock: now_ms,
  )
}

/// The migrations for the package's tables, all named `howdy_notifications_`.
pub fn schema() -> migration.Package {
  migration.Package("howdy_notifications", [
    gloo_migration.new(
      1,
      "create_notifications",
      "CREATE TABLE howdy_notifications_items (
         id TEXT PRIMARY KEY,
         user_id TEXT NOT NULL,
         kind TEXT NOT NULL,
         title TEXT NOT NULL,
         body TEXT NOT NULL,
         link TEXT,
         data TEXT NOT NULL,
         inbox INTEGER NOT NULL,
         created_at BIGINT NOT NULL,
         read_at BIGINT,
         email TEXT NOT NULL,
         email_due BIGINT,
         email_attempts INTEGER NOT NULL DEFAULT 0,
         push TEXT NOT NULL,
         push_due BIGINT,
         push_attempts INTEGER NOT NULL DEFAULT 0
       );
       CREATE INDEX howdy_notifications_items_user
         ON howdy_notifications_items (user_id, created_at);
       CREATE INDEX howdy_notifications_items_email
         ON howdy_notifications_items (email, email_due);
       CREATE INDEX howdy_notifications_items_push
         ON howdy_notifications_items (push, push_due);
       CREATE TABLE howdy_notifications_preferences (
         user_id TEXT NOT NULL,
         kind TEXT NOT NULL,
         inbox INTEGER NOT NULL,
         email TEXT NOT NULL,
         push INTEGER NOT NULL,
         PRIMARY KEY (user_id, kind)
       );
       CREATE TABLE howdy_notifications_digests (
         user_id TEXT PRIMARY KEY,
         sent_at BIGINT NOT NULL
       );
       CREATE TABLE howdy_notifications_push_subscriptions (
         endpoint TEXT PRIMARY KEY,
         user_id TEXT NOT NULL,
         p256dh TEXT NOT NULL,
         auth TEXT NOT NULL,
         created_at BIGINT NOT NULL
       );
       CREATE INDEX howdy_notifications_push_subscriptions_user
         ON howdy_notifications_push_subscriptions (user_id)",
    ),
  ])
}

/// How each kind is delivered when the user has not chosen. Kinds the
/// function does not know should get `default_delivery`.
///
/// ```gleam
/// notifications.with_defaults(notifier, fn(kind) {
///   case kind {
///     "security." <> _ -> Delivery(..default_delivery, email: EmailNow)
///     "comment.created" -> Delivery(..default_delivery, email: EmailDigest)
///     _ -> default_delivery
///   }
/// })
/// ```
pub fn with_defaults(
  notifier: Notifier,
  defaults: fn(String) -> Delivery,
) -> Notifier {
  Notifier(..notifier, defaults:)
}

/// Send email for the kinds whose delivery asks for it. `address` finds a
/// user's address, and `render` writes the email for one notification:
/// its subject and body, but not its recipient, which is filled in.
///
/// ```gleam
/// notifications.with_email(notifier, mailer,
///   address: fn(user_id) { users.email_address(user_id) },
///   render: fn(n) {
///     mail.message()
///     |> mail.subject(n.title)
///     |> mail.text(n.body <> "\n\n" <> notifications.url(notifier, n))
///   },
/// )
/// ```
pub fn with_email(
  notifier: Notifier,
  mailer: mail.Mailer,
  address address: fn(String) -> Result(mail.Address, Nil),
  render render: fn(Notification) -> mail.Message,
) -> Notifier {
  Notifier(..notifier, email: Some(EmailSetup(mailer:, address:, render:)))
}

/// Gather `EmailDigest` notifications into one email per user at most
/// every `every_seconds`, such as `86_400` for a daily digest. `render`
/// writes it from the user's unread notifications, oldest first; those
/// read in the meantime are left out. Needs `with_email`.
///
/// Without a digest, `EmailDigest` notifications are emailed one by one.
pub fn with_digest(
  notifier: Notifier,
  every every_seconds: Int,
  render render: fn(List(Notification)) -> mail.Message,
) -> Notifier {
  Notifier(
    ..notifier,
    digest: Some(DigestSetup(every: every_seconds * 1000, render:)),
  )
}

/// Wait this long before emailing a notification, and skip the email if it
/// is read in the inbox meanwhile. Someone who is already looking at the
/// app does not need an email too. Defaults to zero.
pub fn email_after(notifier: Notifier, seconds: Int) -> Notifier {
  Notifier(..notifier, email_after: seconds * 1000)
}

/// Deliver push notifications with `deliver`, such as the one
/// `web_push.deliver` makes.
pub fn with_push(
  notifier: Notifier,
  deliver: fn(Notification) -> Outcome,
) -> Notifier {
  Notifier(..notifier, push: Some(deliver))
}

/// The address the app is served from, such as `https://example.com`, so
/// email and push can link to it. See `url`.
pub fn with_base_url(notifier: Notifier, base_url: String) -> Notifier {
  let base_url = case string.ends_with(base_url, "/") {
    True -> string.drop_end(base_url, 1)
    False -> base_url
  }
  Notifier(..notifier, base_url:)
}

/// How often the worker looks for email and push that is due, in
/// milliseconds. It also looks straight away whenever a notification is
/// sent from this node. Defaults to ten seconds.
pub fn check_every(notifier: Notifier, milliseconds: Int) -> Notifier {
  Notifier(..notifier, interval: int.max(milliseconds, 100))
}

/// The full URL of a notification's link, using `with_base_url`; the base
/// URL itself when it has none. A link that is already a full URL is kept.
pub fn url(notifier: Notifier, notification: Notification) -> String {
  case notification.link {
    Some("http://" <> _ as link) | Some("https://" <> _ as link) -> link
    Some(link) -> notifier.base_url <> link
    None -> notifier.base_url <> "/"
  }
}

pub fn repo(notifier: Notifier) -> Repo {
  notifier.repo
}

/// Use another clock, in unix milliseconds, for tests.
@internal
pub fn with_clock(notifier: Notifier, clock: fn() -> Int) -> Notifier {
  Notifier(..notifier, clock:)
}

// -- Sending -----------------------------------------------------------------

/// Save a notification for `recipient`, announce it to their open pages,
/// and queue whatever email and push their preferences ask for. Gives
/// `None` when they have muted the kind.
///
/// Call it after the change it is about has been committed, not inside the
/// transaction making it: the announcement cannot be taken back.
pub fn send(
  draft: Draft,
  notifier: Notifier,
  to recipient: String,
) -> service.Result(Option(Notification)) {
  use delivery <- result.try(preference(notifier, recipient, draft.kind))
  case delivery {
    Delivery(inbox: False, email: NoEmail, push: False) -> Ok(None)
    _ -> {
      let now = notifier.clock()
      let notification =
        Notification(
          id: new_id(),
          recipient:,
          kind: draft.kind,
          title: draft.title,
          body: draft.body,
          link: draft.link,
          data: dict.from_list(draft.data),
          created_at: now,
          read_at: None,
        )
      let #(email, email_due) = case delivery.email, notifier.email {
        _, None | NoEmail, _ -> #("none", None)
        EmailNow, Some(_) -> #("now", Some(now + notifier.email_after))
        EmailDigest, Some(_) ->
          case notifier.digest {
            Some(_) -> #("digest", None)
            None -> #("now", Some(now + notifier.email_after))
          }
      }
      let #(push, push_due) = case delivery.push, notifier.push {
        True, Some(_) -> #("pending", Some(now))
        _, _ -> #("none", None)
      }
      // Gloo binds SQLite parameters by position and handles at most nine,
      // so the numbers and fixed words go in the statement itself.
      use _ <- result.try(
        database.execute(
          notifier.repo,
          "INSERT INTO howdy_notifications_items (id, user_id, kind, title, body,
           link, data, inbox, created_at, email, email_due, push, push_due)
         VALUES ($1, $2, $3, $4, $5, $6, $7, "
            <> int.to_string(flag(delivery.inbox))
            <> ", "
            <> int.to_string(now)
            <> ", '"
            <> email
            <> "', "
            <> nullable_int(email_due)
            <> ", '"
            <> push
            <> "', "
            <> nullable_int(push_due)
            <> ")",
          [
            sql.string(notification.id),
            sql.string(recipient),
            sql.string(notification.kind),
            sql.string(notification.title),
            sql.string(notification.body),
            sql.nullable(sql.string, notification.link),
            sql.string(encode_data(draft.data)),
          ],
        ),
      )
      case delivery.inbox {
        True -> {
          announce(recipient, Received(notification))
          announce_unread(notifier, recipient)
        }
        False -> Nil
      }
      case email != "none" || push != "none" {
        True -> wake(notifier)
        False -> Nil
      }
      Ok(Some(notification))
    }
  }
}

/// Send the same notification to each recipient, one at a time, stopping
/// at the first error.
pub fn send_to_each(
  draft: Draft,
  notifier: Notifier,
  recipients: List(String),
) -> service.Result(List(Notification)) {
  list.try_map(recipients, fn(recipient) { send(draft, notifier, recipient) })
  |> result.map(option.values)
}

// -- The inbox ---------------------------------------------------------------

/// Which part of the inbox to read. Build with `page`.
pub opaque type Page {
  Page(limit: Int, before: Option(String), unread_only: Bool)
}

/// The newest twenty notifications.
pub fn page() -> Page {
  Page(limit: 20, before: None, unread_only: False)
}

/// At most `limit` notifications, between 1 and 100.
pub fn limit(page: Page, limit: Int) -> Page {
  Page(..page, limit: int.clamp(limit, 1, 100))
}

/// Those older than the notification with this ID, for the next page.
pub fn before(page: Page, id: String) -> Page {
  Page(..page, before: Some(id))
}

/// Only unread notifications.
pub fn unread_only(page: Page) -> Page {
  Page(..page, unread_only: True)
}

/// A user's inbox, newest first.
pub fn list(
  notifier: Notifier,
  recipient: String,
  page: Page,
) -> service.Result(List(Notification)) {
  // Gloo binds SQLite parameters by position: each appears once, in order.
  let #(cursor, cursor_args) = case page.before {
    None -> #("", [])
    Some(id) -> #(
      " AND (created_at, id) < (SELECT created_at, id
          FROM howdy_notifications_items WHERE id = $2 AND user_id = $3)",
      [sql.string(id), sql.string(recipient)],
    )
  }
  let unread = case page.unread_only {
    True -> " AND read_at IS NULL"
    False -> ""
  }
  database.query(
    notifier.repo,
    "SELECT " <> columns <> " FROM howdy_notifications_items
     WHERE user_id = $1 AND inbox = 1" <> unread <> cursor <> "
     ORDER BY created_at DESC, id DESC LIMIT " <> int.to_string(page.limit),
    [sql.string(recipient), ..cursor_args],
    notification_decoder(),
  )
}

/// One of a user's notifications.
pub fn get(
  notifier: Notifier,
  recipient: String,
  id: String,
) -> service.Result(Notification) {
  database.one(
    notifier.repo,
    "SELECT " <> columns <> " FROM howdy_notifications_items
     WHERE id = $1 AND user_id = $2 AND inbox = 1",
    [sql.string(id), sql.string(recipient)],
    notification_decoder(),
    or: service.NotFound("notification not found"),
  )
}

/// How many notifications in the inbox are unread.
pub fn unread_count(
  notifier: Notifier,
  recipient: String,
) -> service.Result(Int) {
  database.one(
    notifier.repo,
    "SELECT COUNT(*) FROM howdy_notifications_items
     WHERE user_id = $1 AND inbox = 1 AND read_at IS NULL",
    [sql.string(recipient)],
    decode.field(0, decode.int, decode.success),
    or: service.Internal("notification count returned no row"),
  )
}

/// Mark one notification read. Reading one already read changes nothing.
pub fn mark_read(
  notifier: Notifier,
  recipient: String,
  id: String,
) -> service.Result(Nil) {
  use _ <- result.try(get(notifier, recipient, id))
  use _ <- result.try(
    database.execute(
      notifier.repo,
      "UPDATE howdy_notifications_items SET read_at = $1
     WHERE id = $2 AND user_id = $3 AND read_at IS NULL",
      [sql.int(notifier.clock()), sql.string(id), sql.string(recipient)],
    ),
  )
  announce_unread(notifier, recipient)
  Ok(Nil)
}

/// Mark one notification unread again.
pub fn mark_unread(
  notifier: Notifier,
  recipient: String,
  id: String,
) -> service.Result(Nil) {
  use _ <- result.try(get(notifier, recipient, id))
  use _ <- result.try(
    database.execute(
      notifier.repo,
      "UPDATE howdy_notifications_items SET read_at = NULL
     WHERE id = $1 AND user_id = $2",
      [sql.string(id), sql.string(recipient)],
    ),
  )
  announce_unread(notifier, recipient)
  Ok(Nil)
}

/// Mark every notification in a user's inbox read.
pub fn mark_all_read(
  notifier: Notifier,
  recipient: String,
) -> service.Result(Nil) {
  use _ <- result.try(
    database.execute(
      notifier.repo,
      "UPDATE howdy_notifications_items SET read_at = $1
     WHERE user_id = $2 AND read_at IS NULL",
      [sql.int(notifier.clock()), sql.string(recipient)],
    ),
  )
  announce_unread(notifier, recipient)
  Ok(Nil)
}

/// Remove a notification from a user's inbox for good.
pub fn delete(
  notifier: Notifier,
  recipient: String,
  id: String,
) -> service.Result(Nil) {
  use _ <- result.try(get(notifier, recipient, id))
  use _ <- result.try(
    database.execute(
      notifier.repo,
      "DELETE FROM howdy_notifications_items WHERE id = $1 AND user_id = $2",
      [sql.string(id), sql.string(recipient)],
    ),
  )
  announce_unread(notifier, recipient)
  Ok(Nil)
}

/// Remove everything kept for a user: notifications, preferences and push
/// subscriptions. `conn` may be a transaction, such as the one
/// `auth.with_account_deletion` gives, so it all goes with the account.
pub fn delete_user(conn: Repo, recipient: String) -> service.Result(Nil) {
  list.try_each(
    [
      "howdy_notifications_items", "howdy_notifications_preferences",
      "howdy_notifications_digests", "howdy_notifications_push_subscriptions",
    ],
    fn(table) {
      database.execute(conn, "DELETE FROM " <> table <> " WHERE user_id = $1", [
        sql.string(recipient),
      ])
    },
  )
}

/// Delete notifications that were read before `before`, in unix
/// milliseconds, so the table does not grow for ever. Unread ones are kept.
/// Call it now and then, such as daily.
pub fn prune(
  notifier: Notifier,
  read_before before: Int,
) -> service.Result(Nil) {
  database.execute(
    notifier.repo,
    "DELETE FROM howdy_notifications_items
     WHERE read_at IS NOT NULL AND read_at < $1
       AND email NOT IN ('now', 'digest') AND push <> 'pending'",
    [sql.int(before)],
  )
}

const columns = "id, user_id, kind, title, body, link, data, created_at, read_at"

fn notification_decoder() -> decode.Decoder(Notification) {
  use id <- decode.field(0, decode.string)
  use recipient <- decode.field(1, decode.string)
  use kind <- decode.field(2, decode.string)
  use title <- decode.field(3, decode.string)
  use body <- decode.field(4, decode.string)
  use link <- decode.field(5, decode.optional(decode.string))
  use data <- decode.field(6, decode.string)
  use created_at <- decode.field(7, decode.int)
  use read_at <- decode.field(8, decode.optional(decode.int))
  decode.success(Notification(
    id:,
    recipient:,
    kind:,
    title:,
    body:,
    link:,
    data: decode_data(data),
    created_at:,
    read_at:,
  ))
}

fn encode_data(data: List(#(String, String))) -> String {
  json.object(list.map(data, fn(pair) { #(pair.0, json.string(pair.1)) }))
  |> json.to_string
}

fn decode_data(data: String) -> Dict(String, String) {
  json.parse(data, decode.dict(decode.string, decode.string))
  |> result.unwrap(dict.new())
}

fn nullable_int(value: Option(Int)) -> String {
  case value {
    Some(value) -> int.to_string(value)
    None -> "NULL"
  }
}

fn flag(on: Bool) -> Int {
  case on {
    True -> 1
    False -> 0
  }
}

fn new_id() -> String {
  bit_array.base64_url_encode(crypto.strong_random_bytes(16), False)
}

// -- Preferences -------------------------------------------------------------

/// How `kind` reaches `recipient`: their choice for the kind, else their
/// choice for `every_kind`, else the app's default.
pub fn preference(
  notifier: Notifier,
  recipient: String,
  kind: String,
) -> service.Result(Delivery) {
  use chosen <- result.map(database.query(
    notifier.repo,
    "SELECT kind, inbox, email, push FROM howdy_notifications_preferences
     WHERE user_id = $1 AND kind IN ($2, $3)",
    [sql.string(recipient), sql.string(kind), sql.string(every_kind)],
    preference_decoder(),
  ))
  case list.key_find(chosen, kind), list.key_find(chosen, every_kind) {
    Ok(delivery), _ | Error(Nil), Ok(delivery) -> delivery
    Error(Nil), Error(Nil) -> notifier.defaults(kind)
  }
}

/// The choices a user has made, by kind, `every_kind` included.
pub fn preferences(
  notifier: Notifier,
  recipient: String,
) -> service.Result(List(#(String, Delivery))) {
  database.query(
    notifier.repo,
    "SELECT kind, inbox, email, push FROM howdy_notifications_preferences
     WHERE user_id = $1 ORDER BY kind",
    [sql.string(recipient)],
    preference_decoder(),
  )
}

/// Choose how `kind`, or `every_kind`, reaches a user. Use `muted` to stop
/// it altogether.
pub fn set_preference(
  notifier: Notifier,
  recipient: String,
  kind: String,
  delivery: Delivery,
) -> service.Result(Nil) {
  use <- bool.guard(
    kind == "" || string.length(kind) > 200,
    Error(service.Invalid("a kind is 1 to 200 characters")),
  )
  use conn <- database.write_transaction(
    notifier.repo,
    touching: "howdy_notifications_preferences",
  )
  use _ <- result.try(
    database.execute(
      conn,
      "DELETE FROM howdy_notifications_preferences
     WHERE user_id = $1 AND kind = $2",
      [sql.string(recipient), sql.string(kind)],
    ),
  )
  database.execute(
    conn,
    "INSERT INTO howdy_notifications_preferences
       (user_id, kind, inbox, email, push) VALUES ($1, $2, $3, $4, $5)",
    [
      sql.string(recipient),
      sql.string(kind),
      sql.int(flag(delivery.inbox)),
      sql.string(email_code(delivery.email)),
      sql.int(flag(delivery.push)),
    ],
  )
}

/// Forget a user's choice for `kind`, so the default applies again.
pub fn clear_preference(
  notifier: Notifier,
  recipient: String,
  kind: String,
) -> service.Result(Nil) {
  database.execute(
    notifier.repo,
    "DELETE FROM howdy_notifications_preferences
     WHERE user_id = $1 AND kind = $2",
    [sql.string(recipient), sql.string(kind)],
  )
}

fn preference_decoder() -> decode.Decoder(#(String, Delivery)) {
  use kind <- decode.field(0, decode.string)
  use inbox <- decode.field(1, decode.int)
  use email <- decode.field(2, decode.string)
  use push <- decode.field(3, decode.int)
  let email = case email {
    "now" -> EmailNow
    "digest" -> EmailDigest
    _ -> NoEmail
  }
  decode.success(#(kind, Delivery(inbox: inbox == 1, email:, push: push == 1)))
}

fn email_code(email: Email) -> String {
  case email {
    NoEmail -> "none"
    EmailNow -> "now"
    EmailDigest -> "digest"
  }
}

// -- Live --------------------------------------------------------------------

/// What a subscriber hears about a user's inbox.
pub type Event {
  /// A new notification arrived.
  Received(Notification)
  /// The number of unread notifications changed, because one arrived or
  /// was read, marked unread or deleted, on this page or any other.
  Unread(count: Int)
}

/// A subscription made with `subscribe`.
pub opaque type Subscription {
  Subscription(relay: Pid)
}

/// Hear about `recipient`'s inbox on `subject`, from any node in the
/// cluster, until the process that owns the subject exits or `unsubscribe`
/// is called. Nothing announced after this returns is missed.
///
/// In a live view, subscribe from an effect:
///
/// ```gleam
/// server_component.select(fn(_dispatch, subject) {
///   notifications.subscribe(user_id, subject)
///   process.new_selector() |> process.select_map(subject, Notified)
/// })
/// ```
pub fn subscribe(recipient: String, subject: Subject(Event)) -> Subscription {
  let assert Ok(owner) = process.subject_owner(subject)
    as "howdy/notifications: the subject has no owner"
  Subscription(
    relay_events(recipient, owner, fn(event) { process.send(subject, event) }),
  )
}

pub fn unsubscribe(subscription: Subscription) -> Nil {
  stop_relay(subscription.relay)
}

/// How many subscriptions a user has, across the cluster.
pub fn subscribers(recipient: String) -> Int {
  count_subscribers(recipient)
}

/// Tell a user's subscribers something, from any node. `send` does this
/// itself; this is for events of the app's own making, such as an unread
/// count changed by a bulk update.
pub fn announce(recipient: String, event: Event) -> Nil {
  broadcast(recipient, event)
}

fn announce_unread(notifier: Notifier, recipient: String) -> Nil {
  case subscribers(recipient) > 0 {
    False -> Nil
    True ->
      case unread_count(notifier, recipient) {
        Ok(count) -> announce(recipient, Unread(count))
        Error(_) -> Nil
      }
  }
}

/// A server-sent event stream of `recipient`'s inbox. It opens with an
/// `unread` event giving the count, then sends a `notification` event for
/// each that arrives and an `unread` event whenever the count changes:
///
/// ```text
/// event: notification
/// data: {"id": "…", "title": "Ana commented on your post", …}
///
/// event: unread
/// data: {"count": 3}
/// ```
///
/// `recipient` must be the signed-in user; take it from the session, never
/// from the request.
pub fn stream(
  ctx: Context,
  notifier: Notifier,
  recipient: String,
) -> Response(Content) {
  sse.new(fn(stream) {
    subscribe(recipient, sse.subject(stream))
    case unread_count(notifier, recipient) {
      Ok(count) -> {
        let _ = sse.send(stream, event_to_sse(Unread(count)))
        Nil
      }
      Error(_) -> Nil
    }
  })
  |> sse.on_message(fn(stream, state, event) {
    case sse.send(stream, event_to_sse(event)) {
      Ok(Nil) -> sse.continue(state)
      Error(_) -> sse.stop()
    }
  })
  |> sse.start(ctx)
}

fn event_to_sse(event: Event) -> sse.Event {
  case event {
    Received(notification) ->
      sse.json(to_json(notification)) |> sse.name("notification")
    Unread(count) ->
      sse.json(json.object([#("count", json.int(count))]))
      |> sse.name("unread")
  }
}

// -- Routes ------------------------------------------------------------------

/// The inbox over HTTP, for `howdy/ui/bell` or a page of your own.
/// `identify` names the signed-in user, or refuses the request:
///
/// ```gleam
/// notifications.routes(notifier, at: "/notifications", identify: fn(ctx) {
///   auth.required(auth)(ctx) |> result.map(fn(principal) { principal.user.id })
/// })
/// ```
///
/// Writes come from the user's own browser with their cookie, so `identify`
/// must refuse cross-site requests, as `auth.required` does, or the app
/// must use `howdy/csrf`.
///
/// - `GET /` lists the inbox as `{"notifications": [...], "unread": 3}`.
///   It takes `limit`, `before` (an ID, for the next page) and `unread=true`
///   in the query.
/// - `GET /events` is the `stream` of the inbox.
/// - `POST /read` marks every notification read.
/// - `POST /:id/read` and `POST /:id/unread` mark one.
/// - `DELETE /:id` deletes one.
///
/// Writes answer `{"unread": 2}` with the new count. A plain HTML form can
/// post to them too: give the action a `next` query parameter, a path
/// such as `?next=/inbox`, and the answer is a redirect there instead.
pub fn routes(
  notifier: Notifier,
  at prefix: String,
  identify identify: fn(Context) -> service.Result(String),
) -> Controller {
  let user = fn(ctx, next) {
    case identify(ctx) {
      Ok(recipient) -> next(recipient)
      Error(error) -> service.error_response(ctx, error)
    }
  }
  controller.new(prefix)
  |> controller.get("/", fn(ctx) {
    use recipient <- user(ctx)
    use count <- query.int_or(ctx, "limit", default: 20)
    use cursor <- query.optional_string(ctx, "before")
    use unread <- query.bool_or(ctx, "unread", default: False)
    let page = page() |> limit(count)
    let page = case cursor {
      Some(id) -> before(page, id)
      None -> page
    }
    let page = case unread {
      True -> unread_only(page)
      False -> page
    }
    {
      use notifications <- result.try(list(notifier, recipient, page))
      use unread <- result.map(unread_count(notifier, recipient))
      #(notifications, unread)
    }
    |> service.respond(ctx, fn(found) {
      json.object([
        #("notifications", json.array(found.0, to_json)),
        #("unread", json.int(found.1)),
      ])
    })
  })
  |> controller.get("/events", fn(ctx) {
    use recipient <- user(ctx)
    stream(ctx, notifier, recipient)
  })
  |> controller.post("/read", fn(ctx) {
    use recipient <- user(ctx)
    changed(ctx, notifier, recipient, mark_all_read(notifier, recipient))
  })
  |> controller.post("/:id/read", fn(ctx) {
    use recipient <- user(ctx)
    use id <- param.string(ctx, "id")
    changed(ctx, notifier, recipient, mark_read(notifier, recipient, id))
  })
  |> controller.post("/:id/unread", fn(ctx) {
    use recipient <- user(ctx)
    use id <- param.string(ctx, "id")
    changed(ctx, notifier, recipient, mark_unread(notifier, recipient, id))
  })
  |> controller.delete("/:id", fn(ctx) {
    use recipient <- user(ctx)
    use id <- param.string(ctx, "id")
    changed(ctx, notifier, recipient, delete(notifier, recipient, id))
  })
}

/// Answer a write with the new unread count, or redirect to `next`.
fn changed(
  ctx: Context,
  notifier: Notifier,
  recipient: String,
  outcome: service.Result(Nil),
) -> Response(Content) {
  let next =
    request.get_query(ctx.request)
    |> result.unwrap([])
    |> list.key_find("next")
  case outcome, next {
    Ok(Nil), Ok(next) ->
      case local_path(next) {
        True ->
          response.new(303)
          |> response.set_header("location", next)
          |> response.set_body(content.Empty)
        False -> service.error_response(ctx, service.Invalid("bad next path"))
      }
    _, _ ->
      outcome
      |> result.try(fn(_) { unread_count(notifier, recipient) })
      |> service.respond(ctx, fn(count) {
        json.object([#("unread", json.int(count))])
      })
  }
}

/// A path on this site: one leading `/`, not `//` or `/\`, which browsers
/// treat as another host.
fn local_path(path: String) -> Bool {
  case path {
    "//" <> _ | "/\\" <> _ -> False
    "/" <> _ -> !string.contains(path, "\n") && !string.contains(path, "\r")
    _ -> False
  }
}

// -- The worker --------------------------------------------------------------

type WorkerMessage {
  Tick
  Wake
  Stop
}

type Worker {
  Worker(notifier: Notifier, self: Subject(WorkerMessage), awake: Bool)
}

/// The worker that sends email and push, as a child of the app's
/// supervisor. Run one on each node: they share the work through the
/// database without sending anything twice, unless a node dies mid-send.
///
/// ```gleam
/// supervisor.new(supervisor.OneForOne)
/// |> supervisor.add(notifications.supervised(notifier))
/// |> supervisor.add(howdy.supervised(app(notifier)))
/// ```
pub fn supervised(notifier: Notifier) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() { start(notifier) })
}

/// Start the worker linked to the caller. Prefer `supervised`.
pub fn start(notifier: Notifier) -> actor.StartResult(Nil) {
  actor.new_with_initialiser(1000, fn(subject) {
    process.send_after(subject, notifier.interval, Tick)
    let selector = process.new_selector() |> process.select(subject)
    actor.initialised(Worker(notifier:, self: subject, awake: False))
    |> actor.selecting(selector)
    |> actor.returning(Nil)
    |> Ok
  })
  |> actor.named(notifier.worker)
  |> actor.on_message(work)
  |> actor.start
}

/// Stop the worker started for this notifier on this node, if any.
pub fn stop(notifier: Notifier) -> Nil {
  case process.named(notifier.worker) {
    Ok(_) -> process.send(process.named_subject(notifier.worker), Stop)
    Error(Nil) -> Nil
  }
}

fn wake(notifier: Notifier) -> Nil {
  case process.named(notifier.worker) {
    Ok(_) -> process.send(process.named_subject(notifier.worker), Wake)
    Error(Nil) -> Nil
  }
}

fn work(
  worker: Worker,
  message: WorkerMessage,
) -> actor.Next(Worker, WorkerMessage) {
  case message {
    Stop -> actor.stop()
    // Sends often come in bursts; one pass a moment later covers them all.
    Wake if worker.awake -> actor.continue(worker)
    Wake -> {
      process.send_after(worker.self, 20, Tick)
      actor.continue(Worker(..worker, awake: True))
    }
    Tick -> {
      case deliver_due(worker.notifier) {
        Ok(_) -> Nil
        Error(error) ->
          logging.log(
            logging.Warning,
            "howdy/notifications: delivery pass failed: "
              <> service.message(error),
          )
      }
      case worker.awake {
        True -> Nil
        False -> {
          process.send_after(worker.self, worker.notifier.interval, Tick)
          Nil
        }
      }
      actor.continue(Worker(..worker, awake: False))
    }
  }
}

/// What one pass of `deliver_due` did.
pub type Report {
  Report(emails: Int, digests: Int, pushes: Int, failed: Int)
}

/// Send every email, digest and push that is due now, and return what was
/// done. The worker calls this; call it yourself to deliver without one,
/// such as from a scheduled job, or in tests.
pub fn deliver_due(notifier: Notifier) -> service.Result(Report) {
  let report = Report(0, 0, 0, 0)
  use report <- result.try(deliver_emails(notifier, report))
  use report <- result.try(deliver_digests(notifier, report))
  deliver_pushes(notifier, report)
}

const batch = 50

const lease = 120_000

const attempts = 5

/// Claim up to a batch of rows whose `state` column is `waiting` and whose
/// `due` column has passed, by moving their due time a lease into the
/// future, so another node's worker leaves them alone while they are sent.
fn claim(
  notifier: Notifier,
  state: String,
  waiting: String,
  due: String,
  tried: String,
) -> service.Result(List(#(Notification, Int))) {
  let now = notifier.clock()
  use conn <- database.write_transaction(
    notifier.repo,
    touching: "howdy_notifications_items",
  )
  use claimed <- result.try(
    database.query(
      conn,
      "SELECT "
        <> columns
        <> ", "
        <> tried
        <> " FROM howdy_notifications_items n
     WHERE "
        <> state
        <> " = $1 AND "
        <> due
        <> " <= $2
     ORDER BY "
        <> due
        <> " LIMIT $3"
        <> database.for_update(conn, "n"),
      [sql.string(waiting), sql.int(now), sql.int(batch)],
      {
        use notification <- decode.then(notification_decoder())
        use tried <- decode.field(9, decode.int)
        decode.success(#(notification, tried))
      },
    ),
  )
  use _ <- result.map(
    list.try_each(claimed, fn(row) {
      database.execute(
        conn,
        "UPDATE howdy_notifications_items SET "
          <> due
          <> " = $1, "
          <> tried
          <> " = $2
         WHERE id = $3",
        [sql.int(now + lease), sql.int(row.1 + 1), sql.string({ row.0 }.id)],
      )
    }),
  )
  list.map(claimed, fn(row) { #(row.0, row.1 + 1) })
}

/// Record what became of an attempt: done, tried again after a delay that
/// doubles each time, or given up.
fn settle(
  notifier: Notifier,
  notification: Notification,
  tried: Int,
  outcome: Outcome,
  state: String,
  done: String,
  due: String,
) -> service.Result(Bool) {
  let #(set, args, ok) = case outcome {
    Delivered -> #(
      state <> " = $1, " <> due <> " = NULL",
      [sql.string(done)],
      True,
    )
    Retry(reason) if tried < attempts -> {
      log_failure(notification, state, reason)
      let delay = 30_000 * int.bitwise_shift_left(1, tried - 1)
      #(due <> " = $1", [sql.int(notifier.clock() + delay)], False)
    }
    Retry(reason) | GiveUp(reason) -> {
      log_failure(notification, state, reason)
      #(state <> " = $1, " <> due <> " = NULL", [sql.string("failed")], False)
    }
  }
  database.execute(
    notifier.repo,
    "UPDATE howdy_notifications_items SET " <> set <> " WHERE id = $2",
    list.append(args, [sql.string(notification.id)]),
  )
  |> result.replace(ok)
}

fn log_failure(notification: Notification, channel: String, reason: String) {
  logging.log(
    logging.Warning,
    "howdy/notifications: "
      <> channel
      <> " for notification "
      <> notification.id
      <> " failed: "
      <> reason,
  )
}

fn deliver_emails(
  notifier: Notifier,
  report: Report,
) -> service.Result(Report) {
  case notifier.email {
    None -> Ok(report)
    Some(setup) -> {
      use claimed <- result.try(claim(
        notifier,
        "email",
        "now",
        "email_due",
        "email_attempts",
      ))
      list.try_fold(claimed, report, fn(report, row) {
        let #(notification, tried) = row
        case read_since(notifier, notification) {
          // Read in the inbox before the email went: no need to send it.
          True ->
            database.execute(
              notifier.repo,
              "UPDATE howdy_notifications_items
               SET email = 'skipped', email_due = NULL WHERE id = $1",
              [sql.string(notification.id)],
            )
            |> result.replace(report)
          False -> {
            let outcome =
              guarded(fn() {
                email(setup, notification.recipient, setup.render(notification))
              })
            use ok <- result.map(settle(
              notifier,
              notification,
              tried,
              outcome,
              "email",
              "sent",
              "email_due",
            ))
            case ok {
              True -> Report(..report, emails: report.emails + 1)
              False -> Report(..report, failed: report.failed + 1)
            }
          }
        }
      })
    }
  }
}

/// Whether a claimed notification has been read since it was claimed:
/// `claim` reads it inside the lock, but the inbox can change meanwhile.
fn read_since(notifier: Notifier, notification: Notification) -> Bool {
  case notification.read_at {
    Some(_) -> True
    None ->
      case get(notifier, notification.recipient, notification.id) {
        Ok(Notification(read_at: Some(_), ..)) -> True
        _ -> False
      }
  }
}

fn email(
  setup: EmailSetup,
  recipient: String,
  message: mail.Message,
) -> Outcome {
  case setup.address(recipient) {
    Error(Nil) -> GiveUp("the user has no email address")
    Ok(address) ->
      case mail.send(setup.mailer, mail.to(message, [address])) {
        Ok(_) -> Delivered
        Error(error) ->
          case mail.retryable(error) {
            True -> Retry(mail.error_to_string(error))
            False -> GiveUp(mail.error_to_string(error))
          }
      }
  }
}

fn deliver_pushes(
  notifier: Notifier,
  report: Report,
) -> service.Result(Report) {
  case notifier.push {
    None -> Ok(report)
    Some(deliver) -> {
      use claimed <- result.try(claim(
        notifier,
        "push",
        "pending",
        "push_due",
        "push_attempts",
      ))
      list.try_fold(claimed, report, fn(report, row) {
        let #(notification, tried) = row
        use ok <- result.map(settle(
          notifier,
          notification,
          tried,
          guarded(fn() { deliver(notification) }),
          "push",
          "sent",
          "push_due",
        ))
        case ok {
          True -> Report(..report, pushes: report.pushes + 1)
          False -> Report(..report, failed: report.failed + 1)
        }
      })
    }
  }
}

/// One email per user with digest notifications waiting, if their last
/// digest went at least the digest's interval ago. Notifications read
/// meanwhile are skipped, and a user with only read ones gets no email.
fn deliver_digests(
  notifier: Notifier,
  report: Report,
) -> service.Result(Report) {
  case notifier.email, notifier.digest {
    Some(setup), Some(digest) -> {
      let now = notifier.clock()
      use waiting <- result.try(database.query(
        notifier.repo,
        "SELECT DISTINCT n.user_id FROM howdy_notifications_items n
         LEFT JOIN howdy_notifications_digests d ON d.user_id = n.user_id
         WHERE n.email = 'digest' AND (d.sent_at IS NULL OR d.sent_at <= $1)
         LIMIT $2",
        [sql.int(now - digest.every), sql.int(batch)],
        decode.field(0, decode.string, decode.success),
      ))
      list.try_fold(waiting, report, fn(report, recipient) {
        use claimed <- result.try(claim_digest(notifier, digest, recipient, now))
        case claimed {
          None -> Ok(report)
          Some(#(_, [])) -> Ok(report)
          Some(#(previous, notifications)) -> {
            let outcome =
              guarded(fn() {
                email(setup, recipient, digest.render(notifications))
              })
            let ids = list.map(notifications, fn(n) { n.id })
            case outcome {
              Delivered ->
                set_digest_state(notifier, ids, "sent")
                |> result.replace(Report(..report, digests: report.digests + 1))
              Retry(reason) -> {
                // Put the last digest time back, so the next pass tries
                // again.
                logging.log(
                  logging.Warning,
                  "howdy/notifications: digest failed: " <> reason,
                )
                restore_digest(notifier, recipient, previous)
                |> result.replace(Report(..report, failed: report.failed + 1))
              }
              GiveUp(reason) -> {
                logging.log(
                  logging.Warning,
                  "howdy/notifications: digest failed: " <> reason,
                )
                set_digest_state(notifier, ids, "failed")
                |> result.replace(Report(..report, failed: report.failed + 1))
              }
            }
          }
        }
      })
    }
    _, _ -> Ok(report)
  }
}

/// Take a user's digest for sending: check it is still due, stamp it as
/// sent now so no other worker takes it, mark notifications read meanwhile
/// as skipped, and return the unread ones with the previous stamp.
fn claim_digest(
  notifier: Notifier,
  digest: DigestSetup,
  recipient: String,
  now: Int,
) -> service.Result(Option(#(Option(Int), List(Notification)))) {
  use conn <- database.write_transaction(
    notifier.repo,
    touching: "howdy_notifications_digests",
  )
  use previous <- result.try(database.query(
    conn,
    "SELECT sent_at FROM howdy_notifications_digests d WHERE user_id = $1"
      <> database.for_update(conn, "d"),
    [sql.string(recipient)],
    decode.field(0, decode.int, decode.success),
  ))
  let previous = list.first(previous) |> option.from_result
  let due = case previous {
    Some(sent) -> sent <= now - digest.every
    None -> True
  }
  use <- bool.guard(!due, Ok(None))
  use _ <- result.try(
    database.execute(
      conn,
      "UPDATE howdy_notifications_items SET email = 'skipped'
     WHERE user_id = $1 AND email = 'digest' AND read_at IS NOT NULL",
      [sql.string(recipient)],
    ),
  )
  use notifications <- result.try(database.query(
    conn,
    "SELECT " <> columns <> " FROM howdy_notifications_items
     WHERE user_id = $1 AND email = 'digest'
     ORDER BY created_at, id LIMIT 100",
    [sql.string(recipient)],
    notification_decoder(),
  ))
  use <- bool.guard(notifications == [], Ok(Some(#(previous, []))))
  use _ <- result.try(
    database.execute(
      conn,
      "DELETE FROM howdy_notifications_digests WHERE user_id = $1",
      [sql.string(recipient)],
    ),
  )
  use _ <- result.map(
    database.execute(
      conn,
      "INSERT INTO howdy_notifications_digests (user_id, sent_at) VALUES ($1, $2)",
      [sql.string(recipient), sql.int(now)],
    ),
  )
  Some(#(previous, notifications))
}

fn set_digest_state(
  notifier: Notifier,
  ids: List(String),
  state: String,
) -> service.Result(Nil) {
  list.try_each(ids, fn(id) {
    database.execute(
      notifier.repo,
      "UPDATE howdy_notifications_items SET email = $1 WHERE id = $2",
      [sql.string(state), sql.string(id)],
    )
  })
}

fn restore_digest(
  notifier: Notifier,
  recipient: String,
  previous: Option(Int),
) -> service.Result(Nil) {
  case previous {
    Some(sent_at) ->
      database.execute(
        notifier.repo,
        "UPDATE howdy_notifications_digests SET sent_at = $1 WHERE user_id = $2",
        [sql.int(sent_at), sql.string(recipient)],
      )
    None ->
      database.execute(
        notifier.repo,
        "DELETE FROM howdy_notifications_digests WHERE user_id = $1",
        [sql.string(recipient)],
      )
  }
}

/// Run one delivery, giving up on it if the app's code for it crashes.
fn guarded(run: fn() -> Outcome) -> Outcome {
  case rescue(run) {
    Ok(outcome) -> outcome
    Error(reason) -> GiveUp("crashed: " <> reason)
  }
}

// -- FFI ---------------------------------------------------------------------

@external(erlang, "howdy_notifications_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, String)

@external(erlang, "howdy_notifications_ffi", "now_ms")
fn now_ms() -> Int

@external(erlang, "howdy_notifications_ffi", "subscribe")
fn relay_events(recipient: String, owner: Pid, send: fn(Event) -> Nil) -> Pid

@external(erlang, "howdy_notifications_ffi", "unsubscribe")
fn stop_relay(relay: Pid) -> Nil

@external(erlang, "howdy_notifications_ffi", "broadcast")
fn broadcast(recipient: String, event: Event) -> Nil

@external(erlang, "howdy_notifications_ffi", "subscribers")
fn count_subscribers(recipient: String) -> Int
