//// One trace: its facts, what deserves a look, the waterfall of its
//// spans, and the log lines written in it.

import gleam/float
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/format
import howdy/admin/internal/layout
import howdy/admin/internal/telemetry/logs
import howdy/admin/internal/telemetry/shared
import howdy/content.{type Content}
import howdy/controller.{type Context}
import howdy/telemetry/recorder.{type Recorder, type Span}
import howdy/trace
import howdy/ui
import howdy/ui/alert
import howdy/ui/badge
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html

pub fn page(
  config: Config,
  recorder: Recorder,
  ctx: Context,
) -> Response(Content) {
  let assert Ok(id) = controller.param(ctx, "id")
  // A trace the recorder holds always has a span, but the id came from the
  // request, so an empty answer is treated like a dropped trace.
  case recorder.trace(recorder, id) {
    Ok([first, ..] as spans) -> {
      let tree = shared.tree(spans)
      let root =
        list.find(spans, fn(span) { span.parent_id == None })
        |> result.lazy_or(fn() { list.first(tree) |> result.map(fn(p) { p.0 }) })
        |> result.unwrap(first)
      layout.page(
        config,
        ctx,
        current: "/telemetry",
        heading: root.name,
        live: False,
        content: [
          ui.stack([], [
            facts(root, spans),
            warnings(spans),
            waterfall(config, tree, spans),
            logs.card(config, recorder.logs(recorder, id), False),
            ui.p([
              ui.link(config.path(config, "/telemetry"), [text("All traces")]),
            ]),
          ]),
        ],
      )
    }
    Error(Nil) | Ok([]) ->
      layout.page(
        config,
        ctx,
        current: "/telemetry",
        heading: "Trace not found",
        live: False,
        content: [
          ui.p([
            ui.muted(
              "The recorder no longer holds this trace: it keeps the newest ones and drops the rest.",
            ),
          ]),
          ui.p([
            ui.link(config.path(config, "/telemetry"), [text("All traces")]),
          ]),
        ],
      )
  }
}

fn facts(root: Span, spans: List(Span)) -> Element(msg) {
  let failures = list.count(spans, shared.failed)
  ui.row([], [
    shared.status_badge(
      shared.status(root),
      recorder.Trace(root, list.length(spans), failures),
    ),
    ui.badge(badge.Secondary, [], [text(format.duration(root.duration))]),
    ui.badge(badge.Outline, [], [
      text(format.describe(list.length(spans), "span")),
    ]),
    ui.muted("started " <> format.clock(root.start) <> " UTC · trace "),
    layout.mono(root.trace_id),
  ])
}

/// What deserves a look: failures, statements run once per row, and slow
/// statements.
fn warnings(spans: List(Span)) -> Element(msg) {
  let failures = list.filter(spans, shared.failed)
  let slow =
    list.filter(spans, fn(span) {
      shared.is_query(span) && span.duration >= shared.slow_query_us
    })
  ui.stack([], [
    case failures {
      [] -> element.none()
      failures ->
        ui.alert(alert.Danger, [], [
          ui.alert_title([
            text(format.describe(list.length(failures), "span") <> " failed"),
          ]),
          ui.alert_description(
            list.map(failures, fn(span) {
              html.div([], [
                text(span.name <> ": "),
                text(case span.status {
                  recorder.Failed(message) -> message
                  _ -> ""
                }),
              ])
            }),
          ),
        ])
    },
    case shared.repeated_queries(spans) {
      [] -> element.none()
      repeated ->
        ui.alert(alert.Info, [], [
          ui.alert_title([text("The same statement ran many times")]),
          ui.alert_description([
            html.p([], [
              text(
                "Usually a query inside a loop, one per row. A join, or one query with IN, fetches them all at once.",
              ),
            ]),
            ..list.map(repeated, fn(pair) {
              html.div([], [
                text(int.to_string(pair.1) <> " × "),
                layout.mono(layout.clip(pair.0)),
              ])
            })
          ]),
        ])
    },
    case slow {
      [] -> element.none()
      slow ->
        ui.alert(alert.Info, [], [
          ui.alert_title([
            text(
              "Statements slower than " <> format.duration(shared.slow_query_us),
            ),
          ]),
          ui.alert_description(
            list.map(slow, fn(span) {
              html.div([], [
                text(format.duration(span.duration) <> " "),
                layout.mono(
                  layout.clip(option.unwrap(shared.query_text(span), span.name)),
                ),
              ])
            }),
          ),
        ])
    },
  ])
}

fn waterfall(
  config: Config,
  tree: List(#(Span, Int)),
  spans: List(Span),
) -> Element(msg) {
  let start =
    list.fold(spans, 0, fn(earliest, span) {
      case earliest == 0 || span.start < earliest {
        True -> span.start
        False -> earliest
      }
    })
  let end =
    list.fold(spans, 0, fn(latest, span) {
      int.max(latest, span.start + span.duration)
    })
  let window = int.max(end - start, 1)
  ui.card([], [
    ui.card_header([], [
      ui.card_title([text("Timeline")]),
      ui.card_description([
        text("Open a span for its attributes and events."),
      ]),
    ]),
    ui.card_content(
      [],
      list.map(tree, fn(pair) {
        span_row(config, pair.0, pair.1, start, window)
      }),
    ),
  ])
}

fn span_row(
  config: Config,
  span: Span,
  depth: Int,
  start: Int,
  window: Int,
) -> Element(msg) {
  let left = percent(span.start - start, window)
  let width = float.max(percent(span.duration, window), 0.4)
  let colour = case shared.failed(span), shared.is_query(span), span.kind {
    True, _, _ -> "var(--howdy-danger)"
    False, True, _ -> "var(--howdy-chart-2, var(--howdy-primary))"
    False, False, trace.Client -> "var(--howdy-chart-3, var(--howdy-primary))"
    False, False, _ -> "var(--howdy-primary)"
  }
  ui.collapsible(
    [attribute.attribute("data-span", span.span_id)],
    open: False,
    summary: [
      html.div(
        [
          attribute.style("display", "grid"),
          attribute.style(
            "grid-template-columns",
            "minmax(14rem, 2fr) 3fr 6rem",
          ),
          attribute.style("gap", "0.75rem"),
          attribute.style("align-items", "center"),
          attribute.style("width", "100%"),
        ],
        [
          html.span(
            [
              attribute.style(
                "padding-left",
                float.to_string(int.to_float(depth) *. 1.25) <> "rem",
              ),
              attribute.style("overflow", "hidden"),
              attribute.style("text-overflow", "ellipsis"),
              attribute.style("white-space", "nowrap"),
            ],
            [text(span.name)],
          ),
          html.div(
            [
              attribute.style("position", "relative"),
              attribute.style("height", "0.75rem"),
              attribute.style("border-radius", "0.25rem"),
              attribute.style("background", "var(--howdy-muted)"),
            ],
            [
              html.div(
                [
                  attribute.style("position", "absolute"),
                  attribute.style("top", "0"),
                  attribute.style("bottom", "0"),
                  attribute.style("left", float.to_string(left) <> "%"),
                  attribute.style("width", float.to_string(width) <> "%"),
                  attribute.style("border-radius", "0.25rem"),
                  attribute.style("background", colour),
                ],
                [],
              ),
            ],
          ),
          html.span(
            [
              attribute.style("text-align", "right"),
              attribute.style("font-family", "var(--howdy-font-mono)"),
            ],
            [text(format.duration(span.duration))],
          ),
        ],
      ),
    ],
    content: [span_details(config, span, start)],
  )
}

fn percent(part: Int, whole: Int) -> Float {
  int.to_float(part) *. 100.0 /. int.to_float(whole)
  |> float.to_precision(3)
}

fn span_details(config: Config, span: Span, start: Int) -> Element(msg) {
  ui.stack([], [
    ui.muted(
      kind_name(span.kind)
      <> " span"
      <> case span.scope {
        "" -> ""
        scope -> " from " <> scope
      }
      <> ", starting "
      <> format.duration(span.start - start)
      <> " in",
    ),
    case span.status {
      recorder.Failed(message) ->
        ui.alert(alert.Danger, [], [ui.alert_description([text(message)])])
      _ -> element.none()
    },
    case span.attributes {
      [] -> element.none()
      attributes ->
        ui.table([], [
          ui.table_body(
            [],
            list.map(attributes, fn(pair) {
              ui.table_row([], [
                ui.table_cell([], [layout.mono(pair.0)]),
                ui.table_cell([], [shared.value(pair.1)]),
              ])
            }),
          ),
        ])
    },
    case span.events {
      [] -> element.none()
      events ->
        ui.table([], [
          ui.table_header([], [
            ui.table_row([], [
              ui.table_head([], [text("At")]),
              ui.table_head([], [text("Event")]),
            ]),
          ]),
          ui.table_body(
            [],
            list.map(events, fn(event) {
              ui.table_row([], [
                ui.table_cell([], [
                  layout.mono("+" <> format.duration(event.at - span.start)),
                ]),
                ui.table_cell([], [
                  html.div([], [text(event.name)]),
                  ..list.map(event.attributes, fn(pair) {
                    html.div([], [
                      ui.muted(pair.0 <> ": "),
                      shared.value(pair.1),
                    ])
                  })
                ]),
              ])
            }),
          ),
        ])
    },
    case span.links {
      [] -> element.none()
      links ->
        html.div(
          [],
          list.map(links, fn(link) {
            html.div([], [
              ui.muted("Linked to "),
              ui.link(shared.trace_href(config, link.0), [
                text("trace " <> link.0),
              ]),
            ])
          }),
        )
    },
  ])
}

fn kind_name(kind: trace.Kind) -> String {
  case kind {
    trace.Internal -> "Internal"
    trace.Server -> "Server"
    trace.Client -> "Client"
    trace.Producer -> "Producer"
    trace.Consumer -> "Consumer"
  }
}
