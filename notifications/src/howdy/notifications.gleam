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
//// gathered into a digest, and by push: to the browser's own notifications
//// with `howdy/notifications/web_push`, and to any other push service the
//// app adds with `with_push_service`. Users choose per kind with
//// `set_preference`, and the app sets the defaults with `with_defaults`.
//// Email and push are background jobs of
//// [howdy_jobs](https://hexdocs.pm/howdy_jobs/howdy/jobs.html), queued in
//// the transaction that saves the notification and done by the app's
//// runner (`handle_jobs`), which retries what fails.
////
//// Recipients are user IDs as strings, such as `howdy_auth` user IDs. The
//// package does not check them against any table, so it works with any
//// account system.

import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
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
import howdy/database/postgres
import howdy/jobs
import howdy/mail
import howdy/migration
import howdy/param
import howdy/query
import howdy/service
import howdy/sse
import logging
import pog

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
    /// Pushed by every push service the notifier has, such as to the
    /// browsers the user turned on with `web_push`.
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
    /// Push services by name, in the order they were added.
    push: List(#(String, fn(Notification) -> Outcome)),
    base_url: String,
    email_after: Int,
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
    push: [],
    base_url: "",
    email_after: 0,
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
         push TEXT NOT NULL
       );
       CREATE INDEX howdy_notifications_items_user
         ON howdy_notifications_items (user_id, created_at);
       CREATE INDEX howdy_notifications_items_digest
         ON howdy_notifications_items (user_id, email);
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
         sent_at BIGINT
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
    // What became of each push service's delivery of each notification. The
    // items table's `push` column now only tracks push jobs queued before
    // this table existed.
    gloo_migration.new(
      2,
      "create_push_deliveries",
      "CREATE TABLE howdy_notifications_push_deliveries (
         item_id TEXT NOT NULL,
         service TEXT NOT NULL,
         user_id TEXT NOT NULL,
         state TEXT NOT NULL,
         PRIMARY KEY (item_id, service)
       );
       CREATE INDEX howdy_notifications_push_deliveries_user
         ON howdy_notifications_push_deliveries (user_id)",
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
/// `web_push.deliver` makes. It is the push service named `"default"`:
/// calling `with_push` again replaces it. Add more with `with_push_service`.
pub fn with_push(
  notifier: Notifier,
  deliver: fn(Notification) -> Outcome,
) -> Notifier {
  with_push_service(notifier, default_push_service, deliver)
}

/// Deliver push notifications with `deliver` too, as the push service
/// called `name`, such as one sending to phones. A notification the user
/// wants pushed goes to every service, each in a job of its own: one that
/// fails or is retried does not hold up or repeat the others. Adding a
/// name that is already there replaces its service.
///
/// ```gleam
/// notifier
/// |> notifications.with_push_service("web", web_push.deliver(push))
/// |> notifications.with_push_service("phones", my_app.send_to_phones)
/// ```
///
/// `deliver` is given the notification and finds the user's devices
/// itself. Keep a name once notifications have been sent with it: jobs
/// waiting for a service that is gone fail.
pub fn with_push_service(
  notifier: Notifier,
  named name: String,
  deliver deliver: fn(Notification) -> Outcome,
) -> Notifier {
  let push = case list.key_find(notifier.push, name) {
    Ok(_) ->
      list.map(notifier.push, fn(service) {
        case service.0 == name {
          True -> #(name, deliver)
          False -> service
        }
      })
    Error(Nil) -> list.append(notifier.push, [#(name, deliver)])
  }
  Notifier(..notifier, push:)
}

/// The name `with_push` gives its service.
const default_push_service = "default"

/// The address the app is served from, such as `https://example.com`, so
/// email and push can link to it. See `url`.
pub fn with_base_url(notifier: Notifier, base_url: String) -> Notifier {
  let base_url = case string.ends_with(base_url, "/") {
    True -> string.drop_end(base_url, 1)
    False -> base_url
  }
  Notifier(..notifier, base_url:)
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
      let email = case delivery.email, notifier.email {
        _, None | NoEmail, _ -> "none"
        EmailNow, Some(_) -> "now"
        EmailDigest, Some(_) ->
          case notifier.digest {
            Some(_) -> "digest"
            None -> "now"
          }
      }
      let push = case delivery.push {
        True -> list.map(notifier.push, fn(service) { service.0 })
        False -> []
      }
      // The notification and the jobs that deliver it are saved together.
      // Gloo binds SQLite parameters by position and handles at most nine,
      // so the numbers and fixed words go in the statement itself.
      use _ <- result.try({
        use conn <- database.transaction(notifier.repo)
        use _ <- result.try(
          database.execute(
            conn,
            "INSERT INTO howdy_notifications_items (id, user_id, kind, title, body,
           link, data, inbox, created_at, email, push)
         VALUES ($1, $2, $3, $4, $5, $6, $7, "
              <> int.to_string(flag(delivery.inbox))
              <> ", "
              <> int.to_string(now)
              <> ", '"
              <> email
              <> "', 'none')",
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
        queue_deliveries(notifier, conn, notification, email, push)
      })
      case delivery.inbox {
        True -> {
          announce(recipient, Received(notification))
          announce_unread(notifier, recipient)
        }
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
  use _ <- result.try({
    use conn <- database.transaction(notifier.repo)
    use _ <- result.try(
      database.execute(
        conn,
        "DELETE FROM howdy_notifications_items WHERE id = $1 AND user_id = $2",
        [sql.string(id), sql.string(recipient)],
      ),
    )
    database.execute(
      conn,
      "DELETE FROM howdy_notifications_push_deliveries WHERE item_id = $1",
      [sql.string(id)],
    )
  })
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
      "howdy_notifications_push_deliveries",
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
  use conn <- database.transaction(notifier.repo)
  use _ <- result.try(
    database.execute(
      conn,
      "DELETE FROM howdy_notifications_items
     WHERE read_at IS NOT NULL AND read_at < $1
       AND email NOT IN ('now', 'digest') AND push <> 'pending'
       AND NOT EXISTS (SELECT 1 FROM howdy_notifications_push_deliveries d
         WHERE d.item_id = howdy_notifications_items.id
           AND d.state = 'pending')",
      [sql.int(before)],
    ),
  )
  database.execute(
    conn,
    "DELETE FROM howdy_notifications_push_deliveries
     WHERE NOT EXISTS (SELECT 1 FROM howdy_notifications_items i
       WHERE i.id = howdy_notifications_push_deliveries.item_id)",
    [],
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
/// cluster, or any server at all with `across_servers`, until the process
/// that owns the subject exits or `unsubscribe` is called. Nothing
/// announced after this returns is missed.
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

/// How many subscriptions a user has, across the cluster. Servers that are
/// not clustered, even with `across_servers`, only count their own.
pub fn subscribers(recipient: String) -> Int {
  count_subscribers(recipient)
}

/// Tell a user's subscribers something, from any node. `send` does this
/// itself; this is for events of the app's own making, such as an unread
/// count changed by a bulk update.
pub fn announce(recipient: String, event: Event) -> Nil {
  case process.named(fan_out_name()) {
    Ok(fan_out) -> send_to(fan_out, fan_out_name(), Tell(recipient, event))
    Error(Nil) -> broadcast(recipient, event)
  }
}

fn announce_unread(notifier: Notifier, recipient: String) -> Nil {
  case process.named(fan_out_name()) {
    // Subscribers on other servers are not known here, so each server
    // counts for its own.
    Ok(fan_out) -> send_to(fan_out, fan_out_name(), Recount(recipient))
    Error(Nil) -> recount(notifier, recipient, False)
  }
}

// -- Across servers ----------------------------------------------------------
// Announcements go through `pg`, which reaches every node of an Erlang
// cluster and no further. `across_servers` sends them through PostgreSQL
// instead: each server's process sends what is announced there as a
// `NOTIFY`, hears every server's, and passes each on to the subscribers on
// its own node. With it, a cluster's nodes hear each announcement once, by
// PostgreSQL, rather than twice.

/// The PostgreSQL channel announcements go out on.
const fan_out_channel = "howdy_notifications"

/// The longest payload PostgreSQL takes. A notification too long to go
/// whole goes by ID, and is read back by the servers with subscribers.
const largest_payload = 7999

type FanOut {
  /// Send an announcement to every server.
  Tell(recipient: String, event: Event)
  /// Ask every server to count the recipient's unread notifications for
  /// its own subscribers.
  Recount(recipient: String)
}

type FanOutState {
  /// Announcing through PostgreSQL.
  Notifying(notifier: Notifier)
  /// On SQLite, or unable to listen: announcing through `pg`, as without
  /// `across_servers`.
  Broadcasting(notifier: Notifier)
}

/// Announce through PostgreSQL, so that pages open on any server hear
/// about their user's notifications, whether or not the servers are
/// connected as an Erlang cluster. Add it to the app's supervisor on every
/// server, after the database pool and before the server:
///
/// ```gleam
/// supervisor.new(supervisor.OneForOne)
/// |> supervisor.add(pool)
/// |> supervisor.add(notifications.across_servers(notifier))
/// |> supervisor.add(jobs.supervised(runner))
/// |> supervisor.add(howdy.supervised(app(notifier)))
/// ```
///
/// It listens on a connection of its own, opened with the pool's settings;
/// see `across_servers_via` for a pool `howdy/database/postgres` did not
/// open. One runs per node. On SQLite, which only one server can use, it
/// changes nothing. While it is not running, such as when it restarts,
/// announcements go through the cluster as they do without it. What is
/// announced while a server's listening connection is lost does not reach
/// that server's open pages, but the inbox has it: the bell reads it when
/// its panel next opens.
pub fn across_servers(
  notifier: Notifier,
) -> supervision.ChildSpecification(Nil) {
  fan_out(notifier, None)
}

/// `across_servers`, listening with these settings, such as
/// `pog.url_config(name, url)`: the same the app's pool uses. The pool name
/// in them is not used.
pub fn across_servers_via(
  notifier: Notifier,
  config: pog.Config,
) -> supervision.ChildSpecification(Nil) {
  fan_out(notifier, Some(config))
}

fn fan_out(
  notifier: Notifier,
  settings: Option(pog.Config),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    actor.new_with_initialiser(10_000, fn(_subject) {
      let state = case database.backend(notifier.repo) {
        Ok(database.Postgres) -> {
          let hear = fn(payload) { hear(notifier, payload) }
          let listening = case settings {
            Some(config) -> postgres.listen_via(config, fan_out_channel, hear)
            None -> postgres.listen(notifier.repo, fan_out_channel, hear)
          }
          case listening {
            Ok(_) -> Notifying(notifier)
            Error(error) -> {
              logging.log(
                logging.Warning,
                "howdy/notifications: not announcing across servers: "
                  <> postgres.listen_error_to_string(error)
                  <> ". Only this node's cluster hears announcements.",
              )
              Broadcasting(notifier)
            }
          }
        }
        _ -> Broadcasting(notifier)
      }
      Ok(actor.initialised(state))
    })
    |> actor.named(fan_out_name())
    |> actor.on_message(fn(state, message) {
      case state {
        Notifying(notifier) -> tell_servers(notifier, message)
        Broadcasting(notifier) ->
          case message {
            Tell(recipient, event) -> broadcast(recipient, event)
            Recount(recipient) -> recount(notifier, recipient, False)
          }
      }
      actor.continue(state)
    })
    |> actor.start
    |> result.map(fn(started) { actor.Started(..started, data: Nil) })
  })
}

/// Send one announcement to every server, or to this node's cluster if
/// PostgreSQL cannot take it.
fn tell_servers(notifier: Notifier, message: FanOut) -> Nil {
  let #(recipient, fields) = case message {
    Tell(recipient, Received(notification)) -> #(recipient, [
      #("notification", to_json(notification)),
    ])
    Tell(recipient, Unread(count)) -> #(recipient, [
      #("unread", json.int(count)),
    ])
    Recount(recipient) -> #(recipient, [#("recount", json.bool(True))])
  }
  let payload = fan_out_payload(recipient, fields)
  let payload = case message, string.byte_size(payload) > largest_payload {
    Tell(_, Received(notification)), True ->
      fan_out_payload(recipient, [#("id", json.string(notification.id))])
    _, _ -> payload
  }
  case postgres.notify(notifier.repo, fan_out_channel, payload) {
    Ok(Nil) -> Nil
    Error(error) -> {
      logging.log(
        logging.Warning,
        "howdy/notifications: could not announce across servers: "
          <> service.message(error),
      )
      case message {
        Tell(recipient, event) -> broadcast(recipient, event)
        Recount(recipient) -> recount(notifier, recipient, False)
      }
    }
  }
}

fn fan_out_payload(recipient: String, fields: List(#(String, Json))) -> String {
  json.object([#("to", json.string(recipient)), ..fields]) |> json.to_string
}

/// Pass an announcement from any server on to this node's subscribers.
fn hear(notifier: Notifier, payload: String) -> Nil {
  let decoder = {
    use recipient <- decode.field("to", decode.string)
    use heard <- decode.then(
      decode.one_of(
        decode.field(
          "notification",
          notification_json_decoder(recipient),
          fn(n) { decode.success(HeardNotification(n)) },
        ),
        [
          decode.field("id", decode.string, fn(id) {
            decode.success(HeardId(id))
          }),
          decode.field("unread", decode.int, fn(count) {
            decode.success(HeardUnread(count))
          }),
          decode.field("recount", decode.bool, fn(_) {
            decode.success(HeardRecount)
          }),
        ],
      ),
    )
    decode.success(#(recipient, heard))
  }
  case json.parse(payload, decoder) {
    Error(_) -> Nil
    Ok(#(recipient, heard)) ->
      case local_subscribers(recipient) > 0 {
        False -> Nil
        True ->
          case heard {
            HeardNotification(notification) ->
              local_broadcast(recipient, Received(notification))
            HeardId(id) ->
              case get(notifier, recipient, id) {
                Ok(notification) ->
                  local_broadcast(recipient, Received(notification))
                Error(_) -> Nil
              }
            HeardUnread(count) -> local_broadcast(recipient, Unread(count))
            HeardRecount -> recount(notifier, recipient, True)
          }
      }
  }
}

type Heard {
  HeardNotification(Notification)
  HeardId(String)
  HeardUnread(Int)
  HeardRecount
}

/// Tell `recipient`'s subscribers how many notifications they have unread,
/// unless there are none: those on this node only if `here_only`, and
/// otherwise those in the cluster.
fn recount(notifier: Notifier, recipient: String, here_only: Bool) -> Nil {
  let #(listening, tell) = case here_only {
    True -> #(local_subscribers(recipient), local_broadcast)
    False -> #(subscribers(recipient), broadcast)
  }
  case listening > 0 {
    False -> Nil
    True ->
      case unread_count(notifier, recipient) {
        Ok(count) -> tell(recipient, Unread(count))
        Error(_) -> Nil
      }
  }
}

/// A notification as `to_json` wrote it.
fn notification_json_decoder(
  recipient: String,
) -> decode.Decoder(Notification) {
  use id <- decode.field("id", decode.string)
  use kind <- decode.field("kind", decode.string)
  use title <- decode.field("title", decode.string)
  use body <- decode.field("body", decode.string)
  use link <- decode.field("link", decode.optional(decode.string))
  use data <- decode.field("data", decode.dict(decode.string, decode.string))
  use created_at <- decode.field("created_at", decode.int)
  use read_at <- decode.field("read_at", decode.optional(decode.int))
  decode.success(Notification(
    id:,
    recipient:,
    kind:,
    title:,
    body:,
    link:,
    data:,
    created_at:,
    read_at:,
  ))
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

// -- Delivery ----------------------------------------------------------------
// Email, digests and push are background jobs of `howdy/jobs`, queued in the
// transaction that saves the notification and done by the app's runner.

/// The queue the delivery jobs go to.
pub const queue = "notifications"

/// How many times a delivery is tried in all.
const attempts = 5

fn email_job() -> jobs.Job(String) {
  jobs.define(
    "howdy_notifications.email",
    encode: json.string,
    decoder: decode.string,
  )
  |> jobs.on_queue(queue)
  |> jobs.max_attempts(attempts)
}

/// One push service's delivery of one notification. Jobs queued before
/// there could be more than one service hold only the notification's ID:
/// they are for the default service, with their state in the items table.
type PushJob {
  PushJob(id: String, service: Option(String))
}

fn push_job() -> jobs.Job(PushJob) {
  jobs.define(
    "howdy_notifications.push",
    encode: fn(job: PushJob) {
      case job.service {
        Some(service) ->
          json.object([
            #("id", json.string(job.id)),
            #("service", json.string(service)),
          ])
        None -> json.string(job.id)
      }
    },
    decoder: decode.one_of(
      {
        use id <- decode.field("id", decode.string)
        use service <- decode.field("service", decode.string)
        decode.success(PushJob(id:, service: Some(service)))
      },
      [decode.map(decode.string, PushJob(id: _, service: None))],
    ),
  )
  |> jobs.on_queue(queue)
  |> jobs.max_attempts(attempts)
}

fn digest_job() -> jobs.Job(String) {
  jobs.define(
    "howdy_notifications.digest",
    encode: json.string,
    decoder: decode.string,
  )
  |> jobs.on_queue(queue)
  |> jobs.max_attempts(attempts)
}

/// Teach the app's jobs runner to send notifications' email, digests and
/// push. They run on the `notifications` queue, ten at a time unless the
/// runner says otherwise with `jobs.queue`. Every node running the runner
/// shares the work.
///
/// ```gleam
/// let runner =
///   jobs.runner(db)
///   |> notifications.handle_jobs(notifier)
///
/// supervisor.new(supervisor.OneForOne)
/// |> supervisor.add(jobs.supervised(runner))
/// |> supervisor.add(howdy.supervised(app(notifier)))
/// ```
///
/// In tests, `jobs.drain(runner)` sends whatever is due.
pub fn handle_jobs(runner: jobs.Runner, notifier: Notifier) -> jobs.Runner {
  runner
  |> jobs.handle(email_job(), fn(id, attempt) {
    deliver_email(notifier, id, attempt)
  })
  |> jobs.handle(push_job(), fn(job, attempt) {
    deliver_push(notifier, job, attempt)
  })
  |> jobs.handle(digest_job(), fn(recipient, attempt) {
    deliver_digest(notifier, recipient, attempt)
  })
}

/// The jobs a new notification needs, queued on `conn`.
fn queue_deliveries(
  notifier: Notifier,
  conn: Repo,
  notification: Notification,
  email: String,
  push: List(String),
) -> service.Result(Nil) {
  let now = notifier.clock()
  use _ <- result.try(case email {
    "now" ->
      jobs.new(email_job(), notification.id)
      |> jobs.at(now + notifier.email_after)
      |> jobs.insert(into: conn)
      |> result.replace(Nil)
    "digest" -> queue_digest(notifier, conn, notification.recipient, now)
    _ -> Ok(Nil)
  })
  list.try_each(push, fn(service) {
    use _ <- result.try(
      database.execute(
        conn,
        "INSERT INTO howdy_notifications_push_deliveries
           (item_id, service, user_id, state) VALUES ($1, $2, $3, 'pending')",
        [
          sql.string(notification.id),
          sql.string(service),
          sql.string(notification.recipient),
        ],
      ),
    )
    jobs.new(push_job(), PushJob(id: notification.id, service: Some(service)))
    |> jobs.at(now)
    |> jobs.insert(into: conn)
    |> result.replace(Nil)
  })
}

/// Queue the recipient's next digest for when it is due: now, or the
/// digest interval after the last one. One waits at a time, so a burst of
/// notifications makes one digest; one sent while a digest is being sent
/// queues the next.
fn queue_digest(
  notifier: Notifier,
  conn: Repo,
  recipient: String,
  now: Int,
) -> service.Result(Nil) {
  case notifier.digest {
    None -> Ok(Nil)
    Some(digest) -> {
      use last <- result.try(database.query(
        conn,
        "SELECT sent_at FROM howdy_notifications_digests WHERE user_id = $1",
        [sql.string(recipient)],
        decode.field(0, decode.optional(decode.int), decode.success),
      ))
      let due = case last {
        [Some(sent_at), ..] -> int.max(now, sent_at + digest.every)
        _ -> now
      }
      jobs.new(digest_job(), recipient)
      |> jobs.at(due)
      |> jobs.unique_while_waiting("howdy_notifications.digest:" <> recipient)
      |> jobs.insert(into: conn)
      |> result.replace(Nil)
    }
  }
}

/// What the job says after a delivery went as `outcome`, having recorded it
/// with `record`, which is given the notification's new state. Retries
/// wait 30 seconds, doubling each time.
fn after_delivery(
  outcome: Outcome,
  attempt: jobs.Attempt,
  what: String,
  record: fn(String) -> service.Result(Nil),
) -> jobs.Outcome {
  let recorded = fn(state, then) {
    case record(state) {
      Ok(Nil) -> then
      Error(error) -> jobs.Retry(service.message(error))
    }
  }
  case outcome {
    Delivered -> recorded("sent", jobs.Done)
    Retry(reason) ->
      case jobs.is_last(attempt) {
        True -> recorded("failed", jobs.Retry(what <> ": " <> reason))
        False ->
          jobs.RetryIn(
            30_000 * int.bitwise_shift_left(1, attempt.number - 1),
            what <> ": " <> reason,
          )
      }
    GiveUp(reason) -> recorded("failed", jobs.GiveUp(what <> ": " <> reason))
  }
}

fn deliver_email(
  notifier: Notifier,
  id: String,
  attempt: jobs.Attempt,
) -> jobs.Outcome {
  case notifier.email, find(notifier, id) {
    None, _ -> jobs.GiveUp("the notifier sends no email: see with_email")
    _, Error(service.NotFound(_)) -> jobs.Cancel("the notification is gone")
    _, Error(error) -> jobs.Retry(service.message(error))
    Some(_), Ok(#(_, state, _)) if state != "now" -> jobs.Done
    Some(_), Ok(#(notification, _, _)) if notification.read_at != None ->
      // Read in the inbox before the email went: no need to send it.
      case set_state(notifier, "email", id, "skipped") {
        Ok(Nil) -> jobs.Cancel("read in the app before the email was due")
        Error(error) -> jobs.Retry(service.message(error))
      }
    Some(setup), Ok(#(notification, _, _)) ->
      guarded(fn() {
        email(setup, notification.recipient, setup.render(notification))
      })
      |> after_delivery(attempt, "email", set_state(notifier, "email", id, _))
  }
}

fn deliver_push(
  notifier: Notifier,
  job: PushJob,
  attempt: jobs.Attempt,
) -> jobs.Outcome {
  let name = option.unwrap(job.service, default_push_service)
  let record = fn(state) { set_push_state(notifier, job, state) }
  let what = "push to " <> name
  case find(notifier, job.id), push_state(notifier, job) {
    Error(service.NotFound(_)), _ | _, Error(service.NotFound(_)) ->
      jobs.Cancel("the notification is gone")
    Error(error), _ | _, Error(error) -> jobs.Retry(service.message(error))
    Ok(_), Ok(state) if state != "pending" -> jobs.Done
    Ok(#(notification, _, _)), Ok(_) ->
      case list.key_find(notifier.push, name) {
        Error(Nil) ->
          GiveUp(
            "the notifier has no push service named "
            <> name
            <> ": see with_push_service",
          )
        Ok(deliver) -> guarded(fn() { deliver(notification) })
      }
      |> after_delivery(attempt, what, record)
  }
}

/// Where a push job's delivery stands: pending, sent or failed.
fn push_state(notifier: Notifier, job: PushJob) -> service.Result(String) {
  case job.service {
    None -> result.map(find(notifier, job.id), fn(found) { found.2 })
    Some(service) -> {
      use conn <- database.connect(notifier.repo)
      database.one(
        conn,
        "SELECT state FROM howdy_notifications_push_deliveries
         WHERE item_id = $1 AND service = $2",
        [sql.string(job.id), sql.string(service)],
        decode.field(0, decode.string, decode.success),
        or: service.NotFound("push delivery not found"),
      )
    }
  }
}

fn set_push_state(
  notifier: Notifier,
  job: PushJob,
  state: String,
) -> service.Result(Nil) {
  case job.service {
    None -> set_state(notifier, "push", job.id, state)
    Some(service) -> {
      use conn <- database.connect(notifier.repo)
      database.execute(
        conn,
        "UPDATE howdy_notifications_push_deliveries SET state = $1
         WHERE item_id = $2 AND service = $3",
        [sql.string(state), sql.string(job.id), sql.string(service)],
      )
    }
  }
}

/// One email of the recipient's unread digest notifications, if their last
/// digest went at least the digest's interval ago; otherwise the job waits
/// until then. Notifications read meanwhile are left out, and a recipient
/// with only read ones gets no email.
fn deliver_digest(
  notifier: Notifier,
  recipient: String,
  attempt: jobs.Attempt,
) -> jobs.Outcome {
  case notifier.email, notifier.digest {
    Some(setup), Some(digest) -> {
      let now = notifier.clock()
      case claim_digest(notifier, digest, recipient, now) {
        Error(error) -> jobs.Retry(service.message(error))
        Ok(NotYet(due)) -> jobs.Snooze(due - now)
        Ok(Nothing) -> jobs.Done
        Ok(Claimed(previous, notifications)) -> {
          let ids = list.map(notifications, fn(n) { n.id })
          let outcome =
            guarded(fn() {
              email(setup, recipient, digest.render(notifications))
            })
          // Sent or failed for good. A digest that was not sent gives the
          // recipient their stamp back, so the next one is not held up.
          let finish = fn(state) {
            use conn <- database.transaction(notifier.repo)
            use _ <- result.try(set_digest_state(conn, ids, state))
            use _ <- result.try(case state {
              "sent" -> Ok(Nil)
              _ -> restore_digest(conn, recipient, previous)
            })
            // More waited than one email holds: the rest go in the next,
            // whether this one went or not.
            case list.length(notifications) >= digest_size {
              True -> queue_digest(notifier, conn, recipient, now)
              False -> Ok(Nil)
            }
          }
          case outcome, jobs.is_last(attempt) {
            Retry(_), False -> {
              let restored = {
                use conn <- database.transaction(notifier.repo)
                restore_digest(conn, recipient, previous)
              }
              case restored {
                Ok(Nil) -> after_delivery(outcome, attempt, "digest", finish)
                Error(error) -> jobs.Retry(service.message(error))
              }
            }
            _, _ -> after_delivery(outcome, attempt, "digest", finish)
          }
        }
      }
    }
    _, _ -> jobs.GiveUp("the notifier sends no digests: see with_digest")
  }
}

/// The most notifications one digest holds.
const digest_size = 100

type DigestClaim {
  /// The last digest went too recently: the next is due then.
  NotYet(due: Int)
  /// Nothing unread is waiting.
  Nothing
  /// Stamped as sent now, so no other job sends it too, with the stamp it
  /// had before, to put back if sending fails.
  Claimed(previous: Option(Int), notifications: List(Notification))
}

/// Take a recipient's digest for sending: check it is due, mark
/// notifications read meanwhile as skipped, and stamp the digest as sent
/// now.
fn claim_digest(
  notifier: Notifier,
  digest: DigestSetup,
  recipient: String,
  now: Int,
) -> service.Result(DigestClaim) {
  use conn <- database.write_transaction(
    notifier.repo,
    touching: "howdy_notifications_digests",
  )
  // The recipient's stamp row is made once and then only updated, so on
  // PostgreSQL a second job taking the same digest waits on its lock and
  // then sees the new stamp. A row that was deleted and inserted again
  // would let it through.
  use _ <- result.try(
    database.execute(
      conn,
      "INSERT INTO howdy_notifications_digests (user_id, sent_at)
     VALUES ($1, NULL) ON CONFLICT (user_id) DO NOTHING",
      [sql.string(recipient)],
    ),
  )
  use previous <- result.try(database.one(
    conn,
    "SELECT sent_at FROM howdy_notifications_digests d WHERE user_id = $1"
      <> database.for_update(conn, "d"),
    [sql.string(recipient)],
    decode.field(0, decode.optional(decode.int), decode.success),
    or: service.Internal("the digest stamp is missing"),
  ))
  case previous {
    Some(sent_at) if sent_at + digest.every > now ->
      Ok(NotYet(sent_at + digest.every))
    _ -> {
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
         ORDER BY created_at, id LIMIT " <> int.to_string(digest_size),
        [sql.string(recipient)],
        notification_decoder(),
      ))
      case notifications {
        [] -> Ok(Nothing)
        _ -> {
          use _ <- result.map(set_stamp(conn, recipient, Some(now)))
          Claimed(previous, notifications)
        }
      }
    }
  }
}

fn set_stamp(
  conn: Repo,
  recipient: String,
  sent_at: Option(Int),
) -> service.Result(Nil) {
  database.execute(
    conn,
    "UPDATE howdy_notifications_digests SET sent_at = $1 WHERE user_id = $2",
    [sql.nullable(sql.int, sent_at), sql.string(recipient)],
  )
}

fn set_digest_state(
  conn: Repo,
  ids: List(String),
  state: String,
) -> service.Result(Nil) {
  list.try_each(ids, fn(id) {
    database.execute(
      conn,
      "UPDATE howdy_notifications_items SET email = $1 WHERE id = $2",
      [sql.string(state), sql.string(id)],
    )
  })
}

fn restore_digest(
  conn: Repo,
  recipient: String,
  previous: Option(Int),
) -> service.Result(Nil) {
  set_stamp(conn, recipient, previous)
}

/// A notification by id, whoever it is for, with its email and push states.
fn find(
  notifier: Notifier,
  id: String,
) -> service.Result(#(Notification, String, String)) {
  use conn <- database.connect(notifier.repo)
  database.one(
    conn,
    "SELECT " <> columns <> ", email, push FROM howdy_notifications_items
     WHERE id = $1",
    [sql.string(id)],
    {
      use notification <- decode.then(notification_decoder())
      use email <- decode.field(9, decode.string)
      use push <- decode.field(10, decode.string)
      decode.success(#(notification, email, push))
    },
    or: service.NotFound("notification not found"),
  )
}

/// Record what became of a notification's email or push. `column` is
/// trusted text.
fn set_state(
  notifier: Notifier,
  column: String,
  id: String,
  state: String,
) -> service.Result(Nil) {
  use conn <- database.connect(notifier.repo)
  database.execute(
    conn,
    "UPDATE howdy_notifications_items SET " <> column <> " = $1 WHERE id = $2",
    [sql.string(state), sql.string(id)],
  )
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

@external(erlang, "howdy_notifications_ffi", "local_broadcast")
fn local_broadcast(recipient: String, event: Event) -> Nil

@external(erlang, "howdy_notifications_ffi", "local_subscribers")
fn local_subscribers(recipient: String) -> Int

@external(erlang, "howdy_notifications_ffi", "fan_out_name")
fn fan_out_name() -> process.Name(FanOut)

/// Send to `pid`, looked up as `name`, without looking it up again: if it
/// has exited since, the message is dropped instead of crashing the caller.
@external(erlang, "howdy_notifications_ffi", "send_to")
fn send_to(pid: Pid, name: process.Name(message), message: message) -> Nil
