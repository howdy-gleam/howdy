//// Command-line management of an app's jobs, for servers without the
//// admin. Give it a way to open the app's database, in a task module:
////
//// ```gleam
//// // src/tasks/jobs.gleam
//// import howdy/jobs/cli
////
//// pub fn main() -> Nil {
////   cli.main(fn() { my_app.database() })
//// }
//// ```
////
//// ```sh
//// gleam run -m tasks/jobs stats
//// gleam run -m tasks/jobs retry --failed --job welcome_email
//// ```
////
//// In a release built with `gleam export erlang-shipment`, run it from the
//// release directory, with the arguments after `-extra`:
////
//// ```sh
//// erl -pa */ebin -noshell -eval 'tasks@jobs:main()' -extra stats
//// ```
////
//// Changes go straight to the database, and running nodes see them the
//// next time they look for jobs.

import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import gloo/repo.{type Repo}
import howdy/jobs.{type Record}
import howdy/service

const usage = "Manage background jobs.

Looking:
  stats                        how many jobs each queue has in each state,
                               and which queues are paused
  list                         the newest jobs, filtered by:
    [--state STATE]            available, scheduled, executing, completed,
                               cancelled or failed
    [--queue QUEUE] [--job NAME]
    [--before ID] [--limit N]  older than a job; how many (default 20)
    [--json]
  show ID [--json]             one job in full, with its errors

Changing:
  retry ID...                  run waiting, failed or cancelled jobs now
  retry --failed               every failed job (up to 1000), narrowed by
    [--queue QUEUE] [--job NAME]
  cancel ID...                 jobs that are waiting or running
  delete ID...                 jobs that are not running
  pause QUEUE                  stop every node taking jobs from the queue
  resume QUEUE
  prune [--older-than AGE]     delete jobs that finished longer ago than
                               AGE, such as 30d or 12h (default 7d)
"

/// What a command printed, and its exit status: 0 for success, 1 when the
/// command failed, 2 when it was not understood.
pub type Outcome {
  Outcome(status: Int, output: String)
}

/// Run the command the process was started with, print what it says, and
/// exit with its status.
pub fn main(open: fn() -> service.Result(Repo)) -> Nil {
  let Outcome(status:, output:) = run(open, arguments())
  case status {
    0 -> io.print(output)
    _ -> io.print_error(output)
  }
  halt(status)
}

@external(erlang, "howdy_jobs_ffi", "arguments")
fn arguments() -> List(String)

@external(erlang, "howdy_jobs_ffi", "halt")
fn halt(status: Int) -> Nil

type Options {
  Options(
    state: Option(jobs.State),
    queue: Option(String),
    job: Option(String),
    before: Option(Int),
    limit: Int,
    json: Bool,
    failed: Bool,
    older_than: Int,
  )
}

/// Run one command without printing or exiting.
pub fn run(
  open: fn() -> service.Result(Repo),
  arguments: List(String),
) -> Outcome {
  let options =
    Options(
      state: None,
      queue: None,
      job: None,
      before: None,
      limit: 20,
      json: False,
      failed: False,
      older_than: 7 * 86_400_000,
    )
  case parse_options(arguments, [], options) {
    Error(message) -> misunderstood(message)
    Ok(#(words, options)) -> command(open, words, options)
  }
}

fn parse_options(
  arguments: List(String),
  words: List(String),
  options: Options,
) -> Result(#(List(String), Options), String) {
  case arguments {
    [] -> Ok(#(list.reverse(words), options))
    ["--json", ..rest] ->
      parse_options(rest, words, Options(..options, json: True))
    ["--failed", ..rest] ->
      parse_options(rest, words, Options(..options, failed: True))
    ["--state", state, ..rest] ->
      case jobs.state_from_string(state) {
        Ok(state) ->
          parse_options(rest, words, Options(..options, state: Some(state)))
        Error(Nil) -> Error("unknown state " <> state)
      }
    ["--queue", queue, ..rest] ->
      parse_options(rest, words, Options(..options, queue: Some(queue)))
    ["--job", job, ..rest] ->
      parse_options(rest, words, Options(..options, job: Some(job)))
    ["--before", id, ..rest] ->
      case int.parse(id) {
        Ok(id) ->
          parse_options(rest, words, Options(..options, before: Some(id)))
        Error(Nil) -> Error("--before takes a job id")
      }
    ["--limit", n, ..rest] ->
      case int.parse(n) {
        Ok(limit) if limit > 0 ->
          parse_options(rest, words, Options(..options, limit:))
        _ -> Error("--limit takes a positive number")
      }
    ["--older-than", age, ..rest] ->
      case parse_duration(age) {
        Ok(older_than) ->
          parse_options(rest, words, Options(..options, older_than:))
        Error(Nil) -> Error("--older-than takes an age such as 30d or 12h")
      }
    ["--help", ..] | ["-h", ..] -> Ok(#(["help"], options))
    ["--" <> option, ..] -> Error("unknown option --" <> option)
    [word, ..rest] -> parse_options(rest, [word, ..words], options)
  }
}

fn command(
  open: fn() -> service.Result(Repo),
  words: List(String),
  options: Options,
) -> Outcome {
  case words {
    [] | ["help"] -> Outcome(0, usage)
    ["stats"] -> {
      use repo <- opened(open)
      use counts <- attempt(jobs.counts(repo))
      use paused <- attempt(jobs.paused(repo))
      done(stats(counts, paused))
    }
    ["list"] -> {
      use repo <- opened(open)
      use found <- attempt(jobs.list(repo, listing(options)))
      case options.json {
        True -> done(json.to_string(json.array(found, jobs.record_to_json)))
        False ->
          case found {
            [] -> done("No jobs.")
            _ -> done(list.map(found, line) |> string.join("\n"))
          }
      }
    }
    ["show", id] -> {
      use id <- with_id(id)
      use repo <- opened(open)
      use record <- attempt(jobs.get(repo, id))
      case options.json {
        True -> done(json.to_string(jobs.record_to_json(record)))
        False -> done(show(record))
      }
    }
    ["retry"] if options.failed -> {
      use repo <- opened(open)
      let listing =
        listing(Options(..options, state: Some(jobs.Failed), limit: 1000))
      use failed <- attempt(jobs.list(repo, listing))
      use _ <- attempt(
        list.try_each(failed, fn(job) { jobs.retry(repo, job.id) }),
      )
      done(count(list.length(failed), "job") <> " to run again.")
    }
    ["retry", ..ids] if ids != [] ->
      each_id(open, ids, jobs.retry, "to run again.")
    ["cancel", ..ids] if ids != [] ->
      each_id(open, ids, jobs.cancel, "cancelled.")
    ["delete", ..ids] if ids != [] -> each_id(open, ids, jobs.delete, "deleted.")
    ["pause", queue] -> {
      use repo <- opened(open)
      use _ <- attempt(jobs.pause(repo, queue))
      done("The " <> queue <> " queue is paused.")
    }
    ["resume", queue] -> {
      use repo <- opened(open)
      use _ <- attempt(jobs.resume(repo, queue))
      done("The " <> queue <> " queue is running.")
    }
    ["prune"] -> {
      use repo <- opened(open)
      use deleted <- attempt(jobs.prune(repo, older_than: options.older_than))
      done(count(deleted, "finished job") <> " deleted.")
    }
    _ -> misunderstood("unknown command: " <> string.join(words, " "))
  }
}

fn listing(options: Options) -> jobs.Listing {
  let listing = jobs.listing() |> jobs.limit(options.limit)
  let listing = case options.state {
    Some(state) -> jobs.in_state(listing, state)
    None -> listing
  }
  let listing = case options.queue {
    Some(queue) -> jobs.in_queue(listing, queue)
    None -> listing
  }
  let listing = case options.job {
    Some(name) -> jobs.named(listing, name)
    None -> listing
  }
  case options.before {
    Some(id) -> jobs.before(listing, id)
    None -> listing
  }
}

fn each_id(
  open: fn() -> service.Result(Repo),
  ids: List(String),
  change: fn(Repo, Int) -> service.Result(Nil),
  said: String,
) -> Outcome {
  case list.try_map(ids, int.parse) {
    Error(Nil) -> misunderstood("job ids are numbers")
    Ok(ids) -> {
      use repo <- opened(open)
      use _ <- attempt(list.try_each(ids, change(repo, _)))
      done(count(list.length(ids), "job") <> " " <> said)
    }
  }
}

fn with_id(id: String, next: fn(Int) -> Outcome) -> Outcome {
  case int.parse(id) {
    Ok(id) -> next(id)
    Error(Nil) -> misunderstood("a job id is a number")
  }
}

// -- Output ---------------------------------------------------------------------

fn stats(counts: List(jobs.Count), paused: List(String)) -> String {
  let queues =
    list.map(counts, fn(count) { count.queue })
    |> list.append(paused)
    |> list.unique
    |> list.sort(string.compare)
  case queues {
    [] -> "No jobs."
    _ ->
      list.map(queues, fn(queue) {
        let states =
          list.filter_map(jobs.states, fn(state) {
            case
              list.find(counts, fn(c) { c.queue == queue && c.state == state })
            {
              Ok(c) ->
                Ok(jobs.state_to_string(state) <> " " <> int.to_string(c.count))
              Error(Nil) -> Error(Nil)
            }
          })
        queue
        <> case list.contains(paused, queue) {
          True -> " (paused)"
          False -> ""
        }
        <> "\n  "
        <> case states {
          [] -> "no jobs"
          _ -> string.join(states, ", ")
        }
      })
      |> string.join("\n")
  }
}

fn line(job: Record) -> String {
  string.pad_start(int.to_string(job.id), 6, " ")
  <> "  "
  <> string.pad_end(jobs.state_to_string(job.state), 9, " ")
  <> "  "
  <> job.queue
  <> "/"
  <> job.name
  <> "  attempt "
  <> int.to_string(job.attempt)
  <> "/"
  <> int.to_string(job.max_attempts)
  <> "  "
  <> case job.state {
    jobs.Scheduled | jobs.Available -> "due " <> time(job.scheduled_at)
    _ ->
      case job.finished_at, job.attempted_at {
        Some(at), _ -> "finished " <> time(at)
        None, Some(at) -> "started " <> time(at)
        None, None -> "queued " <> time(job.inserted_at)
      }
  }
}

fn show(job: Record) -> String {
  let optional = fn(label, value: Option(String)) {
    case value {
      Some(value) -> ["  " <> label <> ": " <> value]
      None -> []
    }
  }
  [
    [
      "Job " <> int.to_string(job.id) <> ": " <> job.name,
      "  state: " <> jobs.state_to_string(job.state),
      "  queue: " <> job.queue <> ", priority " <> int.to_string(job.priority),
      "  attempt: "
        <> int.to_string(job.attempt)
        <> " of "
        <> int.to_string(job.max_attempts),
      "  arguments: " <> job.args,
      "  queued: " <> time(job.inserted_at),
      "  due: " <> time(job.scheduled_at),
    ],
    optional("last started", option.map(job.attempted_at, time)),
    optional("by", job.attempted_by),
    optional("finished", option.map(job.finished_at, time)),
    optional("unique key", job.unique_key),
    case job.errors {
      [] -> []
      errors -> [
        "  errors:",
        ..list.map(errors, fn(failure) {
          "    attempt "
          <> int.to_string(failure.attempt)
          <> " at "
          <> time(failure.at)
          <> ": "
          <> failure.reason
        })
      ]
    },
  ]
  |> list.flatten
  |> string.join("\n")
}

fn time(milliseconds: Int) -> String {
  timestamp.from_unix_seconds(milliseconds / 1000)
  |> timestamp.to_rfc3339(calendar.utc_offset)
}

fn count(n: Int, noun: String) -> String {
  int.to_string(n)
  <> " "
  <> noun
  <> case n {
    1 -> ""
    _ -> "s"
  }
}

/// `30d`, `12h`, `15m` or `90s`, in milliseconds.
fn parse_duration(text: String) -> Result(Int, Nil) {
  let #(number, unit) = case string.last(text) {
    Ok("d") -> #(string.drop_end(text, 1), 86_400_000)
    Ok("h") -> #(string.drop_end(text, 1), 3_600_000)
    Ok("m") -> #(string.drop_end(text, 1), 60_000)
    Ok("s") -> #(string.drop_end(text, 1), 1000)
    _ -> #("", 0)
  }
  case int.parse(number) {
    Ok(n) if n >= 0 -> Ok(n * unit)
    _ -> Error(Nil)
  }
}

// -- Plumbing -------------------------------------------------------------------

fn opened(
  open: fn() -> service.Result(Repo),
  next: fn(Repo) -> Outcome,
) -> Outcome {
  case open() {
    Ok(repo) -> next(repo)
    Error(error) ->
      failed("could not open the database: " <> service.message(error))
  }
}

fn attempt(result: service.Result(a), next: fn(a) -> Outcome) -> Outcome {
  case result {
    Ok(value) -> next(value)
    Error(error) -> failed(service.message(error))
  }
}

fn done(output: String) -> Outcome {
  Outcome(0, output <> "\n")
}

fn failed(message: String) -> Outcome {
  Outcome(1, "Error: " <> message <> "\n")
}

fn misunderstood(message: String) -> Outcome {
  Outcome(2, "Error: " <> message <> "\n\n" <> usage)
}
