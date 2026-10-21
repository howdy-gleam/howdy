//// The recent log lines, live, and the card of a trace's own lines.

import gleam/erlang/process.{type Subject}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/format
import howdy/admin/internal/layout
import howdy/admin/internal/telemetry/shared
import howdy/content.{type Content}
import howdy/controller.{type Context}
import howdy/telemetry/recorder.{type Log, type Recorder}
import howdy/ui
import howdy/ui/badge
import howdy/ui/live
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}

pub fn page(config: Config, ctx: Context) -> Response(Content) {
  layout.page(
    config,
    ctx,
    current: "/telemetry/logs",
    heading: "Logs",
    live: True,
    content: [
      ui.p([
        ui.muted(
          "The newest log lines, with the trace each was written in. The last 2,000 are kept.",
        ),
      ]),
      live.mount(config.path(config, "/live/telemetry/logs")),
    ],
  )
}

pub type LogsModel {
  LogsModel(
    config: Config,
    recorder: Recorder,
    logs: List(Log),
    level: String,
    clock: Option(Subject(LogsMsg)),
  )
}

pub type LogsMsg {
  LogsClock(Subject(LogsMsg))
  LogsTick
  Level(String)
}

pub fn app() -> lustre.App(#(Config, Recorder), LogsModel, LogsMsg) {
  lustre.application(
    init: fn(args: #(Config, Recorder)) {
      #(
        load_logs(LogsModel(args.0, args.1, [], "all", None)),
        shared.ticking(LogsClock),
      )
    },
    update: fn(model: LogsModel, msg) {
      case msg {
        LogsClock(subject) -> {
          let model = LogsModel(..model, clock: Some(subject))
          #(model, logs_tick(model.clock))
        }
        LogsTick -> #(load_logs(model), logs_tick(model.clock))
        Level(level) -> #(load_logs(LogsModel(..model, level:)), effect.none())
      }
    },
    view: fn(model: LogsModel) {
      ui.stack([], [
        ui.row([], [
          ui.native_select(
            [attribute.name("level"), live.on_value("level", Level)],
            [
              shared.option("all", "Every level", model.level == "all"),
              shared.option(
                "warning",
                "Warnings and worse",
                model.level == "warning",
              ),
              shared.option("error", "Errors and worse", model.level == "error"),
            ],
          ),
        ]),
        card(model.config, model.logs, True),
      ])
    },
  )
}

fn logs_tick(clock: Option(Subject(LogsMsg))) -> Effect(LogsMsg) {
  shared.every_second(clock, LogsTick)
}

fn load_logs(model: LogsModel) -> LogsModel {
  let logs =
    recorder.recent_logs(model.recorder, limit: 2000)
    |> list.filter(fn(log) { at_least(log.level, model.level) })
    |> list.reverse
    |> list.take(200)
  LogsModel(..model, logs:)
}

fn at_least(level: String, threshold: String) -> Bool {
  severity(level) >= severity(threshold)
}

fn severity(level: String) -> Int {
  case level {
    "emergency" -> 7
    "alert" -> 6
    "critical" -> 5
    "error" -> 4
    "warning" -> 3
    "notice" -> 2
    "info" -> 1
    _ -> 0
  }
}

/// Log lines, newest first. `link` adds a column linking each line's trace.
pub fn card(config: Config, logs: List(Log), link: Bool) -> Element(msg) {
  case logs, link {
    [], False -> element.none()
    [], True ->
      ui.empty(
        icon: text("≡"),
        title: "No log lines",
        description: "Lines your app logs appear here as they are written.",
        actions: [],
      )
    logs, _ ->
      ui.card([], [
        ui.card_header([], [ui.card_title([text("Logs")])]),
        ui.card_content([], [
          ui.table([], [
            ui.table_header([], [
              ui.table_row(
                [],
                list.flatten([
                  [
                    ui.table_head([], [text("At")]),
                    ui.table_head([], [text("Level")]),
                    ui.table_head([], [text("Message")]),
                  ],
                  case link {
                    True -> [ui.table_head([], [text("Trace")])]
                    False -> []
                  },
                ]),
              ),
            ]),
            ui.table_body(
              [],
              list.map(logs, fn(log) {
                ui.table_row(
                  [],
                  list.flatten([
                    [
                      ui.table_cell([], [layout.mono(format.clock(log.at))]),
                      ui.table_cell([], [level_badge(log.level)]),
                      ui.table_cell([], [
                        shared.value(recorder.Text(log.message)),
                      ]),
                    ],
                    case link {
                      True -> [
                        ui.table_cell([], [
                          case log.trace_id {
                            Some(id) ->
                              ui.link(shared.trace_href(config, id), [
                                text("open"),
                              ])
                            None -> element.none()
                          },
                        ]),
                      ]
                      False -> []
                    },
                  ]),
                )
              }),
            ),
          ]),
        ]),
      ])
  }
}

fn level_badge(level: String) -> Element(msg) {
  let variant = case severity(level) {
    s if s >= 4 -> badge.Danger
    3 -> badge.Outline
    _ -> badge.Secondary
  }
  ui.badge(variant, [], [text(level)])
}
