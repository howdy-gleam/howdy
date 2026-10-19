//// Background jobs: work queued in the app's database and done outside the
//// request, tried again when it fails, and run on a schedule.
////
//// ```gleam
//// import howdy/jobs
////
//// // A job is defined once, in code, with how its arguments are stored.
//// pub fn welcome_email() -> jobs.Job(Int) {
////   jobs.define("welcome_email", encode: json.int, decoder: decode.int)
////   |> jobs.on_queue("mailers")
//// }
////
//// // It is queued inside the transaction that makes it necessary: if the
//// // transaction rolls back, the job was never queued.
//// use conn <- database.transaction(repo)
//// use user <- result.try(users.insert(conn, form))
//// use _ <- result.try(jobs.new(welcome_email(), user.id) |> jobs.insert(conn))
//// Ok(user)
////
//// // And done by a runner the app keeps under its supervisor.
//// jobs.runner(repo)
//// |> jobs.queue("mailers", concurrency: 5)
//// |> jobs.handle(welcome_email(), fn(user_id, _attempt) {
////   case send_welcome(mailer, user_id) {
////     Ok(_) -> jobs.Done
////     Error(error) -> jobs.Retry(mail.error_to_string(error))
////   }
//// })
//// |> jobs.supervised
//// ```
////
//// Jobs are kept in the `howdy_jobs` table (apply `schema` with
//// `howdy/migration`), on PostgreSQL or SQLite. Every node running a runner
//// takes due jobs from the queues it has, so the work spreads across them,
//// and a job is only ever taken by one node at a time.
////
//// ## At least once
////
//// A job is done at least once. While a node runs a job it keeps renewing a
//// lease on it; if the node stops without finishing, the lease runs out and
//// another node runs the job again. A job that sends an email, then crashes
//// before saying it is done, sends it twice. Write jobs so that doing them
//// twice is harmless, such as by checking first whether the work is done.
////
//// ## Arguments last
////
//// A job's arguments are stored as JSON and decoded when it runs, which may
//// be after a deploy has changed the decoder. Keep them small, such as IDs
//// rather than whole records, and make decoders accept what older code
//// stored. A job whose arguments cannot be decoded fails without retrying,
//// and can be retried by hand once a fixed decoder is deployed.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/process.{type Name, type Pid, type Subject, type Timer}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import gloo/migration as gloo_migration
import gloo/repo.{type Repo}
import howdy/database
import howdy/database/postgres
import howdy/jobs/cron.{type Cron}
import howdy/jobs/internal/store.{type Row}
import howdy/migration
import howdy/service
import howdy/trace
import logging
import pog

// -- Defining jobs -------------------------------------------------------------

/// A kind of job, taking arguments of type `args`. Define each once, as a
/// function, and use it both where the job is queued and where the runner
/// is told how to do it.
pub opaque type Job(args) {
  Job(
    name: String,
    encode: fn(args) -> Json,
    decoder: Decoder(args),
    queue: String,
    priority: Int,
    max_attempts: Int,
    timeout: Int,
    backoff: fn(Int) -> Int,
  )
}

/// The queue jobs go to unless their definition says otherwise.
pub const default_queue = "default"

/// A job called `name`, whose arguments are stored with `encode` and read
/// back with `decoder`. The name is how stored jobs find their handler, so
/// it must not change once jobs have been queued under it. Names and queue
/// names are letters, digits, `_`, `-`, `.` and `:`, up to 100 characters.
///
/// By default a job goes to the `default` queue at priority 0, is tried up
/// to 20 times with a growing delay between attempts, and is given five
/// minutes for each attempt.
pub fn define(
  name: String,
  encode encode: fn(args) -> Json,
  decoder decoder: Decoder(args),
) -> Job(args) {
  Job(
    name:,
    encode:,
    decoder:,
    queue: default_queue,
    priority: 0,
    max_attempts: 20,
    timeout: 300_000,
    backoff: exponential_backoff,
  )
}

/// A job that takes no arguments, such as a nightly clean-up.
pub fn without_args(name: String) -> Job(Nil) {
  define(name, encode: fn(_) { json.null() }, decoder: decode.success(Nil))
}

pub fn on_queue(job: Job(args), queue: String) -> Job(args) {
  Job(..job, queue:)
}

/// Which due jobs of a queue go first: 0, the default, before 1, and so on
/// to 9. Jobs of the same priority go in the order they became due.
pub fn priority(job: Job(args), priority: Int) -> Job(args) {
  Job(..job, priority: int.clamp(priority, 0, 9))
}

/// How many times the job is tried, counting the first, before it fails
/// for good. At least 1.
pub fn max_attempts(job: Job(args), attempts: Int) -> Job(args) {
  Job(..job, max_attempts: int.max(attempts, 1))
}

/// How long an attempt may take, in milliseconds, before it is stopped and
/// counted as failed.
pub fn timeout(job: Job(args), milliseconds: Int) -> Job(args) {
  Job(..job, timeout: int.max(milliseconds, 1))
}

/// How long to wait before trying again after attempt number `n` failed,
/// in milliseconds. The default doubles from 15 seconds up to six hours.
/// A tenth either way is added at random, so jobs that failed together are
/// not all tried again together.
pub fn backoff(job: Job(args), delay: fn(Int) -> Int) -> Job(args) {
  Job(..job, backoff: delay)
}

pub fn name(job: Job(args)) -> String {
  job.name
}

pub fn queue_of(job: Job(args)) -> String {
  job.queue
}

fn exponential_backoff(attempt: Int) -> Int {
  int.min(
    15_000 * int.bitwise_shift_left(1, int.clamp(attempt - 1, 0, 20)),
    21_600_000,
  )
}

/// Names written into SQL as they are, so they are kept to plain words.
fn valid_name(name: String) -> Bool {
  let length = string.length(name)
  length > 0
  && length <= 100
  && string.to_utf_codepoints(name)
  |> list.all(fn(codepoint) {
    case string.utf_codepoint_to_int(codepoint) {
      c if c >= 0x30 && c <= 0x3A -> True
      c if c >= 0x41 && c <= 0x5A -> True
      c if c >= 0x61 && c <= 0x7A -> True
      0x5F | 0x2D | 0x2E -> True
      _ -> False
    }
  })
}

// -- Queueing ------------------------------------------------------------------

/// A job about to be queued. Build one with `new`.
pub opaque type Insert {
  Insert(
    name: String,
    queue: String,
    args: String,
    priority: Int,
    max_attempts: Int,
    at: When,
    unique: Option(String),
    unique_waiting: Bool,
  )
}

type When {
  Now
  After(Int)
  At(Int)
}

/// The job, to be done with these arguments as soon as a runner can.
pub fn new(job: Job(args), args: args) -> Insert {
  Insert(
    name: job.name,
    queue: job.queue,
    args: json.to_string(job.encode(args)),
    priority: job.priority,
    max_attempts: job.max_attempts,
    at: Now,
    unique: None,
    unique_waiting: False,
  )
}

/// Do it no sooner than `milliseconds` from now.
pub fn after(insert: Insert, milliseconds: Int) -> Insert {
  Insert(..insert, at: After(int.max(milliseconds, 0)))
}

/// Do it no sooner than this time, in unix milliseconds.
pub fn at(insert: Insert, unix_milliseconds: Int) -> Insert {
  Insert(..insert, at: At(unix_milliseconds))
}

/// Queue it only if no unfinished job has the same `key`, such as
/// `"reindex:" <> id`. While one is waiting or running, `insert` gives
/// `Duplicate` with that job's id instead. Once it has finished, the key is
/// free again.
pub fn unique(insert: Insert, key: String) -> Insert {
  Insert(..insert, unique: Some(key), unique_waiting: False)
}

/// Queue it only if no job with the same `key` is waiting to start; one
/// that is running does not count. Work that arrives while a job runs then
/// gets a job of its own, which a job holding the key the whole time would
/// miss: with `after`, a burst of changes is gathered into one job, and a
/// change made while it runs is not lost. `insert` gives `Duplicate` with
/// the waiting job's id when there is one. Keys of `unique` jobs and of
/// these are separate.
pub fn unique_while_waiting(insert: Insert, key: String) -> Insert {
  Insert(..insert, unique: Some(key), unique_waiting: True)
}

/// What `insert` did.
pub type Inserted {
  Inserted(id: Int)
  /// A job holding the same unique key was waiting, or running, already.
  Duplicate(id: Int)
}

/// Queue the job on `conn`. Pass the connection of the transaction that
/// makes the job necessary, and the job is only queued if that commits.
pub fn insert(insert: Insert, into conn: Repo) -> service.Result(Inserted) {
  insert_at(insert, conn, now_ms())
}

/// Queue several jobs, in order, on `conn`.
pub fn insert_all(
  inserts: List(Insert),
  into conn: Repo,
) -> service.Result(List(Inserted)) {
  let now = now_ms()
  list.try_map(inserts, insert_at(_, conn, now))
}

fn insert_at(insert: Insert, conn: Repo, now: Int) -> service.Result(Inserted) {
  use <- bool.guard(
    !valid_name(insert.name),
    Error(service.Invalid("the job name is not a plain word: " <> insert.name)),
  )
  use <- bool.guard(
    !valid_name(insert.queue),
    Error(service.Invalid(
      "the queue name is not a plain word: " <> insert.queue,
    )),
  )
  let scheduled_at = case insert.at {
    Now -> now
    After(delay) -> now + delay
    At(at) -> at
  }
  use <- with_producer_span(insert.name, insert.queue)
  use #(id, new) <- result.try(store.insert(
    conn,
    store.New(
      name: insert.name,
      queue: insert.queue,
      args: insert.args,
      priority: insert.priority,
      max_attempts: insert.max_attempts,
      scheduled_at:,
      inserted_at: now,
      unique_key: insert.unique,
      unique_waiting: insert.unique_waiting,
      traceparent: trace.traceparent(),
    ),
  ))
  case new, scheduled_at <= now {
    True, True -> {
      use _ <- result.map(store.notify(conn, insert.queue))
      wake_soon(insert.queue)
      Inserted(id)
    }
    True, False -> Ok(Inserted(id))
    False, _ -> Ok(Duplicate(id))
  }
}

/// Inside a span that is being recorded, such as a request's, queueing is
/// a span of its own that the job's run links back to.
fn with_producer_span(
  name: String,
  queue: String,
  run: fn() -> service.Result(a),
) -> service.Result(a) {
  case trace.is_recording() {
    False -> run()
    True ->
      trace.new("enqueue " <> name)
      |> trace.kind(trace.Producer)
      |> trace.attributes([
        trace.string("messaging.system", "howdy_jobs"),
        trace.string("messaging.destination.name", queue),
        trace.string("howdy.job.name", name),
      ])
      |> trace.run(run)
  }
}

/// Wake this queue's producers, after the commit when inside a Howdy
/// transaction.
fn wake_soon(queue: String) -> Nil {
  case database.in_transaction() {
    True -> {
      ensure_wake_hook()
      wake_after_commit(queue)
    }
    False -> wake(queue)
  }
}

// -- Doing jobs ----------------------------------------------------------------

/// What became of an attempt at a job.
pub type Outcome {
  Done
  /// It may work later, such as when a service it needs is down. It is
  /// tried again after the job's backoff, unless this was its last attempt.
  Retry(reason: String)
  /// Like `Retry`, after this many milliseconds.
  RetryIn(milliseconds: Int, reason: String)
  /// Not now, and it does not count as an attempt: try it again after this
  /// many milliseconds, such as when a rate limit says to wait.
  Snooze(milliseconds: Int)
  /// It is no longer needed. It is not tried again.
  Cancel(reason: String)
  /// It never will work, such as when the record it is about is gone. It
  /// fails without being tried again.
  GiveUp(reason: String)
}

/// The attempt a handler is asked to make. Times are unix milliseconds.
pub type Attempt {
  Attempt(
    id: Int,
    name: String,
    queue: String,
    /// 1 for the first attempt.
    number: Int,
    max_attempts: Int,
    inserted_at: Int,
    scheduled_at: Int,
    /// What went wrong in earlier attempts, oldest first.
    errors: List(Failure),
  )
}

/// Whether this is the job's last attempt, so a handler can do something
/// different, such as tell someone, before it fails for good.
pub fn is_last(attempt: Attempt) -> Bool {
  attempt.number >= attempt.max_attempts
}

/// Why an attempt did not succeed.
pub type Failure {
  Failure(attempt: Int, at: Int, reason: String)
}

/// The most recent failures a job keeps.
const kept_failures = 20

fn failures_decoder() -> Decoder(List(Failure)) {
  decode.list({
    use attempt <- decode.field("attempt", decode.int)
    use at <- decode.field("at", decode.int)
    use reason <- decode.field("error", decode.string)
    decode.success(Failure(attempt:, at:, reason:))
  })
}

fn failures_to_json(failures: List(Failure)) -> String {
  json.array(failures, fn(failure) {
    json.object([
      #("attempt", json.int(failure.attempt)),
      #("at", json.int(failure.at)),
      #("error", json.string(failure.reason)),
    ])
  })
  |> json.to_string
}

fn read_failures(errors: String) -> List(Failure) {
  json.parse(errors, failures_decoder()) |> result.unwrap([])
}

fn add_failure(errors: String, failure: Failure) -> String {
  let failures = list.append(read_failures(errors), [failure])
  let extra = list.length(failures) - kept_failures
  failures_to_json(case extra > 0 {
    True -> list.drop(failures, extra)
    False -> failures
  })
}

// -- Stored jobs ---------------------------------------------------------------

/// Where a job is. `Available` and `Scheduled` jobs are both waiting; an
/// available one is due now, a scheduled one later, including one waiting
/// to be tried again.
pub type State {
  Available
  Scheduled
  Executing
  Completed
  Cancelled
  Failed
}

pub fn state_to_string(state: State) -> String {
  case state {
    Available -> "available"
    Scheduled -> "scheduled"
    Executing -> "executing"
    Completed -> "completed"
    Cancelled -> "cancelled"
    Failed -> "failed"
  }
}

pub fn state_from_string(text: String) -> Result(State, Nil) {
  case text {
    "available" -> Ok(Available)
    "scheduled" -> Ok(Scheduled)
    "executing" -> Ok(Executing)
    "completed" -> Ok(Completed)
    "cancelled" -> Ok(Cancelled)
    "failed" -> Ok(Failed)
    _ -> Error(Nil)
  }
}

pub const states = [
  Available,
  Scheduled,
  Executing,
  Completed,
  Cancelled,
  Failed,
]

/// A job as it is stored. Times are unix milliseconds; `args` is the JSON
/// the job's arguments were stored as.
pub type Record {
  Record(
    id: Int,
    name: String,
    queue: String,
    args: String,
    state: State,
    priority: Int,
    attempt: Int,
    max_attempts: Int,
    scheduled_at: Int,
    inserted_at: Int,
    attempted_at: Option(Int),
    finished_at: Option(Int),
    attempted_by: Option(String),
    unique_key: Option(String),
    errors: List(Failure),
  )
}

fn record(row: Row, now: Int) -> Record {
  let state = case row.state {
    "available" if row.scheduled_at > now -> Scheduled
    other -> state_from_string(other) |> result.unwrap(Available)
  }
  Record(
    id: row.id,
    name: row.name,
    queue: row.queue,
    args: row.args,
    state:,
    priority: row.priority,
    attempt: row.attempt,
    max_attempts: row.max_attempts,
    scheduled_at: row.scheduled_at,
    inserted_at: row.inserted_at,
    attempted_at: row.attempted_at,
    finished_at: row.finished_at,
    attempted_by: row.attempted_by,
    unique_key: row.unique_key,
    errors: read_failures(row.errors),
  )
}

/// The job as JSON, with its arguments as the JSON they were stored as.
pub fn record_to_json(record: Record) -> Json {
  json.object([
    #("id", json.int(record.id)),
    #("name", json.string(record.name)),
    #("queue", json.string(record.queue)),
    #(
      "args",
      json.parse(record.args, decode.dynamic)
        |> result.map(fn(_) { raw_json(record.args) })
        |> result.unwrap(json.string(record.args)),
    ),
    #("state", json.string(state_to_string(record.state))),
    #("priority", json.int(record.priority)),
    #("attempt", json.int(record.attempt)),
    #("max_attempts", json.int(record.max_attempts)),
    #("scheduled_at", json.int(record.scheduled_at)),
    #("inserted_at", json.int(record.inserted_at)),
    #("attempted_at", json.nullable(record.attempted_at, json.int)),
    #("finished_at", json.nullable(record.finished_at, json.int)),
    #("attempted_by", json.nullable(record.attempted_by, json.string)),
    #("unique_key", json.nullable(record.unique_key, json.string)),
    #(
      "errors",
      json.preprocessed_array(
        list.map(record.errors, fn(failure) {
          json.object([
            #("attempt", json.int(failure.attempt)),
            #("at", json.int(failure.at)),
            #("error", json.string(failure.reason)),
          ])
        }),
      ),
    ),
  ])
}

/// JSON text already known to be valid, placed as it is.
@external(erlang, "howdy_jobs_ffi", "raw_json")
fn raw_json(text: String) -> Json

/// The migrations for the package's tables, all named `howdy_jobs`.
pub fn schema() -> migration.Package {
  migration.Package("howdy_jobs", [
    gloo_migration.new(1, "create_jobs", store.migrations()),
  ])
}

/// Which stored jobs `list` returns. Build one with `listing`.
pub opaque type Listing {
  Listing(filter: store.Filter)
}

/// Every job, newest first, 50 at a time.
pub fn listing() -> Listing {
  Listing(store.Filter(
    state: None,
    scheduled: None,
    queue: None,
    name: None,
    before: None,
    limit: 50,
  ))
}

pub fn in_state(listing: Listing, state: State) -> Listing {
  let #(stored, scheduled) = case state {
    Available -> #("available", Some(False))
    Scheduled -> #("available", Some(True))
    other -> #(state_to_string(other), None)
  }
  Listing(store.Filter(..listing.filter, state: Some(stored), scheduled:))
}

pub fn in_queue(listing: Listing, queue: String) -> Listing {
  Listing(store.Filter(..listing.filter, queue: Some(queue)))
}

pub fn named(listing: Listing, name: String) -> Listing {
  Listing(store.Filter(..listing.filter, name: Some(name)))
}

/// Only jobs older than the one with this id: the next page after it.
pub fn before(listing: Listing, id: Int) -> Listing {
  Listing(store.Filter(..listing.filter, before: Some(id)))
}

pub fn limit(listing: Listing, limit: Int) -> Listing {
  Listing(store.Filter(..listing.filter, limit: int.clamp(limit, 1, 1000)))
}

pub fn list(repo: Repo, listing: Listing) -> service.Result(List(Record)) {
  let now = now_ms()
  store.list(repo, listing.filter, now)
  |> result.map(list.map(_, record(_, now)))
}

pub fn get(repo: Repo, id: Int) -> service.Result(Record) {
  store.get(repo, id) |> result.map(record(_, now_ms()))
}

/// How many jobs a queue has in a state.
pub type Count {
  Count(queue: String, state: State, count: Int)
}

/// How many jobs each queue has in each state, leaving out the states
/// with none.
pub fn counts(repo: Repo) -> service.Result(List(Count)) {
  use rows <- result.map(store.counts(repo, now_ms()))
  list.filter_map(rows, fn(row) {
    let #(queue, state, count) = row
    state_from_string(state) |> result.map(Count(queue, _, count))
  })
}

/// The names of all the jobs stored, of any state.
pub fn stored_names(repo: Repo) -> service.Result(List(String)) {
  store.names(repo)
}

/// Run a waiting, failed or cancelled job as soon as possible, allowing it
/// one more attempt if it has used them all. `NotFound` for a job that is
/// running, has completed or does not exist.
pub fn retry(repo: Repo, id: Int) -> service.Result(Nil) {
  store.retry(repo, id, now_ms())
  |> result.try(found(_, "no waiting, failed or cancelled job has that id"))
  |> result.map(fn(_) { wake_after_change(repo, id) })
}

fn wake_after_change(repo: Repo, id: Int) -> Nil {
  case store.get(repo, id) {
    Ok(row) -> {
      let _ = store.notify(repo, row.queue)
      wake(row.queue)
    }
    Error(_) -> Nil
  }
}

/// Cancel a job that has not finished. A job that is running carries on,
/// but what it returns is ignored.
pub fn cancel(repo: Repo, id: Int) -> service.Result(Nil) {
  store.cancel(repo, id, now_ms())
  |> result.try(found(_, "no waiting or running job has that id"))
}

/// Delete a job that is not running.
pub fn delete(repo: Repo, id: Int) -> service.Result(Nil) {
  store.delete(repo, id)
  |> result.try(found(_, "no job that is not running has that id"))
}

fn found(changed: Bool, otherwise: String) -> service.Result(Nil) {
  case changed {
    True -> Ok(Nil)
    False -> Error(service.NotFound(otherwise))
  }
}

/// Stop every node taking jobs from `queue` until it is resumed. Jobs
/// already running finish.
pub fn pause(repo: Repo, queue: String) -> service.Result(Nil) {
  store.set_paused(repo, queue, True, now_ms())
}

pub fn resume(repo: Repo, queue: String) -> service.Result(Nil) {
  use _ <- result.map(store.set_paused(repo, queue, False, now_ms()))
  let _ = store.notify(repo, queue)
  wake(queue)
}

/// The queues that are paused.
pub fn paused(repo: Repo) -> service.Result(List(String)) {
  store.paused(repo)
}

/// Delete jobs that finished (completed, failed or were cancelled) more
/// than `older_than` milliseconds ago, and say how many. Runners do this
/// themselves, with `keep_finished_for`.
pub fn prune(repo: Repo, older_than milliseconds: Int) -> service.Result(Int) {
  prune_before(repo, now_ms() - milliseconds, 0, 0)
}

fn prune_before(
  repo: Repo,
  before: Int,
  total: Int,
  passes: Int,
) -> service.Result(Int) {
  use deleted <- result.try(store.prune(repo, before, prune_batch))
  case deleted < prune_batch || passes >= 100 {
    True -> Ok(total + deleted)
    False -> prune_before(repo, before, total + deleted, passes + 1)
  }
}

const prune_batch = 1000

// -- Runners -------------------------------------------------------------------

/// What a node does jobs with: its queues, the handler for each kind of
/// job, and the schedules it keeps. Build one with `runner` and run it
/// with `supervised`. Every node can run the same runner.
pub opaque type Runner {
  Runner(
    repo: Repo,
    queues: List(#(String, Int)),
    handlers: Dict(String, Handler),
    schedules: List(Entry),
    interval: Int,
    lease: Int,
    housekeeping: Int,
    retention: Int,
    grace: Int,
    listen: Listen,
    clock: fn() -> Int,
    name: Name(Nil),
  )
}

type Handler {
  Handler(
    name: String,
    queue: String,
    timeout: Int,
    backoff: fn(Int) -> Int,
    run: fn(String, Attempt) -> Outcome,
  )
}

type Entry {
  Entry(key: String, cron: Cron, insert: Insert)
}

type Listen {
  FromPool
  Via(pog.Config)
  NoListening
}

/// A runner for the jobs in `repo`, which must have had `schema` applied.
pub fn runner(repo: Repo) -> Runner {
  Runner(
    repo:,
    queues: [],
    handlers: dict.new(),
    schedules: [],
    interval: 1000,
    lease: 60_000,
    housekeeping: 30_000,
    retention: 7 * 86_400_000,
    grace: 15_000,
    listen: FromPool,
    clock: now_ms,
    name: process.new_name("howdy_jobs_runner"),
  )
}

/// Take jobs from `queue`, running at most `concurrency` of them at once
/// on this node. A queue a handler's job uses is taken from anyway, ten at
/// a time, unless it is given here.
pub fn queue(
  runner: Runner,
  name: String,
  concurrency concurrency: Int,
) -> Runner {
  let queues = list.key_set(runner.queues, name, int.max(concurrency, 1))
  Runner(..runner, queues:)
}

/// Do jobs of this kind with `perform`, which is given the job's arguments
/// and the attempt being made, and says what became of it. A crash is an
/// attempt that failed and is tried again.
pub fn handle(
  runner: Runner,
  job: Job(args),
  perform: fn(args, Attempt) -> Outcome,
) -> Runner {
  let run = fn(args: String, attempt: Attempt) {
    case json.parse(args, job.decoder) {
      Ok(args) -> perform(args, attempt)
      Error(error) ->
        GiveUp("its arguments could not be decoded: " <> string.inspect(error))
    }
  }
  let handler =
    Handler(
      name: job.name,
      queue: job.queue,
      timeout: job.timeout,
      backoff: job.backoff,
      run:,
    )
  let queues = case list.key_find(runner.queues, job.queue) {
    Ok(_) -> runner.queues
    Error(Nil) -> list.append(runner.queues, [#(job.queue, 10)])
  }
  Runner(
    ..runner,
    handlers: dict.insert(runner.handlers, job.name, handler),
    queues:,
  )
}

/// Queue the job with these arguments whenever `cron` comes round. Each
/// time is queued once, whichever nodes run the runner. A time missed while
/// no node was running is queued once when one starts, however many were
/// missed. A schedule new to the database starts from the next time.
pub fn every(
  runner: Runner,
  cron: Cron,
  run job: Job(args),
  with args: args,
) -> Runner {
  let schedule =
    Entry(
      key: job.name <> " " <> cron.to_string(cron),
      cron:,
      insert: new(job, args),
    )
  Runner(..runner, schedules: list.append(runner.schedules, [schedule]))
}

/// How often producers look for due jobs, in milliseconds, besides when a
/// job is queued. Defaults to a second.
pub fn check_every(runner: Runner, milliseconds: Int) -> Runner {
  Runner(..runner, interval: int.max(milliseconds, 10))
}

/// How long a node's claim on a running job lasts without being renewed,
/// in milliseconds. A node renews it every third of this while the job
/// runs, and when a node stops without finishing a job, others run it
/// again after this long. Defaults to a minute.
pub fn lease(runner: Runner, milliseconds: Int) -> Runner {
  Runner(..runner, lease: int.max(milliseconds, 300))
}

/// How long finished jobs are kept, in milliseconds, before the runner
/// deletes them. Defaults to seven days.
pub fn keep_finished_for(runner: Runner, milliseconds: Int) -> Runner {
  Runner(..runner, retention: int.max(milliseconds, 0))
}

/// How long jobs that are running when the runner is stopped get to finish,
/// in milliseconds. Those still running then are stopped and handed back,
/// without counting the attempt. Defaults to 15 seconds.
pub fn shutdown_grace(runner: Runner, milliseconds: Int) -> Runner {
  Runner(..runner, grace: int.max(milliseconds, 0))
}

/// On PostgreSQL, a runner listens for jobs queued by other nodes, using
/// the settings of the Repo's pool. Give the settings here when the pool
/// was not opened through `howdy/database/postgres` or pog.
pub fn listen_via(runner: Runner, config: pog.Config) -> Runner {
  Runner(..runner, listen: Via(config))
}

/// Do not listen on PostgreSQL: rely on `check_every` for jobs other nodes
/// queue.
pub fn without_listening(runner: Runner) -> Runner {
  Runner(..runner, listen: NoListening)
}

/// Use another clock, in unix milliseconds, for tests.
@internal
pub fn with_clock(runner: Runner, clock: fn() -> Int) -> Runner {
  Runner(..runner, clock:)
}

/// How often the runner looks for jobs whose node went quiet and deletes
/// old ones, for tests.
@internal
pub fn housekeep_every(runner: Runner, milliseconds: Int) -> Runner {
  Runner(..runner, housekeeping: milliseconds)
}

pub fn repo(runner: Runner) -> Repo {
  runner.repo
}

/// The queues the runner takes from, with their concurrency.
pub fn queues(runner: Runner) -> List(#(String, Int)) {
  runner.queues
}

/// The names of the jobs the runner has handlers for.
pub fn handled(runner: Runner) -> List(String) {
  dict.keys(runner.handlers) |> list.sort(string.compare)
}

/// A schedule a runner keeps.
pub type Schedule {
  Schedule(
    name: String,
    cron: String,
    queue: String,
    /// The time it last queued a job for, in unix milliseconds.
    last: Option(Int),
    /// When it is next due, in unix milliseconds.
    next: Option(Int),
  )
}

/// The runner's schedules, with when each last ran and runs next.
pub fn schedules(runner: Runner) -> service.Result(List(Schedule)) {
  use stored <- result.map(store.schedules(runner.repo))
  let now = runner.clock()
  list.map(runner.schedules, fn(schedule) {
    let #(from, last) = case list.key_find(stored, schedule.key) {
      Ok(#(from, queued)) -> #(from, option.map(queued, fn(_) { from }))
      Error(Nil) -> #(now, None)
    }
    Schedule(
      name: schedule.insert.name,
      cron: cron.to_string(schedule.cron),
      queue: schedule.insert.queue,
      last:,
      next: cron.next(schedule.cron, from) |> option.from_result,
    )
  })
}

fn check(runner: Runner) -> Result(Nil, String) {
  let names =
    list.flatten([
      list.map(runner.queues, fn(queue) { queue.0 }),
      dict.keys(runner.handlers),
      list.map(runner.schedules, fn(schedule) { schedule.insert.queue }),
    ])
  use <- bool.guard(
    !list.all(names, valid_name),
    Error(
      "howdy/jobs: job and queue names must be plain words: "
      <> string.join(list.filter(names, fn(name) { !valid_name(name) }), ", "),
    ),
  )
  let keys = list.map(runner.schedules, fn(schedule) { schedule.key })
  use <- bool.guard(
    list.length(list.unique(keys)) != list.length(keys),
    Error("howdy/jobs: the same job is scheduled twice with the same cron"),
  )
  let unhandled =
    list.filter(runner.schedules, fn(schedule) {
      !dict.has_key(runner.handlers, schedule.insert.name)
    })
  case unhandled {
    [] -> Ok(Nil)
    [schedule, ..] ->
      Error(
        "howdy/jobs: "
        <> schedule.insert.name
        <> " is scheduled but has no handler on this runner",
      )
  }
}

/// The runner as a child of the app's supervisor, so it starts and stops
/// with the app:
///
/// ```gleam
/// supervisor.new(supervisor.OneForOne)
/// |> supervisor.add(jobs.supervised(runner))
/// |> supervisor.add(howdy.supervised(app))
/// ```
///
/// When it stops, running jobs get `shutdown_grace` to finish.
pub fn supervised(
  runner: Runner,
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  supervision.supervisor(fn() { start(runner) })
}

/// Start the runner linked to the caller. Prefer `supervised`.
pub fn start(
  runner: Runner,
) -> Result(actor.Started(static_supervisor.Supervisor), actor.StartError) {
  use _ <- result.try(check(runner) |> result.map_error(actor.InitFailed))
  ensure_wake_hook()
  let handlers = dict.values(runner.handlers)
  let names = list.map(handlers, fn(handler) { handler.name })
  let children =
    list.map(runner.queues, fn(queue) {
      let #(queue, limit) = queue
      supervision.worker(fn() { start_producer(runner, queue, limit, names) })
      |> supervision.timeout(runner.grace + 5000)
    })
  let children = [
    supervision.worker(fn() { start_housekeeper(runner) }),
    ..children
  ]
  let children = case runner.schedules {
    [] -> children
    _ -> [supervision.worker(fn() { start_scheduler(runner) }), ..children]
  }
  let children = case listener(runner) {
    Some(child) -> [child, ..children]
    None -> children
  }
  use started <- result.try(
    list.fold(
      list.reverse(children),
      static_supervisor.new(static_supervisor.OneForOne),
      fn(builder, child) {
        static_supervisor.add(
          builder,
          supervision.map_data(child, fn(_) { Nil }),
        )
      },
    )
    |> static_supervisor.restart_tolerance(intensity: 10, period: 10)
    |> static_supervisor.start,
  )
  let _ = process.register(started.pid, runner.name)
  Ok(started)
}

/// Stop a runner started with `start`, giving running jobs its
/// `shutdown_grace` to finish.
pub fn stop(runner: Runner) -> Nil {
  case process.named(runner.name) {
    Ok(pid) -> stop_supervisor(pid, runner.grace + 10_000)
    Error(Nil) -> Nil
  }
}

@external(erlang, "howdy_jobs_ffi", "stop_supervisor")
fn stop_supervisor(pid: Pid, timeout: Int) -> Nil

/// On PostgreSQL, a child hearing jobs other nodes queue, through
/// `NOTIFY howdy_jobs`. Without the pool's settings it logs once and does
/// nothing: producers poll.
fn listener(runner: Runner) -> Option(supervision.ChildSpecification(Nil)) {
  case database.backend(runner.repo), runner.listen {
    Ok(database.Postgres), FromPool -> Some(None)
    Ok(database.Postgres), Via(config) -> Some(Some(config))
    _, _ -> None
  }
  |> option.map(fn(settings) {
    supervision.worker(fn() {
      let listening = case settings {
        Some(config) -> postgres.listen_via(config, store.channel, wake)
        None -> postgres.listen(runner.repo, store.channel, wake)
      }
      case listening {
        Ok(listener) ->
          Ok(actor.Started(pid: postgres.listener_pid(listener), data: Nil))
        Error(error) -> {
          logging.log(
            logging.Warning,
            "howdy/jobs: not listening for jobs other nodes queue: "
              <> postgres.listen_error_to_string(error)
              <> ". Producers poll instead.",
          )
          Ok(actor.Started(pid: process.spawn(process.sleep_forever), data: Nil))
        }
      }
    })
  })
}

// -- Producers -----------------------------------------------------------------
// One per queue per node. It claims due jobs while it has room, runs each
// in a process of its own linked to it, renews their leases, and stops
// jobs that run past their timeout.

type Producer {
  Producer(
    runner: Runner,
    queue: String,
    limit: Int,
    names: List(String),
    self: Subject(ProducerMessage),
    running: Dict(Pid, Running),
    /// A fetch is already on its way.
    awake: Bool,
    /// The last claim filled every free slot, so more may be due.
    backlog: Bool,
    /// The runner is stopping: why, once everything has finished.
    stopping: Option(Dynamic),
  )
}

type Running {
  Running(id: Int, attempt: Int, name: String, timer: Timer, timed_out: Bool)
}

type ProducerMessage {
  Tick
  Fetch
  Wake
  Heartbeat
  TimedOut(Pid)
  Exited(process.ExitMessage)
  GraceOver
}

fn start_producer(
  runner: Runner,
  queue: String,
  limit: Int,
  names: List(String),
) -> actor.StartResult(Nil) {
  actor.new_with_initialiser(5000, fn(subject) {
    process.trap_exits(True)
    join(queue, process.self())
    process.send(subject, Tick)
    process.send_after(subject, runner.lease / 3, Heartbeat)
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_record(howdy_jobs_wake, 1, fn(_) { Wake })
      |> process.select_trapped_exits(Exited)
    actor.initialised(Producer(
      runner:,
      queue:,
      limit:,
      names:,
      self: subject,
      running: dict.new(),
      awake: False,
      backlog: False,
      stopping: None,
    ))
    |> actor.selecting(selector)
    |> actor.returning(Nil)
    |> Ok
  })
  |> actor.on_message(produce)
  |> actor.start
}

type WakeTag {
  HowdyJobsWake
}

const howdy_jobs_wake = HowdyJobsWake

fn produce(
  producer: Producer,
  message: ProducerMessage,
) -> actor.Next(Producer, ProducerMessage) {
  case message {
    Tick -> {
      process.send_after(producer.self, producer.runner.interval, Tick)
      actor.continue(fetch(producer))
    }
    // Jobs are often queued in bursts; one fetch a moment later takes them
    // all.
    Wake if producer.awake -> actor.continue(producer)
    Wake -> {
      process.send_after(producer.self, 5, Fetch)
      actor.continue(Producer(..producer, awake: True))
    }
    Fetch -> actor.continue(fetch(Producer(..producer, awake: False)))
    Heartbeat -> {
      process.send_after(producer.self, producer.runner.lease / 3, Heartbeat)
      let ids =
        dict.values(producer.running)
        |> list.map(fn(job) { #(job.id, job.attempt) })
      let runner = producer.runner
      case store.extend(runner.repo, ids, runner.clock() + runner.lease) {
        Ok(Nil) -> Nil
        Error(error) -> warn("could not renew the lease on running jobs", error)
      }
      actor.continue(producer)
    }
    TimedOut(pid) ->
      case dict.get(producer.running, pid) {
        Ok(job) -> {
          // Stopped before anything that may wait on the database, then
          // settled here; the exit the kill brings is let pass.
          process.kill(pid)
          settle_lost(producer.runner, job, "it timed out")
          let job = Running(..job, timed_out: True)
          actor.continue(
            Producer(
              ..producer,
              running: dict.insert(producer.running, pid, job),
            ),
          )
        }
        Error(Nil) -> actor.continue(producer)
      }
    Exited(process.ExitMessage(pid:, reason:)) ->
      case dict.get(producer.running, pid) {
        Ok(job) -> {
          let _ = process.cancel_timer(job.timer)
          let producer =
            Producer(..producer, running: dict.delete(producer.running, pid))
          case reason {
            _ if job.timed_out -> Nil
            process.Normal -> Nil
            process.Killed -> settle_lost(producer.runner, job, "it was killed")
            process.Abnormal(reason) ->
              settle_lost(
                producer.runner,
                job,
                "its process exited: " <> string.inspect(reason),
              )
          }
          after_finish(producer)
        }
        // Not a job of ours: the supervisor is stopping us.
        Error(Nil) -> {
          let reason = exit_reason(reason)
          case dict.is_empty(producer.running) {
            True -> exit(reason)
            False -> {
              process.send_after(
                producer.self,
                producer.runner.grace,
                GraceOver,
              )
              actor.continue(Producer(..producer, stopping: Some(reason)))
            }
          }
        }
      }
    GraceOver -> {
      let jobs = dict.to_list(producer.running)
      list.each(jobs, fn(entry) {
        process.unlink(entry.0)
        process.kill(entry.0)
      })
      case
        store.release(
          producer.runner.repo,
          list.map(jobs, fn(entry) { #({ entry.1 }.id, { entry.1 }.attempt) }),
          producer.runner.clock(),
        )
      {
        Ok(Nil) -> Nil
        Error(error) -> warn("could not hand back running jobs", error)
      }
      exit(option.unwrap(producer.stopping, normal()))
    }
  }
}

fn after_finish(producer: Producer) -> actor.Next(Producer, ProducerMessage) {
  case producer.stopping {
    Some(reason) ->
      case dict.is_empty(producer.running) {
        True -> exit(reason)
        False -> actor.continue(producer)
      }
    None ->
      case producer.backlog {
        True -> actor.continue(fetch(producer))
        False -> actor.continue(producer)
      }
  }
}

fn fetch(producer: Producer) -> Producer {
  let room = producer.limit - dict.size(producer.running)
  use <- bool.guard(
    room <= 0 || option.is_some(producer.stopping) || producer.names == [],
    producer,
  )
  let runner = producer.runner
  let now = runner.clock()
  case
    store.claim(
      runner.repo,
      queue: producer.queue,
      names: producer.names,
      limit: room,
      now:,
      lease_until: now + runner.lease,
      node: node_name(),
    )
  {
    Error(error) -> {
      warn("could not take jobs from the " <> producer.queue <> " queue", error)
      producer
    }
    Ok(rows) -> {
      let running =
        list.fold(rows, producer.running, fn(running, row) {
          case dict.get(runner.handlers, row.name) {
            Error(Nil) -> running
            Ok(handler) -> {
              let pid = process.spawn(fn() { execute(runner, handler, row) })
              let timer =
                process.send_after(
                  producer.self,
                  handler.timeout,
                  TimedOut(pid),
                )
              dict.insert(
                running,
                pid,
                Running(
                  id: row.id,
                  attempt: row.attempt,
                  name: row.name,
                  timer:,
                  timed_out: False,
                ),
              )
            }
          }
        })
      Producer(..producer, running:, backlog: list.length(rows) >= room)
    }
  }
}

/// Record an attempt whose process did not say how it went.
fn settle_lost(runner: Runner, job: Running, reason: String) -> Nil {
  case store.get(runner.repo, job.id) {
    Ok(row) if row.attempt == job.attempt && row.state == "executing" -> {
      let backoff = case dict.get(runner.handlers, job.name) {
        Ok(handler) -> handler.backoff
        Error(Nil) -> exponential_backoff
      }
      let _ = settle(runner, backoff, row, Retry(reason))
      Nil
    }
    _ -> Nil
  }
}

// -- Running one job -------------------------------------------------------------

fn execute(runner: Runner, handler: Handler, row: Row) -> Outcome {
  let attempt =
    Attempt(
      id: row.id,
      name: row.name,
      queue: row.queue,
      number: row.attempt,
      max_attempts: row.max_attempts,
      inserted_at: row.inserted_at,
      scheduled_at: row.scheduled_at,
      errors: read_failures(row.errors),
    )
  let span =
    trace.new("job " <> row.name)
    |> trace.kind(trace.Consumer)
    |> trace.attributes([
      trace.string("messaging.system", "howdy_jobs"),
      trace.string("messaging.destination.name", row.queue),
      trace.string("howdy.job.name", row.name),
      trace.int("howdy.job.id", row.id),
      trace.int("howdy.job.attempt", row.attempt),
    ])
  let span = case option.map(row.traceparent, trace.link_to) {
    Some(Ok(link)) -> trace.link(span, link)
    _ -> span
  }
  use <- trace.run(span)
  let outcome = case rescue(fn() { handler.run(row.args, attempt) }) {
    Ok(outcome) -> outcome
    Error(crash) -> Retry("it crashed: " <> crash)
  }
  case outcome {
    Done | Snooze(_) -> Nil
    Retry(reason) | RetryIn(reason:, ..) | Cancel(reason) | GiveUp(reason) ->
      trace.set_error(reason)
  }
  case settle(runner, handler.backoff, row, outcome) {
    Ok(_) -> Nil
    Error(error) ->
      warn(
        "could not record what became of job " <> int.to_string(row.id),
        error,
      )
  }
  outcome
}

/// Write what became of an attempt, unless the job has moved on since it
/// was claimed, such as by being cancelled.
fn settle(
  runner: Runner,
  backoff: fn(Int) -> Int,
  row: Row,
  outcome: Outcome,
) -> service.Result(Bool) {
  let now = runner.clock()
  let failed = fn(reason) {
    add_failure(row.errors, Failure(attempt: row.attempt, at: now, reason:))
  }
  case outcome {
    Done -> store.complete(runner.repo, row.id, row.attempt, now)
    Snooze(delay) ->
      store.snooze(
        runner.repo,
        row.id,
        row.attempt,
        now + int.max(delay, 0),
        now,
      )
    Retry(reason) | RetryIn(reason:, ..) if row.attempt >= row.max_attempts -> {
      log(logging.Error, row, "failed for good: " <> reason)
      store.finish(
        runner.repo,
        row.id,
        row.attempt,
        "failed",
        now,
        failed(reason),
      )
    }
    Retry(reason) -> {
      log(logging.Warning, row, "failed: " <> reason)
      let delay = jitter(backoff(row.attempt))
      store.reschedule(
        runner.repo,
        row.id,
        row.attempt,
        now + delay,
        failed(reason),
        now,
      )
    }
    RetryIn(milliseconds:, reason:) -> {
      log(logging.Warning, row, "failed: " <> reason)
      store.reschedule(
        runner.repo,
        row.id,
        row.attempt,
        now + int.max(milliseconds, 0),
        failed(reason),
        now,
      )
    }
    Cancel(reason) ->
      store.finish(
        runner.repo,
        row.id,
        row.attempt,
        "cancelled",
        now,
        failed(reason),
      )
    GiveUp(reason) -> {
      log(logging.Error, row, "gave up: " <> reason)
      store.finish(
        runner.repo,
        row.id,
        row.attempt,
        "failed",
        now,
        failed(reason),
      )
    }
  }
}

fn jitter(delay: Int) -> Int {
  let spread = delay / 10
  case spread > 0 {
    True -> delay - spread + int.random(2 * spread + 1)
    False -> delay
  }
}

fn log(level: logging.LogLevel, row: Row, message: String) -> Nil {
  logging.log(
    level,
    "howdy/jobs: "
      <> row.name
      <> " (job "
      <> int.to_string(row.id)
      <> ", attempt "
      <> int.to_string(row.attempt)
      <> " of "
      <> int.to_string(row.max_attempts)
      <> ") "
      <> message,
  )
}

fn warn(doing: String, error: service.Error) -> Nil {
  logging.log(
    logging.Warning,
    "howdy/jobs: " <> doing <> ": " <> service.message(error),
  )
}

// -- Draining, for tests -----------------------------------------------------------

/// What `drain` did.
pub type Drained {
  Drained(
    completed: Int,
    retried: Int,
    snoozed: Int,
    cancelled: Int,
    failed: Int,
  )
}

/// Run every job that is due, in the calling process, one after another,
/// until none are left, including any the jobs queue. For tests: no runner
/// need be started, and the jobs' work is done by the time it returns.
/// Jobs that are tried again later are not waited for.
pub fn drain(runner: Runner) -> service.Result(Drained) {
  use <- bool.guard(dict.is_empty(runner.handlers), Ok(Drained(0, 0, 0, 0, 0)))
  drain_passes(runner, Drained(0, 0, 0, 0, 0), 0)
}

fn drain_passes(
  runner: Runner,
  drained: Drained,
  passes: Int,
) -> service.Result(Drained) {
  let names = dict.keys(runner.handlers)
  let now = runner.clock()
  use rows <- result.try(
    list.try_map(runner.queues, fn(queue) {
      store.claim(
        runner.repo,
        queue: queue.0,
        names:,
        limit: 100,
        now:,
        lease_until: now + runner.lease,
        node: node_name(),
      )
    }),
  )
  case list.flatten(rows) {
    [] -> Ok(drained)
    _ if passes >= 1000 -> Ok(drained)
    rows -> {
      let drained =
        list.fold(rows, drained, fn(drained, row) {
          case dict.get(runner.handlers, row.name) {
            Error(Nil) -> drained
            Ok(handler) ->
              case execute(runner, handler, row) {
                Done -> Drained(..drained, completed: drained.completed + 1)
                Snooze(_) -> Drained(..drained, snoozed: drained.snoozed + 1)
                Cancel(_) ->
                  Drained(..drained, cancelled: drained.cancelled + 1)
                GiveUp(_) -> Drained(..drained, failed: drained.failed + 1)
                Retry(_) | RetryIn(..) if row.attempt >= row.max_attempts ->
                  Drained(..drained, failed: drained.failed + 1)
                Retry(_) | RetryIn(..) ->
                  Drained(..drained, retried: drained.retried + 1)
              }
          }
        })
      drain_passes(runner, drained, passes + 1)
    }
  }
}

// -- Housekeeping ------------------------------------------------------------------
// Puts back jobs whose node went quiet, and deletes finished jobs once
// they are old enough.

type Chore {
  Sweep
}

fn start_housekeeper(runner: Runner) -> actor.StartResult(Nil) {
  actor.new_with_initialiser(1000, fn(subject) {
    process.send_after(subject, int.random(runner.housekeeping) + 1, Sweep)
    actor.initialised(subject)
    |> actor.selecting(process.new_selector() |> process.select(subject))
    |> actor.returning(Nil)
    |> Ok
  })
  |> actor.on_message(fn(subject, _: Chore) {
    case rescue_expired(runner) {
      Ok(_) -> Nil
      Error(error) -> warn("could not rescue jobs whose node went quiet", error)
    }
    case prune_before(runner.repo, runner.clock() - runner.retention, 0, 0) {
      Ok(_) -> Nil
      Error(error) -> warn("could not delete old finished jobs", error)
    }
    process.send_after(subject, jitter(runner.housekeeping), Sweep)
    actor.continue(subject)
  })
  |> actor.start
}

/// Put back executing jobs whose lease ran out, and say how many.
@internal
pub fn rescue_expired(runner: Runner) -> service.Result(Int) {
  let now = runner.clock()
  use conn <- database.write_transaction(runner.repo, touching: store.table)
  use rows <- result.try(store.expired(conn, now, 100))
  use rescued <- result.map(
    list.try_map(rows, fn(row) {
      let reason = case row.attempted_by {
        Some(node) -> "the node running it, " <> node <> ", went quiet"
        None -> "the node running it went quiet"
      }
      let errors =
        add_failure(row.errors, Failure(attempt: row.attempt, at: now, reason:))
      case row.attempt >= row.max_attempts {
        True -> {
          log(logging.Error, row, "failed for good: " <> reason)
          store.finish(conn, row.id, row.attempt, "failed", now, errors)
        }
        False -> {
          log(logging.Warning, row, "will run again: " <> reason)
          store.reschedule(conn, row.id, row.attempt, now, errors, now)
        }
      }
    }),
  )
  list.length(rescued)
}

// -- Schedules ---------------------------------------------------------------------

type Tock {
  Tock
}

fn start_scheduler(runner: Runner) -> actor.StartResult(Nil) {
  actor.new_with_initialiser(1000, fn(subject) {
    process.send(subject, Tock)
    actor.initialised(subject)
    |> actor.selecting(process.new_selector() |> process.select(subject))
    |> actor.returning(Nil)
    |> Ok
  })
  |> actor.on_message(fn(subject, _: Tock) {
    case queue_scheduled(runner) {
      Ok(_) -> Nil
      Error(error) -> warn("could not queue scheduled jobs", error)
    }
    // Just after the next minute begins.
    let now = runner.clock()
    process.send_after(subject, 60_000 - now % 60_000 + 50, Tock)
    actor.continue(subject)
  })
  |> actor.start
}

/// Queue every scheduled job whose time has come since it was last queued,
/// and say how many were queued.
@internal
pub fn queue_scheduled(runner: Runner) -> service.Result(Int) {
  let now = runner.clock()
  list.try_fold(runner.schedules, 0, fn(queued, schedule) {
    use conn <- database.write_transaction(
      runner.repo,
      touching: "howdy_jobs_schedules",
    )
    use last <- result.try(store.schedule_last(conn, schedule.key, now))
    case latest(schedule.cron, last, now) {
      None -> Ok(queued)
      Some(slot) -> {
        use _ <- result.try(store.schedule_ran(conn, schedule.key, slot, now))
        use _ <- result.map(insert_at(at(schedule.insert, slot), conn, now))
        queued + 1
      }
    }
  })
}

/// The latest time the schedule comes round after `last` and no later
/// than `now`.
fn latest(cron: Cron, last: Int, now: Int) -> Option(Int) {
  case cron.next(cron, last) {
    Ok(slot) if slot <= now ->
      case latest(cron, slot, now) {
        Some(later) -> Some(later)
        None -> Some(slot)
      }
    _ -> None
  }
}

// -- Erlang ---------------------------------------------------------------------------

@external(erlang, "howdy_jobs_ffi", "now_ms")
fn now_ms() -> Int

@external(erlang, "howdy_jobs_ffi", "node_name")
fn node_name() -> String

@external(erlang, "howdy_jobs_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, String)

@external(erlang, "howdy_jobs_ffi", "join")
fn join(queue: String, pid: Pid) -> Nil

@external(erlang, "howdy_jobs_ffi", "wake")
fn wake(queue: String) -> Nil

@external(erlang, "howdy_jobs_ffi", "wake_after_commit")
fn wake_after_commit(queue: String) -> Nil

@external(erlang, "howdy_jobs_ffi", "ensure_wake_hook")
fn ensure_wake_hook() -> Nil

@external(erlang, "howdy_jobs_ffi", "exit_reason")
fn exit_reason(reason: process.ExitReason) -> Dynamic

@external(erlang, "howdy_jobs_ffi", "normal")
fn normal() -> Dynamic

@external(erlang, "erlang", "exit")
fn exit(reason: Dynamic) -> a
