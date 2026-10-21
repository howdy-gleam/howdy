//// The telemetry pages, fed by a real recorder while the app serves
//// requests. The live lists need a browser; their data comes from the
//// functions tested here.

import gleam/dynamic/decode
import gleam/http/request
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gloo/adapter/sqlite
import gloo/repo.{type Repo}
import howdy
import howdy/admin
import howdy/admin/internal/format
import howdy/admin/internal/telemetry/shared
import howdy/controller.{type Context}
import howdy/database
import howdy/telemetry
import howdy/telemetry/recorder
import howdy/testing
import howdy/trace
import logging

fn notes_db() -> Repo {
  let assert Ok(db) = sqlite.start(sqlite.memory())
  let db = database.traced(db)
  let assert Ok(Nil) =
    database.exec(
      db,
      "CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT);
      INSERT INTO notes (title) VALUES ('a'), ('b'), ('c'), ('d'), ('e'), ('f')",
    )
  db
}

/// An app whose notes page loads each note with a query of its own.
fn app(db: Repo, recorder: recorder.Recorder) -> howdy.App {
  let notes =
    controller.new("notes")
    |> controller.get("/", fn(ctx: Context) {
      let assert Ok(ids) =
        database.query(
          db,
          "SELECT id FROM notes",
          [],
          decode.field(0, decode.int, decode.success),
        )
      list.each(ids, fn(_) {
        let _ =
          database.query(
            db,
            "SELECT title FROM notes WHERE id = ?",
            [],
            decode.field(0, decode.string, decode.success),
          )
        Nil
      })
      logging.log(logging.Warning, "slow notes")
      controller.text(ctx, "notes")
    })
  howdy.new()
  |> howdy.controller(notes)
  |> admin.mount(admin.new() |> admin.telemetry(recorder))
}

fn recording() -> recorder.Recorder {
  let recorder = recorder.new(keep: 50)
  let assert Ok(Nil) =
    telemetry.new("howdy-admin-test")
    |> telemetry.record(recorder)
    |> telemetry.start
  recorder
}

fn send(app: howdy.App, path: String) -> #(Int, String) {
  let res =
    testing.get(path) |> request.set_host("localhost") |> testing.send(app)
  #(res.status, testing.text(res))
}

fn get(app: howdy.App, path: String) -> String {
  let #(status, body) = send(app, path)
  assert status == 200
    as { "GET " <> path <> " gave " <> string.inspect(status) }
  body
}

fn notes_trace(recorder: recorder.Recorder) -> recorder.Trace {
  let assert Ok(trace) =
    recorder.traces(recorder, limit: 50)
    |> list.find(fn(trace) { trace.root.name == "GET /notes" })
  trace
}

pub fn a_trace_page_shows_the_timeline_repeats_and_logs_test() {
  let db = notes_db()
  let recorder = recording()
  let app = app(db, recorder)
  let _ = get(app, "/notes")
  let trace = notes_trace(recorder)
  let page = get(app, "/_howdy/telemetry/trace/" <> trace.root.trace_id)
  telemetry.stop()

  assert string.contains(page, "GET /notes")
  assert string.contains(page, "SELECT notes")
  assert string.contains(page, "The same statement ran many times")
  assert string.contains(page, "6 × ")
  assert string.contains(page, "SELECT title FROM notes WHERE id = ?")
  assert string.contains(page, "slow notes")
  assert string.contains(page, trace.root.trace_id)

  // The timeline is the tree: a row per span, the root first and unindented,
  // the queries below it indented one level.
  let assert Ok(spans) = recorder.trace(recorder, trace.root.trace_id)
  let tree = shared.tree(spans)
  assert list.length(tree) == list.length(spans)
  let assert [#(root, 0), ..rest] = tree
  assert root.span_id == trace.root.span_id
  assert list.all(rest, fn(pair) { pair.1 == 1 })
  assert list.length(rest) == 7
  list.each(spans, fn(span) {
    assert string.contains(page, "data-span=\"" <> span.span_id <> "\"")
  })
  assert string.contains(page, "padding-left:0.0rem")
  assert string.contains(page, "padding-left:1.25rem")
  assert !string.contains(page, "padding-left:2.5rem")
  let assert Ok(#(before_root, _)) =
    string.split_once(page, "data-span=\"" <> root.span_id <> "\"")
  assert !list.any(rest, fn(pair) {
    string.contains(before_root, "data-span=\"" <> { pair.0 }.span_id <> "\"")
  })

  let summary = shared.summarise(recorder, trace)
  assert summary.status == Some(200)
  assert summary.queries == 7
  assert summary.repeated == [#("SELECT title FROM notes WHERE id = ?", 6)]
}

pub fn the_list_and_logs_pages_mount_live_views_test() {
  let recorder = recording()
  let app = app(notes_db(), recorder)
  assert string.contains(
    get(app, "/_howdy/telemetry"),
    "/_howdy/live/telemetry",
  )
  assert string.contains(
    get(app, "/_howdy/telemetry/logs"),
    "/_howdy/live/telemetry/logs",
  )
  telemetry.stop()
}

pub fn overview_and_navigation_list_telemetry_test() {
  let recorder = recording()
  let app = app(notes_db(), recorder)
  let _ = get(app, "/notes")
  let overview = get(app, "/_howdy")
  telemetry.stop()
  assert string.contains(overview, "howdy_telemetry")
  assert string.contains(overview, "trace")
  assert string.contains(overview, "/_howdy/telemetry/logs")
  assert admin.has_telemetry(admin.new() |> admin.telemetry(recorder))
  assert !admin.has_telemetry(admin.new())
  // Without a recorder the pages are not mounted.
  let bare = howdy.new() |> admin.mount(admin.new())
  let #(status, _) = send(bare, "/_howdy/telemetry")
  assert status == 404
}

pub fn a_dropped_or_unknown_trace_says_so_test() {
  let recorder = recording()
  let app = app(notes_db(), recorder)
  let _ = get(app, "/notes")
  // A well-formed id the recorder never saw, and one that is not an id at
  // all, both get the notice rather than a crash.
  use id <- list.each(["0af7651916cd43dd8448eb211c80319c", "nonsense", "%20"])
  let page = get(app, "/_howdy/telemetry/trace/" <> id)
  assert string.contains(page, "Trace not found")
  assert string.contains(page, "All traces")
  assert !string.contains(page, "Timeline")
  telemetry.stop()
}

pub fn clearing_forgets_every_trace_test() {
  let recorder = recording()
  let app = app(notes_db(), recorder)
  let _ = get(app, "/notes")
  let res =
    testing.post_form("/_howdy/telemetry/clear", [])
    |> request.set_host("localhost")
    |> testing.header("sec-fetch-site", "same-origin")
    |> testing.send(app)
  telemetry.stop()
  assert res.status == 303
  assert !list.any(recorder.traces(recorder, limit: 50), fn(trace) {
    trace.root.name == "GET /notes"
  })
}

fn span(
  id: String,
  parent: option.Option(String),
  start: Int,
) -> recorder.Span {
  recorder.Span(
    trace_id: "t",
    span_id: id,
    parent_id: parent,
    name: id,
    kind: trace.Internal,
    start:,
    duration: 10,
    attributes: [],
    events: [],
    links: [],
    status: recorder.Unset,
    scope: "",
  )
}

pub fn tree_puts_children_after_their_parent_test() {
  let spans = [
    span("b2", Some("a"), 30),
    span("c", Some("b1"), 25),
    span("a", None, 0),
    span("b1", Some("a"), 20),
    // Its parent is in another service.
    span("x", Some("remote"), 5),
  ]
  assert list.map(shared.tree(spans), fn(pair) { #({ pair.0 }.span_id, pair.1) })
    == [#("a", 0), #("b1", 1), #("c", 2), #("b2", 1), #("x", 0)]
}

pub fn durations_read_well_test() {
  assert format.duration(420) == "420 µs"
  assert format.duration(4200) == "4.2 ms"
  assert format.duration(42_000) == "42 ms"
  assert format.duration(4_200_000) == "4.2 s"
}
