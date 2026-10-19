//// The jobs pages: each queue's jobs by state, with pausing; the schedules
//// a runner keeps; the jobs themselves, filtered and paged, as they change;
//// and one job in full, with its errors, to retry, cancel or delete.

import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import gleam/uri
import gloo/repo.{type Repo}
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/format
import howdy/admin/internal/layout
import howdy/admin/internal/telemetry/shared
import howdy/content.{type Content}
import howdy/controller.{type Context, type Controller}
import howdy/jobs.{type Record, type Runner}
import howdy/service
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

/// How many jobs a page of the list shows.
const page_size = 50

pub fn controller(config: Config, runner: Runner) -> Controller {
  let act = fn(change, after) {
    fn(ctx) { act(config, runner, ctx, change, after) }
  }
  controller.new(config.prefix)
  |> controller.get("/jobs", fn(ctx) { index(config, ctx) })
  |> controller.get("/jobs/job", fn(ctx) { show(config, runner, ctx) })
  |> controller.post("/jobs/job/retry", act(jobs.retry, Stay))
  |> controller.post("/jobs/job/cancel", act(jobs.cancel, Stay))
  |> controller.post("/jobs/job/delete", act(jobs.delete, Leave))
  |> controller.get("/live/jobs", fn(ctx) {
    live.serve(ctx, app(), with: #(config, runner))
  })
}

pub fn job_path(config: Config, id: Int) -> String {
  config.path(config, "/jobs/job?")
  <> uri.query_to_string([#("id", int.to_string(id))])
}

// -- The index -----------------------------------------------------------------

fn index(config: Config, ctx: Context) -> Response(Content) {
  layout.page(
    config,
    ctx,
    current: "/jobs",
    heading: "Jobs",
    live: True,
    content: [
      ui.p([
        ui.muted(
          "The jobs in the database, as they are queued, run and finish. Pausing a queue stops every node taking jobs from it.",
        ),
      ]),
      live.mount(config.path(config, "/live/jobs")),
    ],
  )
}

pub type Model {
  Model(
    config: Config,
    runner: Runner,
    state: Option(jobs.State),
    queue: Option(String),
    name: Option(String),
    /// The id each earlier page started before, newest last, for going
    /// back; the current page starts before `before`.
    pages: List(Option(Int)),
    before: Option(Int),
    loaded: service.Result(Loaded),
    /// The last change made from the page, when it failed.
    problem: Option(service.Error),
    clock: Option(Subject(Msg)),
  )
}

pub type Loaded {
  Loaded(
    counts: List(jobs.Count),
    paused: List(String),
    schedules: List(jobs.Schedule),
    names: List(String),
    found: List(Record),
  )
}

pub type Msg {
  Clock(Subject(Msg))
  Tick
  ShowState(String)
  ShowQueue(String)
  ShowName(String)
  Older(Int)
  Newer
  Pause(String)
  Resume(String)
  Retry(Int)
  Cancel(Int)
}

fn app() -> lustre.App(#(Config, Runner), Model, Msg) {
  lustre.application(
    init: fn(args: #(Config, Runner)) {
      #(initial(args.0, args.1), shared.ticking(Clock))
    },
    update:,
    view:,
  )
}

fn initial(config: Config, runner: Runner) -> Model {
  Model(
    config:,
    runner:,
    state: None,
    queue: None,
    name: None,
    pages: [],
    before: None,
    loaded: Error(service.Internal("not loaded yet")),
    problem: None,
    clock: None,
  )
  |> load
}

/// The page as it first renders, for tests.
@internal
pub fn render(config: Config, runner: Runner) -> String {
  initial(config, runner) |> view |> element.to_string
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Clock(subject) -> {
      let model = Model(..model, clock: Some(subject))
      #(model, tick(model))
    }
    Tick -> #(load(model), tick(model))
    ShowState(value) ->
      first_page(
        Model(
          ..model,
          state: jobs.state_from_string(value) |> option.from_result,
        ),
      )
    ShowQueue(value) -> first_page(Model(..model, queue: chosen(value)))
    ShowName(value) -> first_page(Model(..model, name: chosen(value)))
    Older(id) -> #(
      load(
        Model(..model, pages: [model.before, ..model.pages], before: Some(id)),
      ),
      effect.none(),
    )
    Newer ->
      case model.pages {
        [before, ..pages] -> #(
          load(Model(..model, pages:, before:)),
          effect.none(),
        )
        [] -> #(model, effect.none())
      }
    Pause(queue) -> change(model, jobs.pause(jobs.repo(model.runner), queue))
    Resume(queue) -> change(model, jobs.resume(jobs.repo(model.runner), queue))
    Retry(id) -> change(model, jobs.retry(jobs.repo(model.runner), id))
    Cancel(id) -> change(model, jobs.cancel(jobs.repo(model.runner), id))
  }
}

fn chosen(value: String) -> Option(String) {
  case value {
    "" -> None
    value -> Some(value)
  }
}

fn first_page(model: Model) -> #(Model, Effect(Msg)) {
  #(load(Model(..model, pages: [], before: None)), effect.none())
}

fn change(model: Model, outcome: service.Result(Nil)) -> #(Model, Effect(Msg)) {
  let problem = case outcome {
    Ok(Nil) -> None
    Error(error) -> Some(error)
  }
  #(load(Model(..model, problem:)), effect.none())
}

/// The database is not in memory, but the page is development only and the
/// queries are small: look again every second.
fn tick(model: Model) -> Effect(Msg) {
  shared.every_second(model.clock, Tick)
}

fn load(model: Model) -> Model {
  let repo = jobs.repo(model.runner)
  let listing =
    jobs.listing()
    |> jobs.limit(page_size + 1)
    |> maybe(model.state, jobs.in_state)
    |> maybe(model.queue, jobs.in_queue)
    |> maybe(model.name, jobs.named)
    |> maybe(model.before, jobs.before)
  let loaded = {
    use counts <- result.try(jobs.counts(repo))
    use paused <- result.try(jobs.paused(repo))
    use schedules <- result.try(jobs.schedules(model.runner))
    use names <- result.try(jobs.stored_names(repo))
    use found <- result.try(jobs.list(repo, listing))
    Ok(Loaded(counts:, paused:, schedules:, names:, found:))
  }
  Model(..model, loaded:)
}

fn maybe(listing: a, value: Option(b), apply: fn(a, b) -> a) -> a {
  case value {
    Some(value) -> apply(listing, value)
    None -> listing
  }
}

fn view(model: Model) -> Element(Msg) {
  case model.loaded {
    Error(error) -> layout.problem(error)
    Ok(loaded) ->
      ui.stack([], [
        case model.problem {
          Some(error) -> layout.problem(error)
          None -> element.none()
        },
        queues_card(model, loaded),
        case loaded.schedules {
          [] -> element.none()
          schedules -> schedules_card(schedules)
        },
        jobs_card(model, loaded),
      ])
  }
}

// -- Queues ----------------------------------------------------------------------

fn queues_card(model: Model, loaded: Loaded) -> Element(Msg) {
  let configured = jobs.queues(model.runner)
  let queues =
    list.flatten([
      list.map(configured, fn(queue) { queue.0 }),
      list.map(loaded.counts, fn(count) { count.queue }),
      loaded.paused,
    ])
    |> list.unique
    |> list.sort(string.compare)
  ui.card([], [
    ui.card_header([], [ui.card_title([text("Queues")])]),
    ui.card_content([], [
      case queues {
        [] -> ui.muted("No queues yet.")
        _ ->
          ui.table([], [
            ui.table_header([], [
              ui.table_row(
                [],
                list.flatten([
                  [
                    ui.table_head([], [text("Queue")]),
                    ui.table_head([], [text("This node runs")]),
                  ],
                  list.map(jobs.states, fn(state) {
                    ui.table_head([], [text(state_label(state))])
                  }),
                  [ui.table_head([], [])],
                ]),
              ),
            ]),
            ui.table_body(
              [],
              list.map(queues, fn(queue) {
                let paused = list.contains(loaded.paused, queue)
                ui.table_row(
                  [],
                  list.flatten([
                    [
                      ui.table_cell([], [
                        layout.mono(queue),
                        case paused {
                          True ->
                            html.span([], [
                              text(" "),
                              ui.badge(badge.Danger, [], [text("paused")]),
                            ])
                          False -> element.none()
                        },
                      ]),
                      ui.table_cell([], [
                        case list.key_find(configured, queue) {
                          Ok(limit) ->
                            text(format.describe(limit, "job") <> " at once")
                          Error(Nil) -> ui.muted("not taken here")
                        },
                      ]),
                    ],
                    list.map(jobs.states, fn(state) {
                      let count =
                        list.find(loaded.counts, fn(count) {
                          count.queue == queue && count.state == state
                        })
                        |> result.map(fn(count) { count.count })
                        |> result.unwrap(0)
                      ui.table_cell([], [
                        case count {
                          0 -> ui.muted("0")
                          n -> text(int.to_string(n))
                        },
                      ])
                    }),
                    [
                      ui.table_cell([], [
                        case paused {
                          True ->
                            ui.sized_button(
                              button.Outline,
                              button.Small,
                              [event.on_click(Resume(queue))],
                              [text("Resume")],
                            )
                          False ->
                            ui.sized_button(
                              button.Ghost,
                              button.Small,
                              [event.on_click(Pause(queue))],
                              [text("Pause")],
                            )
                        },
                      ]),
                    ],
                  ]),
                )
              }),
            ),
          ])
      },
    ]),
  ])
}

fn schedules_card(schedules: List(jobs.Schedule)) -> Element(Msg) {
  ui.card([], [
    ui.card_header([], [
      ui.card_title([text("Schedules")]),
      ui.card_description([text("Times are UTC.")]),
    ]),
    ui.card_content([], [
      ui.table([], [
        ui.table_header([], [
          ui.table_row([], [
            ui.table_head([], [text("Job")]),
            ui.table_head([], [text("Cron")]),
            ui.table_head([], [text("Queue")]),
            ui.table_head([], [text("Last queued")]),
            ui.table_head([], [text("Next")]),
          ]),
        ]),
        ui.table_body(
          [],
          list.map(schedules, fn(schedule) {
            ui.table_row([], [
              ui.table_cell([], [layout.mono(schedule.name)]),
              ui.table_cell([], [layout.mono(schedule.cron)]),
              ui.table_cell([], [text(schedule.queue)]),
              ui.table_cell([], [optional_time(schedule.last, "not yet")]),
              ui.table_cell([], [optional_time(schedule.next, "never")]),
            ])
          }),
        ),
      ]),
    ]),
  ])
}

// -- The jobs ----------------------------------------------------------------------

fn jobs_card(model: Model, loaded: Loaded) -> Element(Msg) {
  let queues =
    list.map(loaded.counts, fn(count) { count.queue })
    |> list.append(list.map(jobs.queues(model.runner), fn(queue) { queue.0 }))
    |> list.unique
    |> list.sort(string.compare)
  let names =
    list.append(loaded.names, jobs.handled(model.runner))
    |> list.unique
    |> list.sort(string.compare)
  let shown = list.take(loaded.found, page_size)
  let more = list.length(loaded.found) > page_size
  ui.card([], [
    ui.card_header([], [ui.card_title([text("Jobs")])]),
    ui.card_content([], [
      ui.stack([], [
        ui.row([], [
          ui.native_select(
            [
              attribute.name("state"),
              attribute.attribute("aria-label", "State"),
              live.on_value("state", ShowState),
            ],
            [
              shared.option("", "Every state", model.state == None),
              ..list.map(jobs.states, fn(state) {
                shared.option(
                  jobs.state_to_string(state),
                  state_label(state),
                  model.state == Some(state),
                )
              })
            ],
          ),
          ui.native_select(
            [
              attribute.name("queue"),
              attribute.attribute("aria-label", "Queue"),
              live.on_value("queue", ShowQueue),
            ],
            [
              shared.option("", "Every queue", model.queue == None),
              ..list.map(queues, fn(queue) {
                shared.option(queue, queue, model.queue == Some(queue))
              })
            ],
          ),
          ui.native_select(
            [
              attribute.name("job"),
              attribute.attribute("aria-label", "Job"),
              live.on_value("job", ShowName),
            ],
            [
              shared.option("", "Every job", model.name == None),
              ..list.map(names, fn(name) {
                shared.option(name, name, model.name == Some(name))
              })
            ],
          ),
        ]),
        case shown {
          [] ->
            ui.empty(
              icon: text("⚙"),
              title: case model.state, model.queue, model.name {
                None, None, None -> "No jobs yet"
                _, _, _ -> "Nothing matches"
              },
              description: "Jobs appear here as they are queued.",
              actions: [],
            )
          _ -> jobs_table(model.config, shown)
        },
        ui.row([], [
          case model.pages {
            [] -> element.none()
            _ ->
              ui.sized_button(
                button.Outline,
                button.Small,
                [event.on_click(Newer)],
                [text("Newer")],
              )
          },
          case more, list.last(shown) {
            True, Ok(last) ->
              ui.sized_button(
                button.Outline,
                button.Small,
                [event.on_click(Older(last.id))],
                [text("Older")],
              )
            _, _ -> element.none()
          },
        ]),
      ]),
    ]),
  ])
}

fn jobs_table(config: Config, shown: List(Record)) -> Element(Msg) {
  ui.table([], [
    ui.table_header([], [
      ui.table_row([], [
        ui.table_head([], [text("Job")]),
        ui.table_head([], [text("Queue")]),
        ui.table_head([], [text("State")]),
        ui.table_head([], [text("Attempt")]),
        ui.table_head([], [text("When")]),
        ui.table_head([], [text("Arguments")]),
        ui.table_head([], []),
      ]),
    ]),
    ui.table_body(
      [],
      list.map(shown, fn(job) {
        ui.table_row([], [
          ui.table_cell([], [
            ui.link(job_path(config, job.id), [
              layout.mono(job.name),
              ui.muted(" #" <> int.to_string(job.id)),
            ]),
          ]),
          ui.table_cell([], [text(job.queue)]),
          ui.table_cell([], [state_badge(job.state)]),
          ui.table_cell([], [
            text(
              int.to_string(job.attempt)
              <> "/"
              <> int.to_string(job.max_attempts),
            ),
          ]),
          ui.table_cell([], [text(when(job))]),
          ui.table_cell([], [layout.mono(layout.clip(job.args))]),
          ui.table_cell([], [
            ui.row(
              [],
              list.flatten([
                case can_retry(job.state) {
                  True -> [
                    ui.sized_button(
                      button.Ghost,
                      button.Small,
                      [event.on_click(Retry(job.id))],
                      [text(retry_label(job.state))],
                    ),
                  ]
                  False -> []
                },
                case can_cancel(job.state) {
                  True -> [
                    ui.sized_button(
                      button.Ghost,
                      button.Small,
                      [event.on_click(Cancel(job.id))],
                      [text("Cancel")],
                    ),
                  ]
                  False -> []
                },
              ]),
            ),
          ]),
        ])
      }),
    ),
  ])
}

// -- One job -------------------------------------------------------------------------

type After {
  Stay
  Leave
}

fn with_id(
  config: Config,
  ctx: Context,
  next: fn(Int) -> Response(Content),
) -> Response(Content) {
  case
    request.get_query(ctx.request)
    |> result.unwrap([])
    |> list.key_find("id")
    |> result.try(int.parse)
  {
    Ok(id) -> next(id)
    Error(Nil) ->
      layout.failed(
        config,
        ctx,
        current: "/jobs",
        heading: "Jobs",
        error: service.NotFound("job"),
      )
  }
}

fn act(
  config: Config,
  runner: Runner,
  ctx: Context,
  change: fn(Repo, Int) -> service.Result(Nil),
  after: After,
) -> Response(Content) {
  use id <- with_id(config, ctx)
  let repo = jobs.repo(runner)
  case change(repo, id), after {
    Ok(Nil), Stay -> layout.redirect(job_path(config, id))
    Ok(Nil), Leave -> layout.redirect(config.path(config, "/jobs"))
    Error(error), _ ->
      case jobs.get(repo, id) {
        Ok(job) -> job_page(config, ctx, runner, job, Some(error))
        Error(_) ->
          layout.failed(config, ctx, current: "/jobs", heading: "Jobs", error:)
      }
  }
}

fn show(config: Config, runner: Runner, ctx: Context) -> Response(Content) {
  use id <- with_id(config, ctx)
  case jobs.get(jobs.repo(runner), id) {
    Error(error) ->
      layout.failed(config, ctx, current: "/jobs", heading: "Jobs", error:)
    Ok(job) -> job_page(config, ctx, runner, job, None)
  }
}

fn job_page(
  config: Config,
  ctx: Context,
  runner: Runner,
  job: Record,
  problem: Option(service.Error),
) -> Response(Content) {
  let action = fn(name) {
    config.path(config, "/jobs/job/" <> name <> "?")
    <> uri.query_to_string([#("id", int.to_string(job.id))])
  }
  let form = fn(name, variant, label) {
    html.form([attribute.method("post"), attribute.action(action(name))], [
      ui.submit_button(variant, [], [text(label)]),
    ])
  }
  let handled = list.contains(jobs.handled(runner), job.name)
  layout.page(
    config,
    ctx,
    current: "/jobs",
    heading: job.name <> " #" <> int.to_string(job.id),
    live: False,
    content: [
      ui.p([
        ui.link(config.path(config, "/jobs"), [text("All jobs")]),
        text(" · "),
        state_badge(job.state),
      ]),
      case problem {
        Some(error) -> layout.problem(error)
        None -> element.none()
      },
      case handled {
        True -> element.none()
        False ->
          ui.p([
            ui.muted(
              "This app's runner has no handler for "
              <> job.name
              <> ", so it only runs on nodes that have one.",
            ),
          ])
      },
      ui.card([], [
        ui.card_content([], [
          layout.facts(
            list.flatten([
              [
                #("State", state_label(job.state)),
                #("Queue", job.queue),
                #("Priority", int.to_string(job.priority)),
                #(
                  "Attempt",
                  int.to_string(job.attempt)
                    <> " of "
                    <> int.to_string(job.max_attempts),
                ),
                #("Queued", time(job.inserted_at)),
                #("Due", time(job.scheduled_at)),
              ],
              optional_fact("Last started", option.map(job.attempted_at, time)),
              optional_fact("Run by", job.attempted_by),
              optional_fact("Finished", option.map(job.finished_at, time)),
              optional_fact("Unique key", job.unique_key),
            ]),
          ),
        ]),
        ui.card_footer([], [
          ui.row(
            [],
            list.flatten([
              case can_retry(job.state) {
                True -> [form("retry", button.Primary, retry_label(job.state))]
                False -> []
              },
              case can_cancel(job.state) {
                True -> [form("cancel", button.Outline, "Cancel")]
                False -> []
              },
              case job.state {
                jobs.Executing -> []
                _ -> [form("delete", button.Ghost, "Delete")]
              },
            ]),
          ),
        ]),
      ]),
      ui.card([], [
        ui.card_header([], [ui.card_title([text("Arguments")])]),
        ui.card_content([], [
          html.pre([attribute.style("white-space", "pre-wrap")], [
            layout.mono(job.args),
          ]),
        ]),
      ]),
      ui.card([], [
        ui.card_header([], [ui.card_title([text("Errors")])]),
        ui.card_content([], [
          case job.errors {
            [] -> ui.muted("None.")
            errors ->
              ui.table([], [
                ui.table_header([], [
                  ui.table_row([], [
                    ui.table_head([], [text("Attempt")]),
                    ui.table_head([], [text("At")]),
                    ui.table_head([], [text("What went wrong")]),
                  ]),
                ]),
                ui.table_body(
                  [],
                  list.map(list.reverse(errors), fn(failure) {
                    ui.table_row([], [
                      ui.table_cell([], [text(int.to_string(failure.attempt))]),
                      ui.table_cell([], [text(time(failure.at))]),
                      ui.table_cell([], [
                        html.pre([attribute.style("white-space", "pre-wrap")], [
                          layout.mono(failure.reason),
                        ]),
                      ]),
                    ])
                  }),
                ),
              ])
          },
        ]),
      ]),
    ],
  )
}

fn optional_fact(
  label: String,
  value: Option(String),
) -> List(#(String, String)) {
  case value {
    Some(value) -> [#(label, value)]
    None -> []
  }
}

// -- Pieces ---------------------------------------------------------------------------

fn state_label(state: jobs.State) -> String {
  case state {
    jobs.Available -> "Available"
    jobs.Scheduled -> "Scheduled"
    jobs.Executing -> "Running"
    jobs.Completed -> "Completed"
    jobs.Cancelled -> "Cancelled"
    jobs.Failed -> "Failed"
  }
}

fn state_badge(state: jobs.State) -> Element(msg) {
  let variant = case state {
    jobs.Failed -> badge.Danger
    jobs.Executing -> badge.Primary
    jobs.Completed -> badge.Secondary
    _ -> badge.Outline
  }
  ui.badge(variant, [], [text(state_label(state))])
}

fn can_retry(state: jobs.State) -> Bool {
  case state {
    jobs.Scheduled | jobs.Failed | jobs.Cancelled -> True
    _ -> False
  }
}

fn retry_label(state: jobs.State) -> String {
  case state {
    jobs.Scheduled -> "Run now"
    _ -> "Retry"
  }
}

fn can_cancel(state: jobs.State) -> Bool {
  case state {
    jobs.Available | jobs.Scheduled | jobs.Executing -> True
    _ -> False
  }
}

/// The moment that matters for a job in its state.
fn when(job: Record) -> String {
  case job.state, job.finished_at, job.attempted_at {
    jobs.Available, _, _ | jobs.Scheduled, _, _ ->
      "due " <> time(job.scheduled_at)
    jobs.Executing, _, Some(at) -> "started " <> time(at)
    _, Some(at), _ -> "finished " <> time(at)
    _, None, _ -> "queued " <> time(job.inserted_at)
  }
}

fn time(milliseconds: Int) -> String {
  format.date_time(timestamp.from_unix_seconds(milliseconds / 1000))
}

fn optional_time(milliseconds: Option(Int), otherwise: String) -> Element(msg) {
  case milliseconds {
    Some(at) -> text(time(at))
    None -> ui.muted(otherwise)
  }
}
