//// The telemetry pages: requests and other traces as they finish, each
//// trace as a waterfall with its queries, events and logs, and the recent
//// log lines. They read the recorder `howdy_telemetry` fills, so they show
//// whatever the app traced: the spans Howdy opens and the app's own.

import gleam/erlang/process.{type Subject}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/format
import howdy/admin/internal/layout
import howdy/admin/internal/telemetry/logs
import howdy/admin/internal/telemetry/shared
import howdy/admin/internal/telemetry/trace as trace_page
import howdy/content.{type Content}
import howdy/controller.{type Context, type Controller}
import howdy/telemetry/recorder.{type Recorder, type Span}
import howdy/ui
import howdy/ui/badge
import howdy/ui/button
import howdy/ui/live
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event

/// A trace slower than this, in microseconds, counts as slow in the list.
const slow_trace_us = 500_000

/// How many traces the list shows.
const shown = 100

pub fn controller(config: Config, recorder: Recorder) -> Controller {
  controller.new(config.prefix)
  |> controller.get("/telemetry", fn(ctx) { traces_page(config, ctx) })
  |> controller.get("/telemetry/trace/:id", fn(ctx) {
    trace_page.page(config, recorder, ctx)
  })
  |> controller.get("/telemetry/logs", fn(ctx) { logs.page(config, ctx) })
  |> controller.post("/telemetry/clear", fn(_) {
    recorder.clear(recorder)
    layout.redirect(config.path(config, "/telemetry"))
  })
  |> controller.get("/live/telemetry", fn(ctx) {
    live.serve(ctx, list_app(), with: #(config, recorder))
  })
  |> controller.get("/live/telemetry/logs", fn(ctx) {
    live.serve(ctx, logs.app(), with: #(config, recorder))
  })
}

// -- The list ------------------------------------------------------------------

fn traces_page(config: Config, ctx: Context) -> Response(Content) {
  layout.page(
    config,
    ctx,
    current: "/telemetry",
    heading: "Traces",
    live: True,
    content: [
      ui.p([
        ui.muted(
          "Requests and other traces your app recorded, newest first, as they finish. Open one for its timeline, queries and logs.",
        ),
      ]),
      live.mount(config.path(config, "/live/telemetry")),
    ],
  )
}

pub type Show {
  Everything
  Failures
  Slow
}

pub type ListModel {
  ListModel(
    config: Config,
    recorder: Recorder,
    /// The recorder's version when the list was last read.
    version: Int,
    summaries: List(shared.Summary),
    search: String,
    show: Show,
    tooling: Bool,
    /// The runtime's subject for the ticking timer, once it exists.
    clock: Option(Subject(ListMsg)),
  )
}

pub type ListMsg {
  Clock(Subject(ListMsg))
  Tick
  Search(List(#(String, String)))
  ClearSearch
  ShowOnly(String)
  Tooling(String)
  ClearAll
}

fn list_app() -> lustre.App(#(Config, Recorder), ListModel, ListMsg) {
  lustre.application(
    init: fn(args: #(Config, Recorder)) {
      let model =
        ListModel(
          config: args.0,
          recorder: args.1,
          version: -1,
          summaries: [],
          search: "",
          show: Everything,
          tooling: False,
          clock: None,
        )
      #(load(model), shared.ticking(Clock))
    },
    update: list_update,
    view: list_view,
  )
}

fn list_update(
  model: ListModel,
  msg: ListMsg,
) -> #(ListModel, Effect(ListMsg)) {
  case msg {
    Clock(subject) -> {
      let model = ListModel(..model, clock: Some(subject))
      #(model, tick(model.clock))
    }
    Tick ->
      case recorder.version(model.recorder) == model.version {
        True -> #(model, tick(model.clock))
        False -> #(load(model), tick(model.clock))
      }
    Search(fields) -> #(
      load(
        ListModel(
          ..model,
          search: list.key_find(fields, "q") |> result.unwrap("") |> string.trim,
        ),
      ),
      effect.none(),
    )
    ClearSearch -> #(load(ListModel(..model, search: "")), effect.none())
    ShowOnly(value) -> {
      let show = case value {
        "failures" -> Failures
        "slow" -> Slow
        _ -> Everything
      }
      #(load(ListModel(..model, show:)), effect.none())
    }
    Tooling(value) -> #(
      load(ListModel(..model, tooling: value == "yes")),
      effect.none(),
    )
    ClearAll -> {
      recorder.clear(model.recorder)
      #(load(model), effect.none())
    }
  }
}

/// the list is only rebuilt when a trace has arrived since.
fn tick(clock: Option(Subject(ListMsg))) -> Effect(ListMsg) {
  shared.every_second(clock, Tick)
}

fn load(model: ListModel) -> ListModel {
  let version = recorder.version(model.recorder)
  let search = string.lowercase(model.search)
  let summaries =
    recorder.traces(model.recorder, limit: 1000)
    |> list.filter(fn(trace) {
      model.tooling || !shared.is_tooling(model.config, trace)
    })
    |> list.filter(fn(trace) {
      search == ""
      || string.contains(string.lowercase(label(trace.root)), search)
    })
    |> list.filter(fn(trace) {
      case model.show {
        Everything -> True
        Failures -> trace.failed > 0
        Slow -> trace.root.duration >= slow_trace_us
      }
    })
    |> list.take(shown)
    |> list.map(shared.summarise(model.recorder, _))
  ListModel(..model, version:, summaries:)
}

/// A root's name, with the path for a request so a search can find it.
fn label(span: Span) -> String {
  case recorder.attribute(span, "url.path") {
    Some(recorder.Text(path)) -> span.name <> " " <> path
    _ -> span.name
  }
}

fn list_view(model: ListModel) -> Element(ListMsg) {
  let config = model.config
  ui.stack([], [
    ui.row([], [
      html.form([event.on_submit(Search)], [
        ui.row([], [
          ui.input([
            attribute.type_("search"),
            attribute.name("q"),
            attribute.value(model.search),
            attribute.placeholder("search names and paths"),
            attribute.style("width", "18rem"),
          ]),
          ui.submit_button(button.Secondary, [], [text("Search")]),
          case model.search {
            "" -> element.none()
            _ ->
              ui.sized_button(
                button.Ghost,
                button.Small,
                [event.on_click(ClearSearch)],
                [text("Clear")],
              )
          },
        ]),
      ]),
      ui.native_select(
        [attribute.name("show"), live.on_value("show", ShowOnly)],
        [
          shared.option("all", "All traces", model.show == Everything),
          shared.option("failures", "With failures", model.show == Failures),
          shared.option(
            "slow",
            "Slower than " <> format.duration(slow_trace_us),
            model.show == Slow,
          ),
        ],
      ),
      ui.native_select(
        [attribute.name("tooling"), live.on_value("tooling", Tooling)],
        [
          shared.option("no", "Hide admin requests", !model.tooling),
          shared.option("yes", "Show admin requests", model.tooling),
        ],
      ),
      ui.button(button.Outline, [event.on_click(ClearAll)], [text("Clear all")]),
    ]),
    case model.summaries {
      [] ->
        ui.empty(
          icon: text("◷"),
          title: case model.search, model.show {
            "", Everything -> "No traces yet"
            _, _ -> "Nothing matches"
          },
          description: case model.search, model.show {
            "", Everything ->
              "Use your app and its requests appear here as they finish."
            _, _ -> "Clear the search or show all traces."
          },
          actions: [],
        )
      summaries ->
        ui.table([], [
          ui.table_header([], [
            ui.table_row([], [
              ui.table_head([], [text("Finished")]),
              ui.table_head([], [text("Trace")]),
              ui.table_head([], [text("Status")]),
              ui.table_head([], [text("Duration")]),
              ui.table_head([], [text("Spans")]),
              ui.table_head([], [text("Queries")]),
            ]),
          ]),
          ui.table_body([], list.map(summaries, summary_row(config, _))),
        ])
    },
  ])
}

fn summary_row(config: Config, summary: shared.Summary) -> Element(msg) {
  let root = summary.trace.root
  ui.table_row([], [
    ui.table_cell([], [text(format.clock(root.start + root.duration))]),
    ui.table_cell([], [
      ui.link(shared.trace_href(config, root.trace_id), [text(root.name)]),
      case recorder.attribute(root, "url.path") {
        Some(recorder.Text(path)) if path != "" ->
          html.div([], [ui.muted(layout.clip(path))])
        _ -> element.none()
      },
    ]),
    ui.table_cell([], [shared.status_badge(summary.status, summary.trace)]),
    ui.table_cell([], [layout.mono(format.duration(root.duration))]),
    ui.table_cell([], [text(int.to_string(summary.trace.spans))]),
    ui.table_cell([], [
      text(int.to_string(summary.queries)),
      case summary.repeated {
        [] -> element.none()
        _ ->
          html.span([], [
            text(" "),
            ui.badge(badge.Outline, [], [text("repeated")]),
          ])
      },
    ]),
  ])
}
