# howdy_admin

A development admin area for [howdy](https://github.com/howdy-gleam/howdy/blob/v1.0.0/README.md) apps: browse and edit the
database, manage users and groups, and sign in as any user. It is mounted from
the `dev/` entry point beside [`howdy_dev`](https://github.com/howdy-gleam/howdy/blob/v1.0.0/howdy_dev/README.md), so it
never reaches a deployment.

```sh
gleam add --dev howdy_dev@1 howdy_admin@1
```

```gleam
// dev/my_app_dev.gleam
import gleam/erlang/process
import howdy/admin
import howdy/dev
import my_app

pub fn main() {
  let db = my_app.open_database()
  let identity = my_app.identity(db)
  let permissions = my_app.permissions(db)
  let dashboard =
    admin.new() |> admin.auth(identity) |> admin.authorization(permissions)

  let assert Ok(_) =
    dev.start(fn() {
      my_app.app(db, identity, permissions) |> admin.mount(dashboard)
    })
  process.sleep_forever()
}
```

Run `gleam dev` and open <http://localhost:8787/_howdy> (whatever port the app
listens on). See [`examples/admin`](https://github.com/howdy-gleam/howdy/blob/v1.0.0/examples/admin/README.md) for a complete
app.

## What the app registers is what the admin shows

Gleam cannot discover at runtime which packages an app uses, and there is no
registry of the Repo or `auth.Auth` the app built, so the app hands them over:

- `admin.database(repo)`: the tables of a Gloo Repo, on PostgreSQL or SQLite.
  The overview names the backend and the packages `howdy/migration` has
  applied. Each table has a grid of its rows that follows the database, so a
  row your app or another client writes appears on its own and is marked
  `changed` for a few seconds. The grid searches every column at once,
  filters by column with equals, not equals, contains, greater, less, null
  and not null, sorts by any column, and pages at a chosen size. All of that
  runs in the database, so a large table is fine. Rows can be inserted,
  edited and deleted. A row is addressed by its primary key, or by `rowid`
  (SQLite) or `ctid` (PostgreSQL) when the table has none.
- `admin.auth(identity)`: users and groups. Create a user (provisioned without
  a credential), suspend and resume them, see their live sessions (method,
  when they signed in, last seen, expiry and client) and revoke any one of
  them or all at once, move them between groups, delete the account, and
  create, rename and delete groups. Deletion asks for the email address to be
  typed back, and is offered only when the app configured
  `auth.with_account_deletion`, whose callback removes the app's own rows in
  the same transaction. Registering auth also
  registers its Repo, unless `admin.database` was given another.
- `admin.authorization(permissions)`: roles in every scope, each with its
  permissions and who holds it. Define a role (global, or in an organization)
  with its permissions one per line, replace the list later, assign and revoke
  it from the role's page or from a user's page, and delete it, which drops
  its assignments. Needs `auth` too.
- `admin.mail(box)`: the messages a `howdy/mail/outbox` keeps, listed as
  they arrive. Each message shows its envelope, its HTML in a sandboxed frame
  at desktop or mobile width (no scripts, links open in a new tab, inline
  `cid:` images shown), its text with links you can follow, its raw source
  (downloadable as `.eml`), and its attachments. See
  [`howdy_mail`](https://github.com/howdy-gleam/howdy/blob/v1.0.0/mail/README.md).
- `admin.mail_previews(previews, send_with: mailer)`: your templates built
  from sample data, grouped, each rendered as it would be sent, with a button
  that sends it through `mailer`. Point that mailer at the outbox or a local
  SMTP server, never production. A template that crashes on its sample, or a
  message the mailer would refuse, shows why. Calls add up, so the app's
  previews and `howdy/auth/emails.previews` can be registered separately.
- `admin.telemetry(recorder)`: the traces and log lines a
  `howdy/telemetry/recorder` holds, listed as requests finish. Each trace
  opens as a timeline of its spans with their attributes and events, with
  failures, statements repeated five or more times (a query per row) and
  statements slower than 100 ms pointed out. See
  [`howdy_telemetry`](https://github.com/howdy-gleam/howdy/blob/v1.0.0/telemetry/README.md).
- `admin.flags(features)`: the feature flags of a running `howdy/flags`,
  including stored keys the code no longer registers. Each flag's page shows
  its rollout and ramp, and has its kill switch, the users, organizations and
  groups it is allowed or blocked for (a user can be given by email when
  `auth` is registered), a check of whether someone gets it and why, and its
  history with undo. Rollouts and ramps are not set here: the admin only
  runs in development, so set them from the app or `howdy/flags/cli`. When
  the flags' store is read-only, the pages show everything and change
  nothing. **Groups** creates groups and manages
  their members. Changes are recorded as made by `howdy_admin`. See
  [`howdy_flags`](https://github.com/howdy-gleam/howdy/blob/v1.0.0/flags/README.md).
- `admin.at("/somewhere")` moves the pages, and `admin.named` sets the sidebar
  title.

Every value in the grid is shown and edited as text, and the database casts
what it is given: PostgreSQL through an explicit `CAST` to the column's type,
SQLite by column affinity. A refused write shows the driver's message, which a
real application never should. In an insert form, a column left empty takes its
default and the `NULL` box stores a null; in an edit form every column is
written.

## Signing in as a user

The user's page has **Sign in as this user**. It calls `auth.impersonate`,
which issues a session with method `Impersonation`, records
`session.impersonated` in the audit trail with the actor `howdy_admin`, and
sets the app's own session cookie before redirecting to `/`. Because the admin
shares the app's origin, the cookie is the real one: the next request to the
app is authenticated as that user. Suspended users cannot be impersonated,
and the session skips second factors and SSO enforcement, which is why it is
never reachable by the user themselves.

`howdy_auth` migration **18** allows the new method name; run it before using
this version.

## Development only

There is no login. Anyone who can reach the pages can read and change every
row and sign in as anyone. The defences are:

- It is a dev dependency and its entry point lives in `dev/`, which `gleam
  export erlang-shipment` leaves out.
- `howdy/dev` listens on loopback. The admin also refuses any request whose
  `Host` is not `localhost`, `127.0.0.1` or `[::1]` with `403`, so a page on
  another site cannot reach it through DNS rebinding. `admin.allow_hosts`
  replaces that list for a trusted network; anyone who can reach an allowed
  host owns your data.
- Writes must come from the admin's own origin. A `POST` whose
  `Sec-Fetch-Site` or `Origin` header says another site sent it gets `403`,
  so a page you visit while the admin runs cannot post to it. Forms carry no
  CSRF token; the browser's headers do that job.

## How the grid stays current

Each open grid is a Lustre server component that re-runs its query, compares
the page with the previous one, and marks what differs for a few seconds.
What prompts the query depends on the database.

On **PostgreSQL** the grid installs a statement-level trigger named
`howdy_admin_notify` on the table it shows, which calls `pg_notify` with the
table's name on the `howdy_admin` channel after any insert, update, delete or
truncate. The grid listens on one extra connection, opened with the same
settings as the app's pool through pgo's own notification client, and
reloads the moment its table is named. It still checks every 15 seconds in
case a notification was missed while that connection reconnected. The
trigger only notifies and never touches a row, and `howdy/migration` ignores
triggers with this prefix when it checks a package's schema, so the app
starts as before. To put the database back exactly as it was, call
`admin.remove_notify_triggers(repo)` or run
`DROP FUNCTION howdy_admin_notify() CASCADE`.

On **SQLite** there is no such mechanism, and `sqlight` does not expose the
update hook, so the grid asks once a second. That is fine for a development
tool with a few tabs open.

## Testing

`gleam test` drives every page through `howdy/testing` against an in-memory
SQLite database, or against PostgreSQL when `HOWDY_ADMIN_TEST_POSTGRES_URL`
names a server whose database the tests may empty, which also covers the
notifications. `node browser_test/live_grid.mjs` opens the grid in headless
Chromium against a running `examples/admin`, changes the table with `sqlite3`,
and checks the grid follows. `node browser_test/mail.mjs` registers an
address against the running example and checks the registration email
appears in the outbox without a reload, renders in its sandboxed frame with
its sign-in link, and that a preview can be sent.
