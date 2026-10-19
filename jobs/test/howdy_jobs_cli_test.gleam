import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/string
import gloo/adapter/sqlite
import gloo/repo.{type Repo}
import howdy/database
import howdy/jobs
import howdy/jobs/cli.{Outcome}
import howdy/migration
import howdy/service

fn open() -> Repo {
  let assert Ok(db) = sqlite.start(sqlite.memory())
  let assert Ok(Nil) = database.sqlite_defaults(db)
  let assert Ok(Nil) = migration.run(db, [jobs.schema()])
  db
}

fn run(db: Repo, arguments: String) -> cli.Outcome {
  cli.run(fn() { Ok(db) }, string.split(arguments, " "))
}

fn echo_job() -> jobs.Job(String) {
  jobs.define("echo", encode: json.string, decoder: decode.string)
}

fn queue(db: Repo, text: String) -> Int {
  let assert Ok(jobs.Inserted(id)) = jobs.insert(jobs.new(echo_job(), text), db)
  id
}

fn fail_all(db: Repo) -> Nil {
  let assert Ok(_) =
    jobs.runner(db)
    |> jobs.handle(echo_job(), fn(_, _) { jobs.GiveUp("broken") })
    |> jobs.drain
  Nil
}

pub fn help_and_unknown_commands_test() {
  let db = open()
  let assert Outcome(0, "Manage background jobs." <> _) = run(db, "help")
  let assert Outcome(2, "Error: unknown command: frobnicate" <> _) =
    run(db, "frobnicate")
  let assert Outcome(2, "Error: unknown state" <> _) =
    run(db, "list --state sleeping")
}

pub fn stats_and_list_test() {
  let db = open()
  let assert Outcome(0, "No jobs.\n") = run(db, "stats")
  let a = queue(db, "a")
  let _ = queue(db, "b")
  let assert Ok(Nil) = jobs.pause(db, "mailers")
  let assert Outcome(0, stats) = run(db, "stats")
  assert stats == "default\n  available 2\nmailers (paused)\n  no jobs\n"
  let assert Outcome(0, listed) = run(db, "list --limit 1")
  assert string.contains(listed, "available  default/echo  attempt 0/20")
  assert !string.contains(listed, "\n" <> int.to_string(a) <> " ")
  let assert Outcome(0, json) = run(db, "list --json --state available")
  let assert Ok([_, _]) =
    json.parse(
      json,
      decode.list(decode.field("args", decode.string, decode.success)),
    )
}

pub fn show_retry_cancel_delete_test() {
  let db = open()
  let id = queue(db, "a")
  fail_all(db)
  let assert Outcome(0, shown) = run(db, "show " <> int.to_string(id))
  assert string.contains(shown, "state: failed")
  assert string.contains(shown, "arguments: \"a\"")
  assert string.contains(shown, "attempt 1 at ")
  assert string.contains(shown, ": broken")
  let assert Outcome(0, "1 job to run again.\n") =
    run(db, "retry " <> int.to_string(id))
  let assert Outcome(0, "1 job cancelled.\n") =
    run(db, "cancel " <> int.to_string(id))
  let assert Outcome(1, "Error: no waiting or running job has that id\n") =
    run(db, "cancel " <> int.to_string(id))
  let assert Outcome(0, "1 job deleted.\n") =
    run(db, "delete " <> int.to_string(id))
  let assert Outcome(1, _) = run(db, "show " <> int.to_string(id))
  let assert Outcome(2, _) = run(db, "show twelve")
}

pub fn retry_every_failed_job_test() {
  let db = open()
  let _ = queue(db, "a")
  let _ = queue(db, "b")
  fail_all(db)
  let assert Outcome(0, "2 jobs to run again.\n") = run(db, "retry --failed")
  let assert Ok([]) =
    jobs.list(db, jobs.listing() |> jobs.in_state(jobs.Failed))
}

pub fn pause_resume_and_prune_test() {
  let db = open()
  let assert Outcome(0, "The default queue is paused.\n") =
    run(db, "pause default")
  let assert Ok(["default"]) = jobs.paused(db)
  let assert Outcome(0, "The default queue is running.\n") =
    run(db, "resume default")
  let assert Outcome(0, "0 finished jobs deleted.\n") =
    run(db, "prune --older-than 1d")
  let assert Outcome(2, _) = run(db, "prune --older-than soon")
}

pub fn a_database_that_will_not_open_test() {
  let assert Outcome(1, "Error: could not open the database: " <> _) =
    cli.run(fn() { Error(service.Internal("down")) }, ["stats"])
}
