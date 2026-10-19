import gleam/dynamic/decode
import gleam/list
import gleam/option.{Some}
import gloo/adapter/sqlite
import gloo/value
import howdy
import howdy/controller
import howdy/database
import howdy/health
import howdy/service
import howdy/telemetry
import howdy/telemetry/recorder
import howdy/testing
import howdy/trace

fn recording() -> recorder.Recorder {
  let recorder = recorder.new(keep: 20)
  let assert Ok(Nil) =
    telemetry.new("howdy-database-test")
    |> telemetry.record(recorder)
    |> telemetry.start
  recorder
}

fn db() {
  let assert Ok(db) = sqlite.start(sqlite.memory())
  let db = database.traced(db)
  let assert Ok(Nil) =
    database.exec(db, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)")
  db
}

pub fn queries_in_a_span_are_its_children_test() {
  let db = db()
  let recorder = recording()
  let assert Ok(Nil) = {
    use <- trace.span("request", [])
    use tx <- database.transaction(db)
    let assert Ok(Nil) =
      database.execute(tx, "INSERT INTO notes (body) VALUES (?)", [
        value.GString("secret"),
      ])
    let assert Ok(_) =
      database.query(
        tx,
        "SELECT body FROM notes",
        [],
        decode.field(0, decode.string, decode.success),
      )
    Ok(Nil)
  }

  let assert [trace] = recorder.traces(recorder, limit: 5)
  let assert Ok(spans) = recorder.trace(recorder, trace.root.trace_id)
  let assert [request, transaction, insert, select] = spans
  assert request.name == "request"
  assert transaction.name == "transaction"
  assert transaction.parent_id == Some(request.span_id)
  assert insert.name == "INSERT notes"
  assert insert.kind == trace.Client
  assert insert.parent_id == Some(transaction.span_id)
  assert recorder.attribute(insert, "db.query.text")
    == Some(recorder.Text("INSERT INTO notes (body) VALUES (?)"))
  assert recorder.attribute(insert, "db.system.name")
    == Some(recorder.Text("sqlite"))
  assert select.name == "SELECT notes"
  assert recorder.attribute(select, "db.response.returned_rows")
    == Some(recorder.Integer(1))
  // Parameter values are never recorded.
  assert !list.any(spans, fn(span) {
    list.any(span.attributes, fn(attribute) {
      attribute.1 == recorder.Text("secret")
    })
  })
}

pub fn a_failed_query_fails_its_span_without_the_driver_text_test() {
  let db = db()
  let recorder = recording()
  let _ = {
    use <- trace.span("request", [])
    database.execute(db, "INSERT INTO missing (x) VALUES (1)", [])
  }
  let assert [trace] = recorder.traces(recorder, limit: 5)
  let assert Ok([_, insert]) = recorder.trace(recorder, trace.root.trace_id)
  assert insert.status == recorder.Failed("database operation failed")
}

pub fn a_rolled_back_transaction_says_so_test() {
  let db = db()
  let recorder = recording()
  let _ = {
    use <- trace.span("request", [])
    use _tx <- database.transaction(db)
    Error(service.Invalid("no"))
  }
  let assert [trace] = recorder.traces(recorder, limit: 5)
  let assert Ok(spans) = recorder.trace(recorder, trace.root.trace_id)
  let assert Ok(transaction) =
    list.find(spans, fn(span) { span.name == "transaction" })
  assert recorder.attribute(transaction, "db.transaction.rolled_back")
    == Some(recorder.Boolean(True))
}

pub fn queries_outside_a_span_are_not_traced_test() {
  let db = db()
  let recorder = recording()
  let assert Ok(_) =
    database.query(
      db,
      "SELECT body FROM notes",
      [],
      decode.field(0, decode.string, decode.success),
    )
  assert recorder.traces(recorder, limit: 5) == []
  telemetry.stop()
}

pub fn health_checks_are_not_traced_test() {
  let db = db()
  let recorder = recording()
  let app =
    howdy.new()
    |> howdy.controller(
      controller.new("notes")
      |> controller.get("/", fn(ctx) {
        let assert Ok(Nil) = database.health_check(db)()
        controller.text(ctx, "notes")
      }),
    )
    |> howdy.health_check(
      health.new() |> health.check("database", database.health_check(db)),
    )

  assert { testing.get("/up") |> testing.send(app) }.status == 200
  assert recorder.traces(recorder, limit: 5) == []

  // The same query in a request is traced, so the check above is not
  // passing for want of a recorder.
  assert { testing.get("/notes") |> testing.send(app) }.status == 200
  let assert [trace] = recorder.traces(recorder, limit: 5)
  let assert Ok([request, select]) =
    recorder.trace(recorder, trace.root.trace_id)
  assert request.name == "GET /notes"
  assert select.name == "SELECT"
}
