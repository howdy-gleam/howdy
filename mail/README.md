# howdy_mail

Email for [howdy](https://github.com/mikeyjones/howdy/blob/v1.0.0/README.md) apps: messages written with
[smail](https://hexdocs.pm/smail) templates, sent over SMTP or an HTTP
provider, and kept in a development outbox that the
[admin area](https://github.com/mikeyjones/howdy/blob/v1.0.0/admin/README.md) shows. [`howdy_auth`](https://github.com/mikeyjones/howdy/blob/v1.0.0/auth/README.md)
builds its emails on it.

```sh
gleam add howdy_mail@1 smail@2
```

## Writing a message

```gleam
import howdy/mail
import smail/attribute
import smail/email
import smail/html

pub fn welcome(user: User) -> mail.Message {
  mail.message()
  |> mail.to([mail.named(user.name, user.email)])
  |> mail.subject("Welcome to Acme")
  |> mail.template(
    email.html([], [
      email.head([], []),
      email.body([], [
        email.preview("Your account is ready"),
        email.container([], [
          email.paragraph([], [html.text("Hi " <> user.name <> ",")]),
          email.button([attribute.href("https://acme.test/start")], [
            html.text("Get started"),
          ]),
        ]),
      ]),
    ]),
  )
  |> mail.tag("onboarding.welcome")
}
```

`template` renders the smail element to HTML, and to plain text for mail
clients that do not show HTML. `text` sets the plain text yourself; do that
when the text carries a link that matters, because smail can run the block
after a button into the button's URL. `html` takes HTML without smail. The
rest of the builder is `from`, `cc`, `bcc`, `reply_to`, `header`, `attach`
(with `mail.attachment(filename:, content_type:, content:)`, and
`mail.inline(attachment, "logo")` for an image the HTML shows as
`cid:logo`), and `tag`. Functions that take a list add to what was there.
`mail.parse_address("Someone <someone@example.com>")` reads an address.

## Sending

```gleam
let mailer =
  mail.mailer(adapter)
  |> mail.default_from(mail.named("Acme", "hello@acme.test"))

case mail.send(mailer, welcome(user)) {
  Ok(receipt) -> ...
  Error(mail.Invalid(reason)) -> ...     // the message is wrong; do not retry
  Error(mail.Unavailable(reason)) -> ... // timeout, 4xx SMTP, 429/5xx: retry later
  Error(mail.Refused(reason)) -> ...     // bad credentials, unverified sender
}
```

`send` checks the message before the adapter sees it: a sender (its own or
the default), at least one recipient, a subject, a body, addresses that are
addresses, and no line break in the subject, a name or a header, so user
input cannot add headers. Headers the MIME writer sets itself (`From`,
`Subject`, `Content-Type` and the like) are refused from `header`. `send`
waits for the provider to accept or refuse the message. There is no queue
yet; `mail.retryable(error)` says whether trying again might work, and
`mail.to_service_error` turns an error into a `howdy/service` error that
does not leak provider details to clients.

`mail.prepare(mailer, message)` does the checks and applies the defaults
without sending, which is what previews use.

## Adapters

| Module | Configuration |
| --- | --- |
| `howdy/mail/smtp` | `smtp.from_env()` reads `SMTP_URL`, `smtp.from_url("smtp://user:pass@host:587")` |
| `howdy/mail/resend` | `resend.from_env()` reads `RESEND_API_KEY`, or `resend.new(key)` |
| `howdy/mail/sendgrid` | `sendgrid.from_env()` reads `SENDGRID_API_KEY`, or `sendgrid.new(key)` |
| `howdy/mail/outbox` | `outbox.start()` in memory, `outbox.start_in(directory)` on disk |

**SMTP** uses gen_smtp, one connection per message. `smtps://` is TLS from
the first byte (port 465 by default); `smtp://` requires `STARTTLS` (port
587), except for loopback addresses and dotless names such as a Compose
service called `mailpit`, where TLS is off. Certificates are checked against
the system's CAs and the host name. `?tls=none|starttls|implicit` chooses
explicitly, and `smtp.tls(config, smtp.StartTls(verify: False))` skips
verification. Percent-encode an `@` in the user name as `%40`.

**Resend** sends each message's id as the `Idempotency-Key`, so retrying the
same `Outgoing` does not send it twice. Tags become Resend tags, with
characters other than letters, digits, `_` and `-` turned into `_`.

**SendGrid** needs a `To` recipient, drops an address repeated in `Cc` or
`Bcc`, sends tags as categories and the message id as the custom argument
`howdy_id`. Set `sendgrid.base_url(config, "https://api.eu.sendgrid.com")`
for the EU region.

`resend.request` and `sendgrid.request` build the HTTP request an adapter
sends, and `receipt` reads the response, so they can be tested without the
network.

### Your own adapter

An adapter is a name and a function from a checked `mail.Outgoing` to a
`Receipt`:

```gleam
pub fn adapter(config: Config) -> mail.Adapter {
  mail.adapter(named: "Postmark", send: fn(outgoing: mail.Outgoing) {
    // outgoing.from, .to, .cc, .bcc, .subject, .html, .text, .headers,
    // .attachments, .tags, .id, .date
    // mime.encode(outgoing) is the raw RFC 5322 message, for APIs that take one.
    Ok(mail.Receipt(outgoing.id, Some(provider_id)))
  })
}
```

Return `Unavailable` for anything worth retrying and `Refused` for the rest.
Adapters wrap: `mail.redirect_all(adapter, to: address)` sends everything to
one inbox for staging, keeping the intended recipients in `X-Original-To`,
and `mail.fallback(primary, secondary)` tries the second when the first is
`Unavailable`.

## The development outbox

In development, keep mail instead of sending it, and read it in the admin:

```gleam
// dev/my_app_dev.gleam
let assert Ok(box) = outbox.start_in("tmp/mail")
let mailer =
  mail.mailer(outbox.adapter(box)) |> mail.default_from(my_app.sender)

let assert Ok(_) =
  dev.start(fn() {
    my_app.app(db, mailer)
    |> admin.mount(
      admin.new()
      |> admin.mail(box)
      |> admin.mail_previews(my_app.previews(), send_with: mailer),
    )
  })
```

Start the outbox outside the function `howdy/dev` rebuilds from, so it
survives reloads. `start_in` writes each message to the directory you give
it as an `.eml` file, which any mail client opens, and a `.json` file the
outbox reads back after a restart. Put the directory in `.gitignore`: it
holds sign-in tokens. The newest 500 messages are kept.

The outbox is also the adapter for tests:

```gleam
let box = outbox.start()
// ... run the flow ...
let assert Ok(sent) = outbox.latest_to(box, "ada@example.com")
assert sent.subject == "Confirm your account"
```

## Previews

A preview is a name and a function that builds a message from sample data.
The admin renders each one as it would be sent, and sends it on demand:

```gleam
import howdy/mail/preview

pub fn previews() -> List(preview.Preview) {
  [
    preview.new("Welcome", fn() { welcome(sample_user()) }),
    preview.new("Invoice", fn() { invoice(sample_invoice()) })
      |> preview.in_group("Billing"),
  ]
}
```

Previews are built each time they are shown, so with `howdy/dev` an edited
template shows on the next refresh. A template that crashes on its sample
data, or a message that would be refused, shows why instead.
`howdy/auth/emails.previews` gives one for every auth email.

## Testing

`gleam test` covers the builder and its checks, the MIME encoding (decoded
again with gen_smtp's parser), SMTP against gen_smtp's own server on
loopback, including authentication, refusals and required `STARTTLS`, the
outbox on disk and in memory, and the provider requests.
