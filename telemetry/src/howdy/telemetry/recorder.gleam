//// Recent traces and log lines, held in memory for the dev admin.
////
//// ```gleam
//// let recorder = recorder.new(keep: 200)
////
//// let assert Ok(Nil) =
////   telemetry.new("acme-web")
////   |> telemetry.record(recorder)
////   |> telemetry.start
////
//// admin.new()
//// |> admin.telemetry(recorder)
//// ```
////
//// A trace is kept from the moment its root span ends, the request in most
//// cases, until `keep` newer traces have arrived. Spans whose root never
//// ends here are dropped after a few minutes. The last 2,000 log lines are
//// kept, with the trace they were logged in.
////
//// The tables belong to a process that exits with the process that called
//// `new`, so make the recorder in `main`.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/string
import howdy/trace

pub opaque type Recorder {
  Recorder(tables: Tables)
}

type Tables

/// A finished span. Times are in microseconds: `start` since the Unix
/// epoch, `duration` from start to end.
pub type Span {
  Span(
    trace_id: String,
    span_id: String,
    parent_id: Option(String),
    name: String,
    kind: trace.Kind,
    start: Int,
    duration: Int,
    attributes: List(#(String, Value)),
    events: List(Event),
    /// The trace and span ids of the spans this one links to.
    links: List(#(String, String)),
    status: Status,
    /// The library that opened the span, such as `howdy` or `pgo`.
    scope: String,
  )
}

pub type Value {
  Text(String)
  Integer(Int)
  Number(Float)
  Boolean(Bool)
  Many(List(Value))
}

/// Something that happened during a span: a log line, an exception.
pub type Event {
  Event(name: String, at: Int, attributes: List(#(String, Value)))
}

pub type Status {
  Unset
  Succeeded
  Failed(message: String)
}

/// A trace, summarised by its root span.
pub type Trace {
  Trace(root: Span, spans: Int, failed: Int)
}

pub type Log {
  Log(
    at: Int,
    level: String,
    message: String,
    trace_id: Option(String),
    span_id: Option(String),
  )
}

/// A recorder holding the last `keep` traces.
pub fn new(keep keep: Int) -> Recorder {
  Recorder(new_tables(keep))
}

/// Up to `limit` traces, newest first.
pub fn traces(recorder: Recorder, limit limit: Int) -> List(Trace) {
  traces_ffi(recorder.tables, limit)
}

/// Every span of the trace with id `trace_id`, earliest first.
pub fn trace(recorder: Recorder, trace_id: String) -> Result(List(Span), Nil) {
  trace_ffi(recorder.tables, trace_id)
}

/// The log lines written while the trace with id `trace_id` ran.
pub fn logs(recorder: Recorder, trace_id: String) -> List(Log) {
  logs_ffi(recorder.tables, trace_id)
}

/// The last `limit` log lines, oldest first.
pub fn recent_logs(recorder: Recorder, limit limit: Int) -> List(Log) {
  recent_logs_ffi(recorder.tables, limit)
}

/// A number that goes up whenever a trace is recorded or the recorder is
/// cleared, so a page that polls can tell whether anything changed.
pub fn version(recorder: Recorder) -> Int {
  version_ffi(recorder.tables)
}

/// Forget every trace and log line.
pub fn clear(recorder: Recorder) -> Nil {
  clear_ffi(recorder.tables)
}

/// The value of the attribute `key` on `span`, if it has one.
pub fn attribute(span: Span, key: String) -> Option(Value) {
  list.key_find(span.attributes, key) |> option.from_result
}

/// A value as text, the way the admin shows it.
pub fn value_to_string(value: Value) -> String {
  case value {
    Text(text) -> text
    Integer(value) -> int.to_string(value)
    Number(value) -> float.to_string(value)
    Boolean(True) -> "true"
    Boolean(False) -> "false"
    Many(values) ->
      "[" <> string.join(list.map(values, value_to_string), ", ") <> "]"
  }
}

@external(erlang, "howdy_telemetry_recorder", "new")
fn new_tables(keep: Int) -> Tables

@external(erlang, "howdy_telemetry_recorder", "traces")
fn traces_ffi(tables: Tables, limit: Int) -> List(Trace)

@external(erlang, "howdy_telemetry_recorder", "trace")
fn trace_ffi(tables: Tables, trace_id: String) -> Result(List(Span), Nil)

@external(erlang, "howdy_telemetry_recorder", "logs")
fn logs_ffi(tables: Tables, trace_id: String) -> List(Log)

@external(erlang, "howdy_telemetry_recorder", "recent_logs")
fn recent_logs_ffi(tables: Tables, limit: Int) -> List(Log)

@external(erlang, "howdy_telemetry_recorder", "version")
fn version_ffi(tables: Tables) -> Int

@external(erlang, "howdy_telemetry_recorder", "clear")
fn clear_ffi(tables: Tables) -> Nil
