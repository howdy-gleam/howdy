import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{Some}
import gloo/adapter/sqlite
import howdy/database
import howdy/jobs
import howdy/migration
import howdy/telemetry
import howdy/telemetry/recorder
import howdy/trace

pub fn a_job_links_back_to_the_request_that_queued_it_test() {
  let assert Ok(db) = sqlite.start(sqlite.memory())
  let assert Ok(Nil) = database.sqlite_defaults(db)
  let assert Ok(Nil) = migration.run(db, [jobs.schema()])
  let echo_job =
    jobs.define("echo", encode: json.string, decoder: decode.string)
  let runner =
    jobs.runner(db)
    |> jobs.handle(echo_job, fn(text, _) {
      case text {
        "fail" -> jobs.Retry("down")
        _ -> jobs.Done
      }
    })
  let recorder = recorder.new(keep: 10)
  let assert Ok(Nil) =
    telemetry.new("howdy-jobs-test")
    |> telemetry.record(recorder)
    |> telemetry.start
  // Outside any request, queueing is no span of its own.
  let assert Ok(_) = jobs.insert(jobs.new(echo_job, "fail"), db)
  let assert Ok(jobs.Inserted(_)) =
    trace.new("POST /signup")
    |> trace.kind(trace.Server)
    |> trace.run(fn() { jobs.insert(jobs.new(echo_job, "hi"), db) })
  let assert Ok(_) = jobs.drain(runner)
  telemetry.stop()

  let traces = recorder.traces(recorder, limit: 10)
  let assert Ok(request) =
    list.find(traces, fn(t) { t.root.name == "POST /signup" })
  let assert Ok(spans) = recorder.trace(recorder, request.root.trace_id)
  let assert Ok(enqueue) = list.find(spans, fn(s) { s.name == "enqueue echo" })
  assert enqueue.kind == trace.Producer
  assert recorder.attribute(enqueue, "messaging.destination.name")
    == Some(recorder.Text("default"))

  let runs = list.filter(traces, fn(t) { t.root.name == "job echo" })
  assert list.length(runs) == 2
  let assert Ok(linked) = list.find(runs, fn(t) { t.root.links != [] })
  assert linked.root.kind == trace.Consumer
  assert linked.root.links == [#(enqueue.trace_id, enqueue.span_id)]
  assert recorder.attribute(linked.root, "howdy.job.attempt")
    == Some(recorder.Integer(1))
  let assert Ok(failed) = list.find(runs, fn(t) { t.root.links == [] })
  assert failed.root.status == recorder.Failed("down")
}
