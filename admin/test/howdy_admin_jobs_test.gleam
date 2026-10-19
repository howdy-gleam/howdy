//// The jobs pages, driven through the app against an in-memory SQLite
//// database with jobs installed.

import gleam/dynamic/decode
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string
import gloo/adapter/sqlite
import gloo/repo.{type Repo}
import howdy
import howdy/admin
import howdy/admin/internal/config
import howdy/admin/internal/jobs as job_pages
import howdy/database
import howdy/jobs
import howdy/jobs/cron
import howdy/migration
import howdy/testing

fn echo_job() -> jobs.Job(String) {
  jobs.define("echo", encode: json.string, decoder: decode.string)
}

fn nightly() -> jobs.Job(Nil) {
  jobs.without_args("nightly") |> jobs.on_queue("maintenance")
}

fn with_jobs(run: fn(Repo, jobs.Runner, howdy.App) -> a) -> a {
  let assert Ok(db) = sqlite.start(sqlite.memory())
  let assert Ok(Nil) = database.sqlite_defaults(db)
  let assert Ok(Nil) = migration.run(db, [jobs.schema()])
  let assert Ok(daily) = cron.parse("0 3 * * *")
  let runner =
    jobs.runner(db)
    |> jobs.queue("default", concurrency: 4)
    |> jobs.handle(echo_job(), fn(text, _) {
      case text {
        "fail" -> jobs.GiveUp("it was always going to fail")
        _ -> jobs.Done
      }
    })
    |> jobs.handle(nightly(), fn(_, _) { jobs.Done })
    |> jobs.every(daily, run: nightly(), with: Nil)
  let app = howdy.new() |> admin.mount(admin.new() |> admin.jobs(runner))
  let value = run(db, runner, app)
  let assert Ok(_) = repo.close(db)
  value
}

fn get(app: howdy.App, path: String) -> String {
  let res =
    testing.get(path) |> request.set_host("localhost") |> testing.send(app)
  assert res.status == 200
    as { "GET " <> path <> " gave " <> string.inspect(res.status) }
  testing.text(res)
}

fn post(app: howdy.App, path: String) -> #(Int, String) {
  let res =
    testing.post_form(path, [])
    |> request.set_host("localhost")
    |> testing.header("sec-fetch-site", "same-origin")
    |> testing.send(app)
  #(
    res.status,
    list.key_find(res.headers, "location")
      |> option.from_result
      |> option.unwrap(""),
  )
}

fn queue(db: Repo, text: String) -> Int {
  let assert Ok(jobs.Inserted(id)) = jobs.insert(jobs.new(echo_job(), text), db)
  id
}

fn render(runner: jobs.Runner) -> String {
  let config =
    config.Config(
      prefix: "/_howdy",
      name: "test",
      database: option.None,
      identity: option.None,
      authorization: option.None,
      outbox: option.None,
      previews: [],
      mailer: option.None,
      recorder: option.None,
      flags: option.None,
      jobs: Some(runner),
      api: option.None,
      hosts: ["localhost"],
      listen: option.None,
    )
  job_pages.render(config, runner)
}

pub fn hidden_until_registered_test() {
  let bare = howdy.new() |> admin.mount(admin.new())
  let overview = get(bare, "/_howdy")
  assert string.contains(overview, "howdy_jobs")
  assert string.contains(overview, "Not registered. Pass your jobs runner")
  assert !admin.has_jobs(admin.new())
  assert admin.has_jobs(admin.new() |> admin.jobs(jobs.runner(sqlite_repo())))
}

fn sqlite_repo() -> Repo {
  let assert Ok(db) = sqlite.start(sqlite.memory())
  db
}

pub fn overview_and_index_test() {
  use db, runner, app <- with_jobs
  let _ = queue(db, "hello")
  let _ = queue(db, "fail")
  let assert Ok(_) = jobs.drain(runner)
  let _ = queue(db, "waiting")
  let overview = get(app, "/_howdy")
  assert string.contains(overview, "2 queues")
  assert string.contains(overview, "1 waiting")
  assert string.contains(overview, "1 failed")
  let index = get(app, "/_howdy/jobs")
  assert string.contains(index, "/_howdy/live/jobs")
  let live = render(runner)
  // The queues, including the one only a schedule uses.
  assert string.contains(live, "default")
  assert string.contains(live, "maintenance")
  assert string.contains(live, "4 jobs at once")
  // The schedule.
  assert string.contains(live, "0 3 * * *")
  assert string.contains(live, "not yet")
  // The jobs, newest first, with what can be done to them.
  assert string.contains(live, "&quot;waiting&quot;")
  assert string.contains(live, "Failed")
  assert string.contains(live, "Retry")
}

pub fn one_job_test() {
  use db, runner, app <- with_jobs
  let id = queue(db, "fail")
  let assert Ok(_) = jobs.drain(runner)
  let page = get(app, "/_howdy/jobs/job?id=" <> int.to_string(id))
  assert string.contains(page, "echo #" <> int.to_string(id))
  assert string.contains(page, "it was always going to fail")
  assert string.contains(page, "Retry")
  assert string.contains(page, "&quot;fail&quot;")

  let here = "/_howdy/jobs/job?id=" <> int.to_string(id)
  let assert #(303, location) =
    post(app, "/_howdy/jobs/job/retry?id=" <> int.to_string(id))
  assert location == here
  let assert Ok(retried) = jobs.get(db, id)
  assert retried.state == jobs.Available
  let assert #(303, _) =
    post(app, "/_howdy/jobs/job/cancel?id=" <> int.to_string(id))
  let assert Ok(cancelled) = jobs.get(db, id)
  assert cancelled.state == jobs.Cancelled
  // Cancelling again explains itself on the job's page.
  let assert #(200, _) =
    post(app, "/_howdy/jobs/job/cancel?id=" <> int.to_string(id))
  let assert #(303, "/_howdy/jobs") =
    post(app, "/_howdy/jobs/job/delete?id=" <> int.to_string(id))
  let assert Error(_) = jobs.get(db, id)
}

pub fn a_missing_job_test() {
  use _, _, app <- with_jobs
  let res =
    testing.get("/_howdy/jobs/job?id=999")
    |> request.set_host("localhost")
    |> testing.send(app)
  assert string.contains(testing.text(res), "no job has that id")
}
