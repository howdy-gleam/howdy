//// The live grid of a table's rows: searched, filtered, sorted and paged,
//// refreshed as the table changes and marking the rows that did.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/timestamp
import gloo/repo.{type Repo}
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/data/forms
import howdy/admin/internal/layout
import howdy/admin/internal/notify
import howdy/admin/internal/schema.{type Row, type Table}
import howdy/service
import howdy/ui
import howdy/ui/badge
import howdy/ui/button
import howdy/ui/live
import howdy/ui/pagination
import howdy/ui/words
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event
import lustre/server_component
import pog

/// How often the grid checks the table for changes, in milliseconds.
const refresh_ms = 1000

/// With notifications, how often the grid still checks, in case one was
/// missed while the listener reconnected.
const fallback_ms = 15_000

/// How long a changed row stays marked, in milliseconds.
const highlight_ms = 4000

pub type Args {
  Args(config: Config, repo: Repo, table: Table)
}

pub type Model {
  Model(
    config: Config,
    repo: Repo,
    table: Table,
    query: schema.Query,
    total: Int,
    rows: List(Row),
    /// Keys of rows that changed recently, with when, in milliseconds.
    changed: Dict(List(String), Int),
    /// Whether anything has been loaded yet; the first load is not a change.
    loaded: Bool,
    /// Whether the database announces changes, so polling is only a backstop.
    notified: Bool,
    /// Where timers send their messages: a subject of the runtime's own,
    /// which it selects on. `None` until the runtime has handed it over.
    clock: Option(Subject(Msg)),
    /// The next `Tick`, so a change of pace can cancel it.
    next_tick: Option(process.Timer),
    error: Option(service.Error),
  )
}

pub type Msg {
  /// The runtime's subject for timers, once it exists.
  Clock(Subject(Msg))
  /// Whether the database will announce changes.
  Subscribed(Bool)
  /// Time to look again.
  Tick
  /// The database said the table changed.
  Changed
  /// Time to drop old change marks.
  Expire
  Go(Int)
  PerPage(String)
  Search(List(#(String, String)))
  ClearSearch
  SortBy(String)
  AddFilter(List(#(String, String)))
  RemoveFilter(Int)
  Delete(List(String))
}

pub fn grid() -> lustre.App(Args, Model, Msg) {
  lustre.application(init:, update:, view:)
}

fn init(args: Args) -> #(Model, Effect(Msg)) {
  let model =
    Model(
      config: args.config,
      repo: args.repo,
      table: args.table,
      query: schema.query(),
      total: 0,
      rows: [],
      changed: dict.new(),
      loaded: False,
      notified: False,
      clock: None,
      next_tick: None,
      error: None,
    )
  let model = load(model)
  // The clock comes first, so its subject is in hand before anything the
  // subscription sends. Polling starts once it arrives.
  #(
    model,
    effect.batch([
      clock(),
      case
        notify.available(args.repo, args.config.listen)
        && notify.install(args.repo, args.table) == Ok(Nil)
      {
        True -> subscribe(args.repo, args.config.listen, args.table)
        False -> effect.none()
      },
    ]),
  )
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  let query = model.query
  case msg {
    Clock(subject) -> schedule(Model(..model, clock: Some(subject)))
    Subscribed(notified) -> schedule(Model(..model, notified:))
    Tick -> schedule(load(model))
    Changed -> after(load(model), highlight_ms + 500, Expire)
    Expire -> #(prune(model), effect.none())
    Go(page) -> #(
      load(requery(
        model,
        schema.Query(..query, offset: { page - 1 } * query.limit),
      )),
      effect.none(),
    )
    PerPage(size) -> {
      let limit =
        int.parse(size) |> result.unwrap(query.limit) |> int.clamp(10, 500)
      #(
        load(requery(model, schema.Query(..query, limit:, offset: 0))),
        effect.none(),
      )
    }
    Search(fields) -> {
      let term = list.key_find(fields, "q") |> result.unwrap("")
      #(
        load(requery(model, schema.Query(..query, search: term, offset: 0))),
        effect.none(),
      )
    }
    ClearSearch -> #(
      load(requery(model, schema.Query(..query, search: "", offset: 0))),
      effect.none(),
    )
    SortBy(column) -> {
      let sort = case query.sort {
        Some(#(current, schema.Ascending)) if current == column ->
          Some(#(column, schema.Descending))
        Some(#(current, schema.Descending)) if current == column -> None
        _ -> Some(#(column, schema.Ascending))
      }
      #(load(requery(model, schema.Query(..query, sort:))), effect.none())
    }
    AddFilter(fields) -> {
      let filter = {
        let field = fn(name) {
          list.key_find(fields, name) |> result.unwrap("")
        }
        use operator <- result.try(schema.operator_from(field("operator")))
        use _ <- result.try(
          list.find(model.table.columns, fn(c) { c.name == field("column") }),
        )
        Ok(schema.Filter(field("column"), operator, field("value")))
      }
      case filter {
        Ok(filter) -> #(
          load(requery(
            model,
            schema.Query(
              ..query,
              filters: list.append(query.filters, [filter]),
              offset: 0,
            ),
          )),
          effect.none(),
        )
        Error(Nil) -> #(model, effect.none())
      }
    }
    RemoveFilter(index) -> {
      let filters =
        list.index_map(query.filters, fn(filter, at) { #(at, filter) })
        |> list.filter(fn(pair) { pair.0 != index })
        |> list.map(fn(pair) { pair.1 })
      #(
        load(requery(model, schema.Query(..query, filters:, offset: 0))),
        effect.none(),
      )
    }
    Delete(key) -> {
      let model = case schema.delete(model.repo, model.table, key) {
        Ok(Nil) -> model
        Error(error) -> Model(..model, error: Some(error))
      }
      #(load(model), effect.none())
    }
  }
}

/// A new query is a new view: nothing in it counts as changed.
fn requery(model: Model, query: schema.Query) -> Model {
  Model(..model, query:, loaded: False, changed: dict.new())
}

/// Ask the runtime for a subject to send timer messages to. The runtime
/// selects on it, so timers are plain `send_after`s that die with it.
fn clock() -> Effect(Msg) {
  use dispatch, subject <- server_component.select
  dispatch(Clock(subject))
  process.new_selector() |> process.select(subject)
}

/// Look again after the polling interval, replacing any tick already set,
/// so a change of pace takes effect at once.
fn schedule(model: Model) -> #(Model, Effect(Msg)) {
  case model.clock {
    None -> #(model, effect.none())
    Some(clock) -> {
      case model.next_tick {
        Some(timer) -> {
          let _ = process.cancel_timer(timer)
          Nil
        }
        None -> Nil
      }
      let milliseconds = case model.notified {
        True -> fallback_ms
        False -> refresh_ms
      }
      let timer = process.send_after(clock, milliseconds, Tick)
      #(Model(..model, next_tick: Some(timer)), effect.none())
    }
  }
}

/// Send `msg` to the runtime in `milliseconds`. Nothing is sent before the
/// clock arrives, which only the first messages of a runtime's life can
/// precede.
fn after(model: Model, milliseconds: Int, msg: Msg) -> #(Model, Effect(Msg)) {
  case model.clock {
    Some(clock) -> {
      let _ = process.send_after(clock, milliseconds, msg)
      Nil
    }
    None -> Nil
  }
  #(model, effect.none())
}

/// Hear the database name this table. The effect runs in the runtime's
/// process, so the listener is linked to the runtime and follows its
/// life. Whether it is listening decides how often the grid polls.
fn subscribe(
  repo: Repo,
  listen: Option(pog.Config),
  table: Table,
) -> Effect(Msg) {
  use dispatch <- effect.from
  let name = table.name
  let subscribed =
    notify.subscribe(repo, listen, fn(changed) {
      case changed == name {
        True -> dispatch(Changed)
        False -> Nil
      }
    })
  dispatch(Subscribed(result.is_ok(subscribed)))
}

fn now() -> Int {
  timestamp.system_time()
  |> timestamp.to_unix_seconds_and_nanoseconds
  |> fn(parts) { parts.0 * 1000 + parts.1 / 1_000_000 }
}

/// Forget marks older than `highlight_ms`.
fn prune(model: Model) -> Model {
  let now = now()
  Model(
    ..model,
    changed: dict.filter(model.changed, fn(_, since) {
      now - since < highlight_ms
    }),
  )
}

/// Read the current page again and note which rows differ from last time.
fn load(model: Model) -> Model {
  let loaded = {
    use total <- result.try(schema.count(model.repo, model.table, model.query))
    // A page past the end, after deletions or a narrower query, becomes the
    // last page.
    let pages = pages(total, model.query.limit)
    let offset = int.min(model.query.offset, { pages - 1 } * model.query.limit)
    let query = schema.Query(..model.query, offset:)
    use rows <- result.try(schema.rows(model.repo, model.table, query))
    Ok(#(total, rows, query))
  }
  case loaded {
    Error(error) -> Model(..model, error: Some(error))
    Ok(#(total, rows, query)) -> {
      let now = now()
      let changed = prune(model).changed
      let changed = case model.loaded {
        False -> changed
        True ->
          list.fold(rows, changed, fn(changed, row) {
            case list.contains(model.rows, row) {
              True -> changed
              False -> dict.insert(changed, row.key, now)
            }
          })
      }
      Model(..model, query:, total:, rows:, changed:, loaded: True, error: None)
    }
  }
}

fn pages(total: Int, per: Int) -> Int {
  int.max(1, { total + per - 1 } / per)
}

fn page(model: Model) -> Int {
  model.query.offset / model.query.limit + 1
}

fn view(model: Model) -> Element(Msg) {
  let table = model.table
  let pages = pages(model.total, model.query.limit)
  ui.stack([], [
    case model.error {
      Some(error) -> layout.problem(error)
      None -> element.none()
    },
    toolbar(model),
    ui.row([], [
      ui.muted(
        int.to_string(model.total)
        <> case model.query.search, model.query.filters {
          "", [] -> " rows"
          _, _ -> " matching rows"
        }
        <> " · page "
        <> int.to_string(page(model))
        <> " of "
        <> int.to_string(pages)
        <> case model.notified {
          True -> " · follows PostgreSQL NOTIFY"
          False -> " · refreshes every second"
        },
      ),
    ]),
    case model.rows {
      [] ->
        ui.empty(
          icon: text("∅"),
          title: case model.query.search, model.query.filters {
            "", [] -> "No rows"
            _, _ -> "Nothing matches"
          },
          description: case model.query.search, model.query.filters {
            "", [] ->
              "This table is empty. Insert a row, or watch here as your application writes one."
            _, _ -> "Clear the search or a filter to see more."
          },
          actions: [],
        )
      rows ->
        ui.table([], [
          ui.table_header([], [
            ui.table_row(
              [],
              list.append(
                list.map(table.columns, fn(column) {
                  ui.table_head([], [sort_button(model, column.name)])
                }),
                [ui.table_head([], [text("")])],
              ),
            ),
          ]),
          ui.table_body([], list.map(rows, row_view(model, _))),
        ])
    },
    case pages > 1 {
      True ->
        pagination.live_pagination(
          words: words.english(),
          current: page(model),
          total: pages,
          attributes: fn(page) {
            [
              event.on_click(Go(page)) |> event.prevent_default,
              attribute.href("#"),
            ]
          },
        )
      False -> element.none()
    },
  ])
}

/// Search, filters and page size.
fn toolbar(model: Model) -> Element(Msg) {
  let query = model.query
  ui.stack([], [
    ui.row([], [
      html.form([event.on_submit(Search)], [
        ui.row([], [
          ui.input([
            attribute.type_("search"),
            attribute.name("q"),
            attribute.value(query.search),
            attribute.placeholder("search every column"),
            attribute.style("width", "20rem"),
          ]),
          ui.submit_button(button.Secondary, [], [text("Search")]),
          case query.search {
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
        [attribute.name("per"), live.on_value("per", PerPage)],
        list.map([10, 25, 50, 100, 250], fn(size) {
          html.option(
            [
              attribute.value(int.to_string(size)),
              attribute.selected(size == query.limit),
            ],
            int.to_string(size) <> " per page",
          )
        }),
      ),
    ]),
    html.form([event.on_submit(AddFilter)], [
      ui.row([], [
        ui.native_select(
          [attribute.name("column")],
          list.map(model.table.columns, fn(column) {
            html.option([attribute.value(column.name)], column.name)
          }),
        ),
        ui.native_select(
          [attribute.name("operator")],
          list.map(schema.operators(), fn(operator) {
            html.option(
              [attribute.value(schema.operator_name(operator))],
              schema.operator_label(operator),
            )
          }),
        ),
        ui.input([
          attribute.name("value"),
          attribute.placeholder("value"),
          attribute.style("width", "14rem"),
        ]),
        ui.submit_button(button.Outline, [], [text("Add filter")]),
      ]),
    ]),
    case query.filters {
      [] -> element.none()
      filters ->
        ui.row(
          [],
          list.index_map(filters, fn(filter, index) {
            ui.badge(badge.Secondary, [], [
              text(
                filter.column
                <> " "
                <> schema.operator_label(filter.operator)
                <> case filter.operator {
                  schema.IsNull | schema.NotNull -> ""
                  _ -> " " <> filter.value
                },
              ),
              text(" "),
              html.button(
                [
                  attribute.type_("button"),
                  attribute.aria_label("Remove filter"),
                  event.on_click(RemoveFilter(index)),
                ],
                [text("×")],
              ),
            ])
          }),
        )
    },
  ])
}

/// A column heading that sorts by the column: ascending, then descending,
/// then back to key order.
fn sort_button(model: Model, column: String) -> Element(Msg) {
  let indicator = case model.query.sort {
    Some(#(current, schema.Ascending)) if current == column -> " ▲"
    Some(#(current, schema.Descending)) if current == column -> " ▼"
    _ -> ""
  }
  ui.sized_button(
    button.Ghost,
    button.ExtraSmall,
    [event.on_click(SortBy(column))],
    [text(column <> indicator)],
  )
}

fn row_view(model: Model, row: Row) -> Element(Msg) {
  let recent = dict.has_key(model.changed, row.key)
  ui.table_row(
    [],
    list.append(
      list.map(row.cells, fn(cell) {
        ui.table_cell([], [
          case cell {
            Some(value) -> text(layout.clip(value))
            None -> ui.muted("NULL")
          },
        ])
      }),
      [
        ui.table_cell([], [
          ui.row([], [
            case recent {
              True -> ui.badge(badge.Primary, [], [text("changed")])
              False -> element.none()
            },
            ui.link(forms.row_path(model.config, model.table.name, row.key), [
              text("Edit"),
            ]),
            ui.sized_button(
              button.Ghost,
              button.Small,
              [event.on_click(Delete(row.key))],
              [text("Delete")],
            ),
          ]),
        ]),
      ],
    ),
  )
}
