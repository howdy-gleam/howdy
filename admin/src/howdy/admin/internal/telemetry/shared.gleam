//// What the recorder's spans and traces say, and the pieces every
//// telemetry page shares: badges, links and the live views' clock.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import howdy/admin/internal/config.{type Config}
import howdy/telemetry/recorder.{type Recorder, type Span, type Trace}
import howdy/ui
import howdy/ui/badge
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/server_component

/// How many times the same statement may run in one trace before it looks
/// like a query in a loop, one per row, that a join would replace.
pub const repeated_query_threshold = 5

/// A query slower than this, in microseconds, is pointed out.
pub const slow_query_us = 100_000

// -- What a trace says --------------------------------------------------------

/// A trace with what the list and the overview point out about it.
pub type Summary {
  Summary(
    trace: Trace,
    /// The response status, for a request.
    status: Option(Int),
    queries: Int,
    /// Statements run at least `repeated_query_threshold` times, with how
    /// many times, most first.
    repeated: List(#(String, Int)),
  )
}

pub fn summarise(recorder: Recorder, trace: Trace) -> Summary {
  let spans = recorder.trace(recorder, trace.root.trace_id) |> result.unwrap([])
  Summary(
    trace:,
    status: status(trace.root),
    queries: list.count(spans, is_query),
    repeated: repeated_queries(spans),
  )
}

pub fn status(span: Span) -> Option(Int) {
  case recorder.attribute(span, "http.response.status_code") {
    Some(recorder.Integer(code)) -> Some(code)
    _ -> None
  }
}

pub fn is_query(span: Span) -> Bool {
  option.is_some(recorder.attribute(span, "db.query.text"))
}

pub fn query_text(span: Span) -> Option(String) {
  case recorder.attribute(span, "db.query.text") {
    Some(recorder.Text(sql)) -> Some(sql)
    _ -> None
  }
}

/// The statements a trace ran often enough to look like a query per row.
pub fn repeated_queries(spans: List(Span)) -> List(#(String, Int)) {
  spans
  |> list.filter_map(fn(span) { option.to_result(query_text(span), Nil) })
  |> list.fold(dict.new(), fn(counts, sql) {
    dict.upsert(counts, sql, fn(count) { option.unwrap(count, 0) + 1 })
  })
  |> dict.to_list
  |> list.filter(fn(pair) { pair.1 >= repeated_query_threshold })
  |> list.sort(fn(a, b) { int.compare(b.1, a.1) })
}

pub fn failed(span: Span) -> Bool {
  case span.status {
    recorder.Failed(_) -> True
    _ -> False
  }
}

/// The admin's own pages and the dev server's reload socket are traced like
/// any request, but they are rarely what you came to look at.
pub fn is_tooling(config: Config, trace: Trace) -> Bool {
  case recorder.attribute(trace.root, "url.path") {
    Some(recorder.Text(path)) ->
      path == config.prefix
      || string.starts_with(path, config.prefix <> "/")
      || string.starts_with(path, "/_howdy/")
    _ -> False
  }
}

/// Spans in the order to draw them, each with its depth: every span after
/// its parent, siblings by start time. A span whose parent is not here,
/// the root or a child of a span in another service, starts at depth 0.
pub fn tree(spans: List(Span)) -> List(#(Span, Int)) {
  let ids = list.map(spans, fn(span) { span.span_id })
  let children: Dict(String, List(Span)) =
    list.fold(spans, dict.new(), fn(children, span) {
      case span.parent_id {
        Some(parent) ->
          case list.contains(ids, parent) {
            True ->
              dict.upsert(children, parent, fn(existing) {
                [span, ..option.unwrap(existing, [])]
              })
            False -> children
          }
        None -> children
      }
    })
  spans
  |> list.filter(fn(span) {
    case span.parent_id {
      Some(parent) -> !list.contains(ids, parent)
      None -> True
    }
  })
  |> by_start
  |> list.flat_map(descend(_, 0, children))
}

fn descend(
  span: Span,
  depth: Int,
  children: Dict(String, List(Span)),
) -> List(#(Span, Int)) {
  let below =
    dict.get(children, span.span_id)
    |> result.unwrap([])
    |> by_start
    |> list.flat_map(descend(_, depth + 1, children))
  [#(span, depth), ..below]
}

fn by_start(spans: List(Span)) -> List(Span) {
  list.sort(spans, fn(a, b) { int.compare(a.start, b.start) })
}

// -- Pieces every page shares -----------------------------------------------

/// Ask the runtime for a subject to send timer messages to. The runtime
/// selects on it, so timers are plain `send_after`s that die with it.
pub fn ticking(wrap: fn(Subject(msg)) -> msg) -> Effect(msg) {
  use dispatch, subject <- server_component.select
  dispatch(wrap(subject))
  process.new_selector() |> process.select(subject)
}

/// Look again in a second. The recorder is in memory, so this is cheap, and
pub fn every_second(clock: Option(Subject(msg)), msg: msg) -> Effect(msg) {
  case clock {
    Some(clock) -> {
      let _ = process.send_after(clock, 1000, msg)
      Nil
    }
    None -> Nil
  }
  effect.none()
}

pub fn option(value: String, label: String, selected: Bool) -> Element(msg) {
  html.option([attribute.value(value), attribute.selected(selected)], label)
}

pub fn status_badge(status: Option(Int), trace: Trace) -> Element(msg) {
  case status, trace.failed {
    Some(code), _ if code >= 500 ->
      ui.badge(badge.Danger, [], [text(int.to_string(code))])
    Some(code), _ if code >= 400 ->
      ui.badge(badge.Outline, [], [text(int.to_string(code))])
    Some(code), 0 -> ui.badge(badge.Secondary, [], [text(int.to_string(code))])
    Some(code), _ -> ui.badge(badge.Danger, [], [text(int.to_string(code))])
    None, 0 -> ui.badge(badge.Secondary, [], [text("ok")])
    None, _ -> ui.badge(badge.Danger, [], [text("failed")])
  }
}

pub fn trace_href(config: Config, trace_id: String) -> String {
  config.path(config, "/telemetry/trace/" <> trace_id)
}

/// Long values, such as SQL and stack traces, keep their line breaks.
pub fn value(value: recorder.Value) -> Element(msg) {
  html.code(
    [
      attribute.style("white-space", "pre-wrap"),
      attribute.style("word-break", "break-word"),
    ],
    [text(recorder.value_to_string(value))],
  )
}
