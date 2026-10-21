# Admin example

A notes app with email-token sign-in on SQLite, and the `howdy_admin`
development area mounted from `dev/`.

```sh
gleam dev
```

Open <http://localhost:8787/_howdy>. The admin shows the app's tables, users,
groups and roles. Create a user, sign in as them, then `POST /notes` with
`{"title": "..."}` and watch the row appear in the `notes_notes` grid
without a reload. Edit the row in another SQLite client and the grid follows
within a second.

Give a user the global `reader` role from their page or from **Roles**, sign
in as them, and `GET /notes/all` answers; without it the route is `403`.

Deleting a user from their page removes their notes too: the example's
deletion callback does that in the same transaction.

Registering at `/auth/register` sends the confirmation email to the outbox
under **Mail**, where its button signs you in. The outbox also writes each
message to `tmp/mail` as an `.eml` file. **Previews** shows every email the
app sends (its own weekly digest and all of auth's) from sample data, and
sends one to the outbox on request. `gleam run` sends through `SMTP_URL`
instead, such as `smtp://localhost:1025` for Mailpit, or prints to the
terminal when it is unset.

With `DATABASE_URL` set to a PostgreSQL server, the app and the admin use it
instead of the SQLite file, and the grid follows changes through `NOTIFY`
rather than polling.

The app defines one feature flag, `notes_newest_first`, which the admin shows
under **Flags**. `gleam run -m tasks/flags help` lists commands to manage the
flags from a terminal, such as `list`, `kill` and `rollout`; `export` prints
every flag the code defines as JSON without opening the database.

`gleam run` serves the app without hot reload or the admin: both are dev
dependencies and their entry point lives in `dev/`, which
`gleam export erlang-shipment` leaves out.
