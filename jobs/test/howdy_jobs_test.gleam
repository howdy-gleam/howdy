import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleeunit
import gloo/adapter/sqlite
import gloo/repo.{type Repo}
import howdy/database
import howdy/database/postgres
import howdy/jobs.{
  Available, Cancelled, Completed, Count, Done, Drained, Duplicate, Executing,
  Failed, GiveUp, Inserted, Retry, RetryIn, Scheduled, Snooze,
}
import howdy/jobs/cron
import howdy/migration
import howdy/service

pub fn main() {
  gleeunit.main()
}

@external(erlang, "howdy_jobs_test_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

/// SQLite in memory, or a PostgreSQL database emptied of the package's
/// rows when `HOWDY_JOBS_TEST_POSTGRES_URL` is set. The PostgreSQL pool is
/// opened and migrated once and kept for the whole run.
fn open() -> Repo {
  case getenv("HOWDY_JOBS_TEST_POSTGRES_URL") {
    Error(Nil) -> {
      let assert Ok(db) = sqlite.start(sqlite.memory())
      let assert Ok(Nil) = database.sqlite_defaults(db)
      let assert Ok(Nil) = migration.run(db, [jobs.schema()])
      let assert Ok(Nil) = migration.check(db, jobs.schema())
      db
    }
    Ok(url) -> {
      let db = case kept() {
        Ok(db) -> db
        Error(Nil) -> {
          // The pool is linked to the process that starts it, and each test
          // runs in a process of its own, so a process that never exits
          // starts it.
          let started = process.new_subject()
          process.spawn_unlinked(fn() {
            let assert Ok(db) =
              postgres.from_url(url) |> result.try(postgres.start)
            process.send(started, db)
            process.sleep_forever()
          })
          let assert Ok(db) = process.receive(started, 10_000)
          let assert Ok(Nil) =
            database.exec(
              db,
              "DROP TABLE IF EXISTS howdy_jobs, howdy_jobs_queues,
                howdy_jobs_schedules;
              CREATE TABLE IF NOT EXISTS howdy_migrations (package TEXT NOT NULL, version BIGINT NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(package, version));
              CREATE TABLE IF NOT EXISTS howdy_migration_schemas (package TEXT PRIMARY KEY NOT NULL, fingerprint TEXT NOT NULL);
              DELETE FROM howdy_migrations WHERE package = 'howdy_jobs';
              DELETE FROM howdy_migration_schemas WHERE package = 'howdy_jobs'",
            )
          let assert Ok(Nil) = migration.run(db, [jobs.schema()])
          let assert Ok(Nil) = migration.check(db, jobs.schema())
          keep(db)
          db
        }
      }
      let assert Ok(Nil) =
        database.exec(
          db,
          "TRUNCATE howdy_jobs, howdy_jobs_queues, howdy_jobs_schedules",
        )
      db
    }
  }
}

@external(erlang, "howdy_jobs_test_ffi", "kept")
fn kept() -> Result(Repo, Nil)

@external(erlang, "howdy_jobs_test_ffi", "keep")
fn keep(db: Repo) -> Nil

type Clock

@external(erlang, "howdy_jobs_test_ffi", "new_clock")
fn new_clock() -> Clock

@external(erlang, "howdy_jobs_test_ffi", "read_clock")
fn read_clock(clock: Clock) -> Int

@external(erlang, "howdy_jobs_test_ffi", "advance")
fn advance(clock: Clock, milliseconds: Int) -> Nil

@external(erlang, "howdy_jobs_test_ffi", "now_ms")
fn now_ms() -> Int

// -- Jobs used by the tests -------------------------------------------------------

fn echo_job() -> jobs.Job(String) {
  jobs.define("echo", encode: json.string, decoder: decode.string)
}

fn tally_job() -> jobs.Job(Int) {
  jobs.define("tally", encode: json.int, decoder: decode.int)
  |> jobs.on_queue("tallies")
  |> jobs.max_attempts(3)
}

/// A runner whose handlers report each call to `seen`.
fn runner(
  db: Repo,
  clock: Clock,
  seen: process.Subject(#(String, Int)),
  outcome: fn(String, jobs.Attempt) -> jobs.Outcome,
) -> jobs.Runner {
  jobs.runner(db)
  |> jobs.with_clock(fn() { read_clock(clock) })
  |> jobs.handle(echo_job(), fn(text, attempt) {
    process.send(seen, #(text, attempt.number))
    outcome(text, attempt)
  })
}

fn drained(runner: jobs.Runner) -> jobs.Drained {
  let assert Ok(drained) = jobs.drain(runner)
  drained
}

fn received(seen: process.Subject(a)) -> List(a) {
  case process.receive(seen, 0) {
    Ok(message) -> [message, ..received(seen)]
    Error(Nil) -> []
  }
}

fn queue(db: Repo, job: jobs.Insert) -> Int {
  let assert Ok(Inserted(id)) = jobs.insert(job, into: db)
  id
}

fn record(db: Repo, id: Int) -> jobs.Record {
  let assert Ok(record) = jobs.get(db, id)
  record
}

// -- Queueing and doing ------------------------------------------------------------

pub fn a_queued_job_is_done_with_its_arguments_test() {
  let db = open()
  let seen = process.new_subject()
  let runner = runner(db, new_clock(), seen, fn(_, _) { Done })
  let id = queue(db, jobs.new(echo_job(), "hello"))
  assert record(db, id).state == Available
  assert drained(runner) == Drained(1, 0, 0, 0, 0)
  assert received(seen) == [#("hello", 1)]
  let done = record(db, id)
  assert done.state == Completed
  assert done.attempt == 1
  assert option.is_some(done.finished_at)
  // Nothing is left to do.
  assert drained(runner) == Drained(0, 0, 0, 0, 0)
}

pub fn a_job_queued_in_a_transaction_that_rolls_back_never_was_test() {
  let db = open()
  let assert Error(service.Invalid("no")) =
    database.transaction(db, fn(conn) {
      let assert Ok(_) = jobs.insert(jobs.new(echo_job(), "lost"), into: conn)
      Error(service.Invalid("no"))
    })
  let assert Ok(Inserted(_)) =
    database.transaction(db, fn(conn) {
      jobs.insert(jobs.new(echo_job(), "kept"), into: conn)
    })
  let assert Ok(all) = jobs.list(db, jobs.listing())
  assert list.map(all, fn(job) { job.args }) == ["\"kept\""]
}

pub fn unique_jobs_are_queued_once_while_unfinished_test() {
  let db = open()
  let seen = process.new_subject()
  let runner = runner(db, new_clock(), seen, fn(_, _) { Done })
  let first = queue(db, jobs.new(echo_job(), "a") |> jobs.unique("same"))
  let assert Ok(Duplicate(again)) =
    jobs.insert(jobs.new(echo_job(), "b") |> jobs.unique("same"), into: db)
  assert again == first
  assert drained(runner).completed == 1
  // Finished, the key is free again.
  let assert Ok(Inserted(later)) =
    jobs.insert(jobs.new(echo_job(), "c") |> jobs.unique("same"), into: db)
  assert later != first
}

pub fn delayed_jobs_wait_their_turn_test() {
  let db = open()
  let clock = new_clock()
  let seen = process.new_subject()
  let runner = runner(db, clock, seen, fn(_, _) { Done })
  let id = queue(db, jobs.new(echo_job(), "later") |> jobs.after(60_000))
  assert record(db, id).state == Scheduled
  assert drained(runner).completed == 0
  advance(clock, 61_000)
  assert drained(runner).completed == 1
  let _ = queue(db, jobs.new(echo_job(), "at") |> jobs.at(now_ms() + 120_000))
  assert drained(runner).completed == 0
  advance(clock, 120_000)
  assert drained(runner).completed == 1
}

pub fn higher_priority_goes_first_test() {
  let db = open()
  let seen = process.new_subject()
  let runner = runner(db, new_clock(), seen, fn(_, _) { Done })
  let low = jobs.define("echo", encode: json.string, decoder: decode.string)
  let _ = queue(db, jobs.new(low |> jobs.priority(5), "low"))
  let _ = queue(db, jobs.new(low |> jobs.priority(0), "high"))
  let _ = queue(db, jobs.new(low |> jobs.priority(5), "low again"))
  let _ = drained(runner)
  assert received(seen) == [#("high", 1), #("low", 1), #("low again", 1)]
}

pub fn jobs_without_a_handler_here_are_left_alone_test() {
  let db = open()
  let seen = process.new_subject()
  let runner = runner(db, new_clock(), seen, fn(_, _) { Done })
  let other = jobs.without_args("someone_elses")
  let id = queue(db, jobs.new(other, Nil))
  assert drained(runner) == Drained(0, 0, 0, 0, 0)
  assert record(db, id).state == Available
}

pub fn invalid_names_are_refused_test() {
  let db = open()
  let bad = jobs.without_args("drop table'")
  let assert Error(service.Invalid(_)) = jobs.insert(jobs.new(bad, Nil), db)
  let assert Error(_) =
    jobs.runner(db) |> jobs.handle(bad, fn(_, _) { Done }) |> jobs.start
}

// -- When it does not work -----------------------------------------------------------

pub fn failures_are_retried_after_a_backoff_test() {
  let db = open()
  let clock = new_clock()
  let seen = process.new_subject()
  let runner =
    runner(db, clock, seen, fn(_, attempt) {
      case attempt.number {
        1 -> Retry("down")
        _ -> Done
      }
    })
  let id = queue(db, jobs.new(echo_job(), "x"))
  assert drained(runner) == Drained(0, 1, 0, 0, 0)
  let waiting = record(db, id)
  assert waiting.state == Scheduled
  assert waiting.attempt == 1
  let assert [jobs.Failure(attempt: 1, reason: "down", ..)] = waiting.errors
  // The first retry waits 15 seconds, give or take a tenth.
  assert waiting.scheduled_at >= read_clock(clock) + 13_000
  assert waiting.scheduled_at <= read_clock(clock) + 17_000
  assert drained(runner).completed == 0
  advance(clock, 17_000)
  assert drained(runner).completed == 1
  assert received(seen) == [#("x", 1), #("x", 2)]
  assert record(db, id).state == Completed
}

pub fn a_job_fails_for_good_after_its_last_attempt_test() {
  let db = open()
  let clock = new_clock()
  let runner =
    jobs.runner(db)
    |> jobs.with_clock(fn() { read_clock(clock) })
    |> jobs.handle(tally_job(), fn(_, _) { RetryIn(1000, "nope") })
  let id = queue(db, jobs.new(tally_job(), 1))
  assert drained(runner).retried == 1
  advance(clock, 1000)
  assert drained(runner).retried == 1
  advance(clock, 1000)
  assert drained(runner).failed == 1
  let failed = record(db, id)
  assert failed.state == Failed
  assert failed.attempt == 3
  assert list.map(failed.errors, fn(failure) { failure.attempt }) == [1, 2, 3]
}

pub fn a_crash_is_a_failed_attempt_test() {
  let db = open()
  let seen = process.new_subject()
  let runner = runner(db, new_clock(), seen, fn(_, _) { panic as "boom" })
  let id = queue(db, jobs.new(echo_job(), "x"))
  assert drained(runner).retried == 1
  let assert [jobs.Failure(reason:, ..)] = record(db, id).errors
  let assert "it crashed: " <> _ = reason
}

pub fn snoozing_does_not_use_an_attempt_test() {
  let db = open()
  let clock = new_clock()
  let seen = process.new_subject()
  let runner =
    runner(db, clock, seen, fn(_, attempt) {
      case attempt.number, received_before(attempt) {
        1, False -> Snooze(5000)
        _, _ -> Done
      }
    })
  let id = queue(db, jobs.new(echo_job(), "x"))
  assert drained(runner).snoozed == 1
  let snoozed = record(db, id)
  assert snoozed.state == Scheduled
  assert snoozed.attempt == 0
  assert snoozed.errors == []
  advance(clock, 5000)
  assert drained(runner).completed == 1
  // Both runs were the first attempt.
  assert received(seen) == [#("x", 1), #("x", 1)]
}

/// Whether this job has been snoozed: its schedule moved past its insert.
fn received_before(attempt: jobs.Attempt) -> Bool {
  attempt.scheduled_at > attempt.inserted_at
}

pub fn cancelling_and_giving_up_test() {
  let db = open()
  let seen = process.new_subject()
  let runner =
    runner(db, new_clock(), seen, fn(text, _) {
      case text {
        "cancel" -> jobs.Cancel("not needed")
        _ -> GiveUp("never")
      }
    })
  let cancelled = queue(db, jobs.new(echo_job(), "cancel"))
  let given_up = queue(db, jobs.new(echo_job(), "give up"))
  assert drained(runner) == Drained(0, 0, 0, 1, 1)
  assert record(db, cancelled).state == Cancelled
  assert record(db, given_up).state == Failed
}

pub fn arguments_that_cannot_be_decoded_fail_test() {
  let db = open()
  let seen = process.new_subject()
  let runner = runner(db, new_clock(), seen, fn(_, _) { Done })
  // Stored by an older version of the job, which took a number.
  let older = jobs.define("echo", encode: json.int, decoder: decode.int)
  let id = queue(db, jobs.new(older, 7))
  assert drained(runner).failed == 1
  let assert [
    jobs.Failure(reason: "its arguments could not be decoded: " <> _, ..),
  ] = record(db, id).errors
  assert received(seen) == []
}

// -- Managing jobs ----------------------------------------------------------------------

pub fn retrying_cancelling_and_deleting_by_hand_test() {
  let db = open()
  let seen = process.new_subject()
  let runner = runner(db, new_clock(), seen, fn(_, _) { GiveUp("no") })
  let id = queue(db, jobs.new(echo_job(), "x"))
  let _ = drained(runner)
  assert record(db, id).state == Failed
  // Retried by hand, even with no attempts left.
  let assert Ok(Nil) = jobs.retry(db, id)
  let retried = record(db, id)
  assert retried.state == Available
  assert retried.max_attempts == 20
  let assert Ok(Nil) = jobs.cancel(db, id)
  assert record(db, id).state == Cancelled
  let assert Error(service.NotFound(_)) = jobs.cancel(db, id)
  let assert Ok(Nil) = jobs.delete(db, id)
  let assert Error(service.NotFound(_)) = jobs.get(db, id)
  let assert Error(service.NotFound(_)) = jobs.retry(db, id)
}

pub fn retrying_a_job_that_used_every_attempt_allows_one_more_test() {
  let db = open()
  let runner =
    jobs.runner(db)
    |> jobs.handle(tally_job() |> jobs.max_attempts(1), fn(_, _) { Retry("x") })
  let id = queue(db, jobs.new(tally_job() |> jobs.max_attempts(1), 1))
  assert drained(runner).failed == 1
  let assert Ok(Nil) = jobs.retry(db, id)
  assert record(db, id).max_attempts == 2
}

pub fn listing_and_counting_test() {
  let db = open()
  let _ = queue(db, jobs.new(echo_job(), "a"))
  let _ = queue(db, jobs.new(echo_job(), "b") |> jobs.after(60_000))
  let t = queue(db, jobs.new(tally_job(), 1))
  let assert Ok(all) = jobs.list(db, jobs.listing())
  assert list.length(all) == 3
  // Newest first.
  let assert [first, ..] = all
  assert first.id == t
  let assert Ok([scheduled]) =
    jobs.list(db, jobs.listing() |> jobs.in_state(Scheduled))
  assert scheduled.args == "\"b\""
  let assert Ok([available]) =
    jobs.list(
      db,
      jobs.listing() |> jobs.in_state(Available) |> jobs.in_queue("default"),
    )
  assert available.args == "\"a\""
  let assert Ok([tally]) = jobs.list(db, jobs.listing() |> jobs.named("tally"))
  assert tally.queue == "tallies"
  let assert Ok(page) =
    jobs.list(db, jobs.listing() |> jobs.before(t) |> jobs.limit(1))
  assert list.length(page) == 1
  let assert Ok(counts) = jobs.counts(db)
  assert list.sort(counts, fn(a, b) {
      case a.queue == b.queue {
        True -> compare_states(a.state, b.state)
        False -> string.compare(a.queue, b.queue)
      }
    })
    == [
      Count("default", Available, 1),
      Count("default", Scheduled, 1),
      Count("tallies", Available, 1),
    ]
  let assert Ok(names) = jobs.stored_names(db)
  assert names == ["echo", "tally"]
}

fn compare_states(a: jobs.State, b: jobs.State) -> order.Order {
  string.compare(jobs.state_to_string(a), jobs.state_to_string(b))
}

pub fn paused_queues_are_left_alone_test() {
  let db = open()
  let seen = process.new_subject()
  let runner = runner(db, new_clock(), seen, fn(_, _) { Done })
  let _ = queue(db, jobs.new(echo_job(), "x"))
  let assert Ok(Nil) = jobs.pause(db, "default")
  let assert Ok(["default"]) = jobs.paused(db)
  assert drained(runner).completed == 0
  let assert Ok(Nil) = jobs.resume(db, "default")
  let assert Ok([]) = jobs.paused(db)
  assert drained(runner).completed == 1
}

pub fn pruning_finished_jobs_test() {
  let db = open()
  let seen = process.new_subject()
  let runner = runner(db, new_clock(), seen, fn(_, _) { Done })
  let _ = queue(db, jobs.new(echo_job(), "done"))
  let _ = drained(runner)
  let waiting = queue(db, jobs.new(echo_job(), "waiting") |> jobs.after(60_000))
  let assert Ok(0) = jobs.prune(db, older_than: 60_000)
  process.sleep(5)
  let assert Ok(1) = jobs.prune(db, older_than: 0)
  let assert Ok([left]) = jobs.list(db, jobs.listing())
  assert left.id == waiting
}

// -- Nodes that go quiet -----------------------------------------------------------------

pub fn jobs_whose_lease_ran_out_are_put_back_test() {
  let db = open()
  let clock = new_clock()
  let seen = process.new_subject()
  let runner = runner(db, clock, seen, fn(_, _) { Done }) |> jobs.lease(10_000)
  let id = queue(db, jobs.new(echo_job(), "x"))
  // Claimed by a node that then went quiet: started and stopped at once,
  // without the grace to hand it back.
  let started =
    runner
    |> jobs.queue("default", concurrency: 1)
    |> jobs.handle(echo_job(), fn(_, _) {
      process.sleep(60_000)
      Done
    })
    |> jobs.shutdown_grace(0)
  let assert Ok(_) = jobs.start(started)
  let assert Ok(Nil) = wait_for(fn() { record(db, id).state == Executing })
  stop_without_handing_back(started, db, id)
  let assert Ok(0) = jobs.rescue_expired(runner)
  advance(clock, 10_001)
  let assert Ok(1) = jobs.rescue_expired(runner)
  let rescued = record(db, id)
  // Due at once, by the runner's clock.
  assert rescued.state != Executing
  assert rescued.scheduled_at <= read_clock(clock)
  let assert [jobs.Failure(attempt: 1, reason:, ..)] = rescued.errors
  let assert "the node running it, " <> _ = reason
  assert drained(runner).completed == 1
  assert record(db, id).attempt == 2
}

/// Stop a runner, then mark its job as still executing, as if the node had
/// died rather than stopped.
fn stop_without_handing_back(runner: jobs.Runner, db: Repo, id: Int) -> Nil {
  jobs.stop(runner)
  let assert Ok(Nil) =
    database.execute(
      db,
      "UPDATE howdy_jobs SET state = 'executing', attempt = 1, lease_until = "
        <> int.to_string(now_ms() + 10_000)
        <> " WHERE id = "
        <> int.to_string(id),
      [],
    )
  Nil
}

fn wait_for(condition: fn() -> Bool) -> Result(Nil, Nil) {
  wait_until(condition, 300)
}

fn wait_until(condition: fn() -> Bool, tries: Int) -> Result(Nil, Nil) {
  case condition() {
    True -> Ok(Nil)
    False if tries <= 0 -> Error(Nil)
    False -> {
      process.sleep(10)
      wait_until(condition, tries - 1)
    }
  }
}

// -- Running for real -------------------------------------------------------------------

pub fn a_started_runner_does_jobs_as_they_are_queued_test() {
  let db = open()
  let seen = process.new_subject()
  // Without the wake on insert, the first poll would be a minute away.
  let runner =
    runner(db, new_clock(), seen, fn(_, _) { Done })
    |> jobs.check_every(60_000)
  let assert Ok(_) = jobs.start(runner)
  process.sleep(50)
  let id = queue(db, jobs.new(echo_job(), "now"))
  let assert Ok(#("now", 1)) = process.receive(seen, 2000)
  let assert Ok(Nil) = wait_for(fn() { record(db, id).state == Completed })
  jobs.stop(runner)
}

pub fn a_job_queued_in_a_transaction_wakes_the_runner_on_commit_test() {
  let db = open()
  let seen = process.new_subject()
  let runner =
    runner(db, new_clock(), seen, fn(_, _) { Done })
    |> jobs.check_every(60_000)
  let assert Ok(_) = jobs.start(runner)
  process.sleep(50)
  let assert Ok(_) =
    database.transaction(db, fn(conn) {
      use inserted <- result.try(jobs.insert(
        jobs.new(echo_job(), "committed"),
        into: conn,
      ))
      // Still uncommitted: nobody has been told.
      process.sleep(100)
      Ok(inserted)
    })
  let assert Ok(#("committed", 1)) = process.receive(seen, 2000)
  jobs.stop(runner)
}

pub fn concurrency_limits_how_many_run_at_once_test() {
  let db = open()
  let running = process.new_subject()
  let runner =
    jobs.runner(db)
    |> jobs.queue("tallies", concurrency: 2)
    |> jobs.handle(tally_job(), fn(_, _) {
      let gate = process.new_subject()
      process.send(running, gate)
      let _ = process.receive(gate, 5000)
      Done
    })
  list.each([1, 2, 3, 4], fn(n) { queue(db, jobs.new(tally_job(), n)) })
  let assert Ok(_) = jobs.start(runner)
  let assert Ok(first) = process.receive(running, 2000)
  let assert Ok(second) = process.receive(running, 2000)
  let assert Error(Nil) = process.receive(running, 200)
  process.send(first, Nil)
  let assert Ok(third) = process.receive(running, 2000)
  let assert Error(Nil) = process.receive(running, 200)
  process.send(second, Nil)
  process.send(third, Nil)
  let assert Ok(fourth) = process.receive(running, 2000)
  process.send(fourth, Nil)
  let assert Ok(Nil) =
    wait_for(fn() {
      let assert Ok(done) =
        jobs.list(db, jobs.listing() |> jobs.in_state(Completed))
      list.length(done) == 4
    })
  jobs.stop(runner)
}

pub fn an_attempt_that_runs_too_long_is_stopped_test() {
  let db = open()
  let slow = tally_job() |> jobs.timeout(100)
  let runner =
    jobs.runner(db)
    |> jobs.handle(slow, fn(_, _) {
      process.sleep(10_000)
      Done
    })
  let id = queue(db, jobs.new(slow, 1))
  let assert Ok(_) = jobs.start(runner)
  let assert Ok(Nil) = wait_for(fn() { record(db, id).errors != [] })
  let timed_out = record(db, id)
  assert timed_out.state == Scheduled
  let assert [jobs.Failure(reason: "it timed out", ..)] = timed_out.errors
  jobs.stop(runner)
}

pub fn stopping_hands_back_jobs_that_do_not_finish_in_time_test() {
  let db = open()
  let started = process.new_subject()
  let runner =
    jobs.runner(db)
    |> jobs.shutdown_grace(100)
    |> jobs.handle(tally_job(), fn(n, _) {
      process.send(started, n)
      case n {
        1 -> process.sleep(50)
        _ -> process.sleep(10_000)
      }
      Done
    })
  let quick = queue(db, jobs.new(tally_job(), 1))
  let slow = queue(db, jobs.new(tally_job(), 2))
  let assert Ok(_) = jobs.start(runner)
  let assert Ok(_) = process.receive(started, 2000)
  let assert Ok(_) = process.receive(started, 2000)
  jobs.stop(runner)
  // The quick one finished within the grace...
  assert record(db, quick).state == Completed
  // ...the slow one was handed back, its attempt not counted.
  let handed_back = record(db, slow)
  assert handed_back.state == Available
  assert handed_back.attempt == 0
}

// -- Schedules ---------------------------------------------------------------------------

pub fn scheduled_jobs_are_queued_once_per_time_test() {
  let db = open()
  let clock = new_clock()
  let assert Ok(every_minute) = cron.parse("* * * * *")
  let nightly = jobs.without_args("nightly")
  let runner =
    jobs.runner(db)
    |> jobs.with_clock(fn() { read_clock(clock) })
    |> jobs.handle(nightly, fn(_, _) { Done })
    |> jobs.every(every_minute, run: nightly, with: Nil)
  // New to the database: it starts from the next minute.
  let assert Ok(0) = jobs.queue_scheduled(runner)
  let assert Ok([jobs.Schedule(last: None, next: Some(_), ..)]) =
    jobs.schedules(runner)
  advance(clock, 60_000)
  let assert Ok(1) = jobs.queue_scheduled(runner)
  // Another node at the same time finds it done.
  let assert Ok(0) = jobs.queue_scheduled(runner)
  // Many minutes missed: queued once.
  advance(clock, 10 * 60_000)
  let assert Ok(1) = jobs.queue_scheduled(runner)
  assert drained(runner).completed == 2
  let assert Ok([schedule]) = jobs.schedules(runner)
  assert schedule.name == "nightly"
  assert schedule.cron == "* * * * *"
  let assert Some(last) = schedule.last
  let assert Some(next) = schedule.next
  assert next == last + 60_000
}

pub fn a_scheduled_job_needs_a_handler_test() {
  let db = open()
  let assert Ok(daily) = cron.parse("@daily")
  let assert Error(_) =
    jobs.runner(db)
    |> jobs.every(daily, run: jobs.without_args("orphan"), with: Nil)
    |> jobs.start
  Nil
}

pub fn listing_schedules_before_they_have_run_test() {
  let db = open()
  let assert Ok(daily) = cron.parse("@daily")
  let job = jobs.without_args("daily")
  let runner =
    jobs.runner(db)
    |> jobs.handle(job, fn(_, _) { Done })
    |> jobs.every(daily, run: job, with: Nil)
  let assert Ok([schedule]) = jobs.schedules(runner)
  assert schedule.last == None
  let assert Some(_) = schedule.next
}

// -- Several nodes ------------------------------------------------------------------------

pub fn two_runners_never_do_the_same_job_twice_test() {
  let db = open()
  let seen = process.new_subject()
  let runner = fn() {
    jobs.runner(db)
    |> jobs.queue("tallies", concurrency: 5)
    |> jobs.check_every(20)
    |> jobs.handle(tally_job(), fn(n, _) {
      process.send(seen, n)
      Done
    })
  }
  let numbers =
    int.range(from: 1, to: 61, with: [], run: fn(acc, n) { [n, ..acc] })
    |> list.reverse
  list.each(numbers, fn(n) { queue(db, jobs.new(tally_job(), n)) })
  let one = runner()
  let other = runner()
  let assert Ok(_) = jobs.start(one)
  let assert Ok(_) = jobs.start(other)
  let done =
    list.map(numbers, fn(_) {
      let assert Ok(n) = process.receive(seen, 5000)
      n
    })
  assert list.sort(done, int.compare) == numbers
  let assert Error(Nil) = process.receive(seen, 300)
  jobs.stop(one)
  jobs.stop(other)
}

pub fn postgres_tells_runners_about_jobs_other_nodes_queue_test() {
  let db = open()
  case database.backend(db) {
    Ok(database.Postgres) -> {
      let seen = process.new_subject()
      let runner =
        runner(db, new_clock(), seen, fn(_, _) { Done })
        |> jobs.check_every(60_000)
      let assert Ok(_) = jobs.start(runner)
      process.sleep(300)
      // Queued as another node would, which cannot wake this one's
      // producers directly.
      let assert Ok(Nil) =
        database.exec(
          db,
          "INSERT INTO howdy_jobs (name, queue, args, state, priority, attempt,
             max_attempts, scheduled_at, inserted_at, errors)
           VALUES ('echo', 'default', '\"elsewhere\"', 'available', 0, 0, 20,
             0, 0, '[]');
           NOTIFY howdy_jobs, 'default'",
        )
      let assert Ok(#("elsewhere", 1)) = process.receive(seen, 2000)
      jobs.stop(runner)
    }
    _ -> Nil
  }
}

// -- Unique while waiting -------------------------------------------------------------

pub fn unique_while_waiting_lets_a_running_job_be_followed_test() {
  let db = open()
  let seen = process.new_subject()
  let runner =
    jobs.runner(db)
    |> jobs.handle(echo_job(), fn(text, _) {
      // Hold the first run until the test has queued more.
      let gate = process.new_subject()
      process.send(seen, gate)
      case text {
        "first" -> {
          let _ = process.receive(gate, 5000)
          Nil
        }
        _ -> Nil
      }
      Done
    })
  let first =
    queue(db, jobs.new(echo_job(), "first") |> jobs.unique_while_waiting("k"))
  // While it waits, more collapse into it.
  let assert Ok(Duplicate(same)) =
    jobs.insert(jobs.new(echo_job(), "x") |> jobs.unique_while_waiting("k"), db)
  assert same == first
  // A plain unique key of the same name is separate.
  let assert Ok(Inserted(_)) =
    jobs.insert(jobs.new(echo_job(), "plain") |> jobs.unique("k"), db)
  let assert Ok(_) =
    jobs.start(
      runner |> jobs.queue("default", concurrency: 1) |> jobs.check_every(20),
    )
  let assert Ok(gate) = process.receive(seen, 2000)
  let assert Ok(Nil) = wait_for(fn() { record(db, first).state == Executing })
  // Running, it no longer holds the key.
  let assert Ok(Inserted(follow_up)) =
    jobs.insert(
      jobs.new(echo_job(), "follow up") |> jobs.unique_while_waiting("k"),
      db,
    )
  let assert Ok(Duplicate(again)) =
    jobs.insert(jobs.new(echo_job(), "y") |> jobs.unique_while_waiting("k"), db)
  assert again == follow_up
  process.send(gate, Nil)
  let assert Ok(Nil) =
    wait_for(fn() {
      record(db, first).state == Completed
      && record(db, follow_up).state == Completed
    })
  jobs.stop(runner)
}

pub fn a_superseded_waiting_job_is_cancelled_rather_than_retried_test() {
  let db = open()
  let clock = new_clock()
  let seen = process.new_subject()
  let started = process.new_subject()
  let runner =
    runner(db, clock, seen, fn(text, _) {
      case text {
        "old" -> {
          process.send(started, Nil)
          // Another job with the key is queued while this one runs.
          let assert Ok(_) =
            jobs.insert(
              jobs.new(echo_job(), "new") |> jobs.unique_while_waiting("k"),
              db,
            )
          Retry("down")
        }
        _ -> Done
      }
    })
  let old =
    queue(db, jobs.new(echo_job(), "old") |> jobs.unique_while_waiting("k"))
  assert drained(runner).completed == 1
  let assert Ok(Nil) = process.receive(started, 0)
  let superseded = record(db, old)
  assert superseded.state == Cancelled
}
