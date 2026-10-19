# Notifications example

Flash messages, a live notification bell, email and Web Push, with
`howdy/flash` and `howdy_notifications`.

```sh
gleam run
```

It listens on 127.0.0.1:8792. Open <http://localhost:8792> and sign in as
Ana, then open it again in another browser, or a private window, and sign
in as Bo.

- Send Bo a notification. The form posts and redirects, and the page says
  "Sent to Bo" with a flash message.
- Bo's bell counts it without a reload, a toast says what arrived, and the
  live view below the form hears it too. Read it in one of Bo's tabs and
  the count changes in the others.
- A mention is emailed as well, thirty seconds later, unless Bo reads it
  first. Mail goes to an outbox in `tmp/mail`, as `.eml` files.
- The bell's panel offers to turn on browser notifications, which arrive
  even with every tab closed. Make keys with
  `gleam run -m howdy/notifications/web_push` and set `VAPID_PUBLIC_KEY`
  and `VAPID_PRIVATE_KEY` so subscriptions survive a restart.
- `/inbox` lists everything with plain forms, so it works without
  JavaScript.

Signing in is pretend: a cookie naming the user. A real app identifies the
user with `howdy_auth`.

`node browser_test/run.mjs` drives two users through all of this in
headless Chromium while the app is running.
