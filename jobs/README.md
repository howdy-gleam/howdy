# howdy_jobs

Background jobs for [howdy](https://github.com/mikeyjones/howdy/blob/v2.1.1/README.md) apps. Work to be done later is
kept in the app's database, on PostgreSQL or SQLite, and done outside the
request:

- queued inside your own transactions, so a job exists only if the change
  that needs it was committed
- retried with a growing delay, unique while unfinished, delayed, and
  ordered by priority
- run on cron schedules, each time queued once however many nodes run them
- spread across nodes, with a job a lost node left half done run again
- shown in the [admin area](https://github.com/mikeyjones/howdy/blob/v2.1.1/admin/README.md), managed on servers from a
  command line, and traced with [howdy_telemetry](https://github.com/mikeyjones/howdy/blob/v2.1.1/telemetry/README.md)

Add it to `[dependencies]` in `gleam.toml`, from the same release as your
app's other Howdy packages:

```toml
howdy_jobs = { git = "https://github.com/mikeyjones/howdy.git", ref = "v2.1.1", path = "jobs" }
```

and its tables to your migrations: `migration.run(db, [jobs.schema(), ..])`.

## Defining, queueing and doing a job

```gleam
import gleam/dynamic/decode
import gleam/json
import howdy/database
import howdy/jobs

// Defined once, used where it is queued and where it is done.
pub fn welcome_email() -> jobs.Job(String) {
  jobs.define("welcome_email", encode: json.string, decoder: decode.string)
  |> jobs.on_queue("mail")
}

// Queued in the transaction that makes it necessary.
pub fn sign_up(db, form) {
  use conn <- database.transaction(db)
  use user <- result.try(users.insert(conn, form))
  use _ <- result.try(
    jobs.new(welcome_email(), user.id) |> jobs.insert(into: conn),
  )
  Ok(user)
}

// Done by a runner under the app's supervisor.
pub fn runner(db, mailer) -> jobs.Runner {
  jobs.runner(db)
  |> jobs.queue("mail", concurrency: 5)
  |> jobs.handle(welcome_email(), fn(user_id, _attempt) {
    case send_welcome(db, mailer, user_id) {
      Ok(_) -> jobs.Done
      Error(error) -> jobs.Retry(error)
    }
  })
}

supervisor.new(supervisor.OneForOne)
|> supervisor.add(jobs.supervised(runner(db, mailer)))
|> supervisor.add(howdy.supervised(app))
```

A handler says what came of each attempt: `Done`, `Retry`, `RetryIn`,
`Snooze`, `Cancel` or `GiveUp`. A crash or a timeout is a failed attempt,
tried again. Jobs are done at least once: a job whose node stops without
finishing it runs again on another, so make doing one twice harmless.

`jobs.new` takes `after`, `at` and `unique`. `jobs.drain(runner)` does every
due job in the test's own process, for tests.

## Schedules

```gleam
let assert Ok(nightly) = cron.parse("0 3 * * *")

runner
|> jobs.handle(cleanup(), fn(_, _) { clean_up(db) })
|> jobs.every(nightly, run: cleanup(), with: Nil)
```

Five-field cron in UTC, with `@daily` and the like. Each time is queued
once across every node; times missed while no node ran are queued once
when one starts.

## Managing jobs

In development, `admin.jobs(runner)` adds a Jobs page to the admin. On a
server, a task module gives you the command line:

```gleam
// src/tasks/jobs.gleam
import howdy/jobs/cli

pub fn main() -> Nil {
  cli.main(fn() { my_app.open_database() })
}
```

```sh
gleam run -m tasks/jobs stats
gleam run -m tasks/jobs retry --failed --queue mail
gleam run -m tasks/jobs pause mail
```

## Learn more

- [Background jobs](https://github.com/mikeyjones/howdy/blob/v2.1.1/docs/jobs/overview.djot): defining, queueing, outcomes,
  queued email and testing
- [Schedules](https://github.com/mikeyjones/howdy/blob/v2.1.1/docs/jobs/schedules.djot): cron, and keeping auth, uploads and
  old jobs tidy
- [Running jobs](https://github.com/mikeyjones/howdy/blob/v2.1.1/docs/jobs/production.djot): nodes, shutdown, pausing, the
  admin, the command line and traces
