//// A live orders table: sort by column, filter by status and due date,
//// select rows, mark them paid, and page through the results. Every
//// change is a message to the server, which renders the new table.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/string
import howdy/ui
import howdy/ui/badge
import howdy/ui/button.{Outline, Primary}
import howdy/ui/calendar.{type Date, Date}
import howdy/ui/chart
import howdy/ui/data_table.{Ascending, Events, Sort}
import howdy/ui/live
import howdy/ui/pagination
import howdy/ui/toast
import howdy/ui/words
import lustre
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event

pub type Status {
  Paid
  Pending
  Refunded
}

pub type Order {
  Order(id: String, customer: String, status: Status, amount: Int, due: Date)
}

pub type Model {
  Model(
    orders: List(Order),
    sort: option.Option(data_table.Sort),
    selected: List(String),
    status: String,
    due_by: option.Option(Date),
    month: Date,
    page: Int,
    toasts: List(#(Int, String)),
    next_toast: Int,
  )
}

pub type Msg {
  SortBy(data_table.Sort)
  Toggle(String)
  ToggleAll
  FilterStatus(String)
  DueBy(String)
  PreviousMonth
  NextMonth
  GoTo(Int)
  MarkPaid
  ClearSelection
}

const per_page = 6

pub fn app(today: Date) -> lustre.App(Nil, Model, Msg) {
  lustre.simple(init: fn(_) { init(today) }, update:, view:)
}

fn init(today: Date) -> Model {
  Model(
    orders: sample_orders(today),
    sort: Some(Sort(column: "due", direction: Ascending)),
    selected: [],
    status: "",
    due_by: None,
    month: Date(today.year, today.month, 1),
    page: 1,
    toasts: [],
    next_toast: 1,
  )
}

fn update(model: Model, msg: Msg) -> Model {
  case msg {
    SortBy(sort) -> Model(..model, sort: Some(sort), page: 1)
    Toggle(id) ->
      case list.contains(model.selected, id) {
        True ->
          Model(
            ..model,
            selected: list.filter(model.selected, fn(x) { x != id }),
          )
        False -> Model(..model, selected: [id, ..model.selected])
      }
    ToggleAll -> {
      let ids = list.map(visible(model), fn(order) { order.id })
      case list.all(ids, list.contains(model.selected, _)) {
        True ->
          Model(
            ..model,
            selected: list.filter(model.selected, fn(id) {
              !list.contains(ids, id)
            }),
          )
        False ->
          Model(
            ..model,
            selected: list.unique(list.append(ids, model.selected)),
          )
      }
    }
    FilterStatus(status) -> Model(..model, status:, page: 1, selected: [])
    DueBy(value) ->
      Model(
        ..model,
        due_by: option.from_result(calendar.from_iso(value)),
        page: 1,
        selected: [],
      )
    PreviousMonth -> Model(..model, month: calendar.add_months(model.month, -1))
    NextMonth -> Model(..model, month: calendar.add_months(model.month, 1))
    GoTo(page) -> Model(..model, page:)
    ClearSelection -> Model(..model, selected: [])
    MarkPaid -> {
      let count = list.length(model.selected)
      let orders =
        list.map(model.orders, fn(order) {
          case list.contains(model.selected, order.id) {
            True -> Order(..order, status: Paid)
            False -> order
          }
        })
      let message =
        int.to_string(count)
        <> case count {
          1 -> " order marked paid"
          _ -> " orders marked paid"
        }
      Model(
        ..model,
        orders:,
        selected: [],
        // Keep the last three: older toasts have long since faded.
        toasts: list.take([#(model.next_toast, message), ..model.toasts], 3),
        next_toast: model.next_toast + 1,
      )
    }
  }
}

/// The orders matching the filters, in no particular order.
fn filtered(model: Model) -> List(Order) {
  model.orders
  |> list.filter(fn(order) {
    model.status == "" || status_value(order.status) == model.status
  })
  |> list.filter(fn(order) {
    case model.due_by {
      Some(date) -> calendar.compare(order.due, date) != order.Gt
      None -> True
    }
  })
}

/// The page of orders being shown.
fn visible(model: Model) -> List(Order) {
  data_table.new(columns(), filtered(model))
  |> data_table.sort(model.sort, by: Events(SortBy))
  |> data_table.sorted_rows
  |> list.drop({ model.page - 1 } * per_page)
  |> list.take(per_page)
}

fn columns() {
  [
    data_table.column("id", "Order", fn(order: Order) { text(order.id) }),
    data_table.column("customer", "Customer", fn(order: Order) {
      text(order.customer)
    })
      |> data_table.sortable(fn(a: Order, b: Order) {
        string.compare(a.customer, b.customer)
      }),
    data_table.column("status", "Status", fn(order: Order) {
      ui.badge(status_badge(order.status), [], [
        text(status_label(order.status)),
      ])
    }),
    data_table.column("due", "Due", fn(order: Order) {
      text(calendar.long_date(order.due))
    })
      |> data_table.sortable(fn(a: Order, b: Order) {
        calendar.compare(a.due, b.due)
      }),
    data_table.column("amount", "Amount", fn(order: Order) {
      text("$" <> chart.format_number(int.to_float(order.amount)))
    })
      |> data_table.sortable(fn(a: Order, b: Order) {
        int.compare(a.amount, b.amount)
      })
      |> data_table.numeric,
  ]
}

fn view(model: Model) -> Element(Msg) {
  let matching = filtered(model)
  let pages = int.max(1, { list.length(matching) + per_page - 1 } / per_page)
  let page = int.clamp(model.page, 1, pages)
  let model = Model(..model, page:)
  let rows = visible(model)
  let chosen = list.length(model.selected)

  ui.card([], [
    ui.card_header([], [
      ui.card_title([html.h2([], [text("Orders")])]),
      ui.card_description([
        text(
          int.to_string(list.length(matching))
          <> " orders"
          <> case model.due_by {
            Some(date) -> " due by " <> calendar.long_date(date)
            None -> ""
          },
        ),
      ]),
    ]),
    ui.card_content([], [
      ui.stack([], [
        html.div([attribute.class("gallery-filters")], [
          html.div([live.on_value("status", FilterStatus)], [
            ui.label([attribute.for("status")], [text("Status")]),
            ui.combobox(
              words: words.english(),
              id: "status",
              name: "status",
              value: model.status,
              label: case model.status {
                "" -> "Any status"
                value -> status_label(status_from(value))
              },
              placeholder: "Any status",
              search: "Search statuses…",
              attributes: [],
              options: [
                ui.combobox_option("", selected: model.status == "", children: [
                  text("Any status"),
                ]),
                ..list.map([Paid, Pending, Refunded], fn(status) {
                  ui.combobox_option(
                    status_value(status),
                    selected: model.status == status_value(status),
                    children: [text(status_label(status))],
                  )
                })
              ],
            ),
          ]),
          html.div([live.on_value("due", DueBy)], [
            ui.label([attribute.for("due")], [text("Due by")]),
            due_calendar(model)
              |> calendar.navigation(
                previous: [event.on_click(PreviousMonth)],
                next: [event.on_click(NextMonth)],
              )
              |> calendar.name("due")
              |> calendar.picker(placeholder: "Any date"),
          ]),
        ]),
        case chosen {
          0 -> element.none()
          _ ->
            ui.row([attribute.class("gallery-bulk")], [
              ui.muted(int.to_string(chosen) <> " selected"),
              ui.sized_button(
                Primary,
                button.Small,
                [event.on_click(MarkPaid)],
                [
                  text("Mark paid"),
                ],
              ),
              ui.sized_button(
                Outline,
                button.Small,
                [event.on_click(ClearSelection)],
                [
                  text("Clear"),
                ],
              ),
            ])
        },
        data_table.new(columns(), rows)
          |> data_table.sort(model.sort, by: Events(SortBy))
          |> data_table.selectable(
            key: fn(order: Order) { order.id },
            selected: model.selected,
            toggle: fn(id) { [event.on_click(Toggle(id))] },
            toggle_all: [event.on_click(ToggleAll)],
          )
          |> data_table.empty([text("No orders match these filters.")])
          |> data_table.view,
        pagination.live_pagination(
          words: words.english(),
          current: page,
          total: pages,
          attributes: fn(n) {
            [
              attribute.href("#page-" <> int.to_string(n)),
              event.on_click(GoTo(n)) |> event.prevent_default,
            ]
          },
        ),
      ]),
    ]),
    toast.region(
      words.english(),
      [],
      list.reverse(
        list.map(model.toasts, fn(entry) {
          toast.toast(
            toast.Info,
            [attribute.id("toast-" <> int.to_string(entry.0))],
            [
              toast.title([text(entry.1)]),
              toast.close([attribute.aria_label("Dismiss")]),
            ],
          )
        }),
      ),
    ),
  ])
}

fn status_badge(status: Status) -> badge.Variant {
  case status {
    Paid -> badge.Secondary
    Pending -> badge.Outline
    Refunded -> badge.Danger
  }
}

fn due_calendar(model: Model) -> calendar.Calendar(Msg) {
  calendar.new("due", year: model.month.year, month: model.month.month)
  |> calendar.selected(model.due_by)
}

fn status_label(status: Status) -> String {
  case status {
    Paid -> "Paid"
    Pending -> "Pending"
    Refunded -> "Refunded"
  }
}

fn status_value(status: Status) -> String {
  case status {
    Paid -> "paid"
    Pending -> "pending"
    Refunded -> "refunded"
  }
}

fn status_from(value: String) -> Status {
  case value {
    "paid" -> Paid
    "refunded" -> Refunded
    _ -> Pending
  }
}

fn sample_orders(today: Date) -> List(Order) {
  let customers = [
    "Ada Lovelace", "Grace Hopper", "Alan Turing", "Katherine Johnson",
    "Edsger Dijkstra", "Barbara Liskov", "Donald Knuth", "Margaret Hamilton",
    "John McCarthy", "Frances Allen", "Ken Thompson", "Radia Perlman",
  ]
  list.index_map(list.append(customers, customers), fn(customer, index) {
    Order(
      id: "#" <> int.to_string(1040 + index),
      customer:,
      status: case index % 5 {
        0 | 3 -> Pending
        4 -> Refunded
        _ -> Paid
      },
      amount: 40 + { index * 37 } % 460,
      due: calendar.add_days(today, { index * 5 } % 40 - 10),
    )
  })
}
