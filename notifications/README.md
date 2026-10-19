# howdy_notifications

Notifications for [howdy](https://github.com/mikeyjones/howdy/blob/v2.1.1/README.md) apps: an inbox kept until read,
pushed live to every page the user has open, with email, digests and Web
Push.

```toml
howdy_notifications = { git = "https://github.com/mikeyjones/howdy.git", ref = "v2.1.1", path = "notifications" }
```

## Sending

```gleam
import howdy/notifications

let notifier = notifications.new(db)

notifications.draft("comment.created", "Ana commented on your post")
|> notifications.body("Looks good to me!")
|> notifications.link("/posts/42#comment-7")
|> notifications.send(notifier, to: post.author_id)
```

The notification is saved first, in the package's tables in your database
(`notifications.schema()` is its migrations, for PostgreSQL and SQLite),
then announced to the recipient's open pages on every node of the cluster.
A page that was closed reads the inbox when it next connects, so nothing is
missed.

## Showing them

`notifications.routes(notifier, at: "/notifications", identify:)` serves the
inbox as JSON, a stream of server-sent events, and routes to mark
notifications read, which also work as plain HTML forms. howdy_ui's `bell`
uses them: a button with the unread count and a panel of the newest, kept
up to date as notifications arrive, each shown as a toast. A live view can
`subscribe` to a user's inbox instead.

## Email and Web Push

```gleam
notifications.new(db)
|> notifications.with_defaults(fn(kind) {
  case kind {
    "security." <> _ -> Delivery(..default_delivery, email: EmailNow)
    _ -> Delivery(..default_delivery, email: EmailDigest)
  }
})
|> notifications.with_email(mailer, address:, render:)
|> notifications.email_after(120)
|> notifications.with_digest(every: 86_400, render: digest_email)
|> notifications.with_push(web_push.deliver(push))
```

Each user can choose per kind, with `set_preference`. Email waits to see
whether the notification is read in the app first, and digest kinds are
gathered into one email per period. `howdy/notifications/web_push` sends
the browser's own notifications, encrypted for each browser (RFC 8291) and
signed with your VAPID keys (RFC 8292); `gleam run -m
howdy/notifications/web_push` makes the keys.

Email and push are sent by a worker you add to your supervision tree with
`notifications.supervised(notifier)`. It retries what fails, and workers on
several nodes share the work through the database.

See the [notifications docs](https://github.com/mikeyjones/howdy/tree/v2.1.1/docs/notifications) and
`examples/notifications`.
