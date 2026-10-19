//// Data tables: rows of records with sortable columns and selectable rows.
////
//// ```gleam
//// let columns = [
////   data_table.column("id", "Invoice", fn(invoice) { text(invoice.id) }),
////   data_table.column("customer", "Customer", fn(invoice) { text(invoice.customer) })
////     |> data_table.sortable(fn(a, b) { string.compare(a.customer, b.customer) }),
////   data_table.column("amount", "Amount", fn(invoice) { text(money(invoice.amount)) })
////     |> data_table.sortable(fn(a, b) { int.compare(a.amount, b.amount) })
////     |> data_table.numeric,
//// ]
////
//// data_table.new(columns, invoices)
//// |> data_table.sort(model.sort, by: data_table.Events(SortBy))
//// |> data_table.selectable(
////   key: fn(invoice) { invoice.id },
////   selected: model.selected,
////   toggle: fn(id) { [event.on_check(fn(_) { Toggle(id) })] },
////   toggle_all: [event.on_check(ToggleAll)],
//// )
//// |> data_table.empty([text("No invoices yet.")])
//// |> data_table.view
//// ```
////
//// Sorting, selection and paging live on the server: the table shows the
//// rows it is given, sorted by the current `Sort` with the column's own
//// comparison. A header click asks for the next sort, through a link on a
//// page or a message in a live view. Put a search box above the table and
//// `howdy/ui/pagination` below it to filter and page the rows you pass in.

import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order}
import howdy/ui/button
import howdy/ui/menu
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import howdy/ui/words.{type Words} as ui_words
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event
import sketch/css.{type Class}
import sketch/css/length.{percent, rem}

pub type Direction {
  Ascending
  Descending
}

/// Which column the rows are sorted by, and which way.
pub type Sort {
  Sort(column: String, direction: Direction)
}

/// What a sortable header does when clicked: follow a link, or send a
/// message. Each is given the sort to ask for next.
pub type SortBy(msg) {
  Links(fn(Sort) -> String)
  Events(fn(Sort) -> msg)
}

pub opaque type Column(row, msg) {
  Column(
    key: String,
    header: String,
    cell: fn(row) -> Element(msg),
    compare: Option(fn(row, row) -> Order),
    numeric: Bool,
  )
}

/// A column. `key` names it in a `Sort`.
pub fn column(
  key: String,
  header: String,
  cell: fn(row) -> Element(msg),
) -> Column(row, msg) {
  Column(key:, header:, cell:, compare: None, numeric: False)
}

/// Let the column be sorted, comparing rows with `compare`.
pub fn sortable(
  column: Column(row, msg),
  compare: fn(row, row) -> Order,
) -> Column(row, msg) {
  Column(..column, compare: Some(compare))
}

/// Align the column to the end, for numbers.
pub fn numeric(column: Column(row, msg)) -> Column(row, msg) {
  Column(..column, numeric: True)
}

type Selection(row, msg) {
  Selection(
    key: fn(row) -> String,
    selected: List(String),
    toggle: fn(String) -> List(Attribute(msg)),
    toggle_all: List(Attribute(msg)),
  )
}

pub opaque type DataTable(row, msg) {
  DataTable(
    columns: List(Column(row, msg)),
    rows: List(row),
    sort: Option(Sort),
    sort_by: Option(SortBy(msg)),
    selection: Option(Selection(row, msg)),
    empty: Option(List(Element(msg))),
    caption: List(Element(msg)),
    hidden: List(String),
    words: Words,
  )
}

pub fn new(
  columns: List(Column(row, msg)),
  rows: List(row),
) -> DataTable(row, msg) {
  DataTable(
    columns:,
    rows:,
    sort: None,
    sort_by: None,
    selection: None,
    empty: None,
    caption: [],
    hidden: [],
    words: ui_words.english(),
  )
}

/// Sort the rows by `sort`, and make the headers of sortable columns ask
/// for a new sort through `by`.
pub fn sort(
  table: DataTable(row, msg),
  sort: Option(Sort),
  by by: SortBy(msg),
) -> DataTable(row, msg) {
  DataTable(..table, sort:, sort_by: Some(by))
}

/// Add a checkbox to each row and one to the header for all rows. `key`
/// identifies a row; rows whose key is in `selected` are checked.
/// `toggle` gives the attributes of a row's checkbox, such as a check
/// handler, and `toggle_all` those of the header's.
pub fn selectable(
  table: DataTable(row, msg),
  key key: fn(row) -> String,
  selected selected: List(String),
  toggle toggle: fn(String) -> List(Attribute(msg)),
  toggle_all toggle_all: List(Attribute(msg)),
) -> DataTable(row, msg) {
  DataTable(
    ..table,
    selection: Some(Selection(key:, selected:, toggle:, toggle_all:)),
  )
}

/// What to show when there are no rows, instead of the words'
/// `no_results`.
pub fn empty(
  table: DataTable(row, msg),
  children: List(Element(msg)),
) -> DataTable(row, msg) {
  DataTable(..table, empty: Some(children))
}

/// Speak another language: the empty message and the selection
/// checkboxes' labels. English by default.
pub fn words(table: DataTable(row, msg), words: Words) -> DataTable(row, msg) {
  DataTable(..table, words:)
}

/// A caption under the table, which also names it for screen readers.
pub fn caption(
  table: DataTable(row, msg),
  children: List(Element(msg)),
) -> DataTable(row, msg) {
  DataTable(..table, caption: children)
}

/// Leave out the columns with these keys, such as those a person has
/// turned off with `columns_menu`.
pub fn hide(
  table: DataTable(row, msg),
  keys: List(String),
) -> DataTable(row, msg) {
  DataTable(..table, hidden: keys)
}

/// A "Columns" button with a menu that turns each column on or off. `id`
/// names the menu; `toggle` gives the attributes of a column's menu item,
/// such as a click handler, given its key and whether it is shown now.
/// Keep the hidden keys in your model and pass them to `hide`.
pub fn columns_menu(
  table: DataTable(row, msg),
  id id: String,
  label label: String,
  toggle toggle: fn(String, Bool) -> List(Attribute(msg)),
) -> Element(msg) {
  html.div([], [
    button.sized(button.Outline, button.Small, menu.trigger(id), [text(label)]),
    menu.menu(
      id,
      [],
      list.map(table.columns, fn(column) {
        let shown = !list.contains(table.hidden, column.key)
        menu.checkbox_item(shown, toggle(column.key, shown), [
          text(column.header),
        ])
      }),
    ),
  ])
}

/// The rows as `table` shows them: sorted by its current sort.
pub fn sorted_rows(table: DataTable(row, msg)) -> List(row) {
  case table.sort {
    None -> table.rows
    Some(Sort(column: key, direction:)) ->
      case list.find(table.columns, fn(column) { column.key == key }) {
        Ok(Column(compare: Some(compare), ..)) ->
          list.sort(table.rows, fn(a, b) {
            case direction {
              Ascending -> compare(a, b)
              Descending -> compare(b, a)
            }
          })
        _ -> table.rows
      }
  }
}

pub fn view(table: DataTable(row, msg)) -> Element(msg) {
  let rows = sorted_rows(table)
  let table =
    DataTable(
      ..table,
      columns: list.filter(table.columns, fn(column) {
        !list.contains(table.hidden, column.key)
      }),
    )
  let width =
    list.length(table.columns)
    + case table.selection {
      Some(_) -> 1
      None -> 0
    }
  let caption = case table.caption {
    [] -> []
    children -> [html.caption([class(caption_class())], children)]
  }
  let body = case rows {
    [] -> [
      html.tr([], [
        html.td(
          [
            class(empty_class()),
            attribute.attribute("colspan", int.to_string(width)),
          ],
          option.unwrap(table.empty, [text(table.words.no_results)]),
        ),
      ]),
    ]
    _ -> list.map(rows, row(table, _))
  }
  html.div([class(scroll_class())], [
    html.table(
      [class(table_class())],
      list.append(caption, [
        html.thead([], [html.tr([], header(table, rows))]),
        html.tbody([], body),
      ]),
    ),
  ])
}

fn header(table: DataTable(row, msg), rows: List(row)) -> List(Element(msg)) {
  let select_all = case table.selection {
    None -> []
    Some(selection) -> {
      let keys = list.map(rows, selection.key)
      let chosen = list.filter(keys, list.contains(selection.selected, _))
      let all = keys != [] && list.length(chosen) == list.length(keys)
      let some = chosen != [] && !all
      [
        html.th([class(check_cell_class())], [
          html.input([
            class(checkbox_class()),
            attribute.type_("checkbox"),
            attribute.aria_label(table.words.select_all_rows),
            attribute.checked(all),
            attribute.property("indeterminate", json.bool(some)),
            ..selection.toggle_all
          ]),
        ]),
      ]
    }
  }
  list.append(
    select_all,
    list.map(table.columns, fn(column) {
      let align = case column.numeric {
        True -> [attribute.data("numeric", "")]
        False -> []
      }
      case column.compare, table.sort_by {
        Some(_), Some(by) -> {
          let current = case table.sort {
            Some(Sort(column: key, direction:)) if key == column.key ->
              Some(direction)
            _ -> None
          }
          let #(aria, next) = case current {
            Some(Ascending) -> #("ascending", Descending)
            Some(Descending) -> #("descending", Ascending)
            None -> #("none", Ascending)
          }
          let next = Sort(column: column.key, direction: next)
          let indicator = case current {
            Some(Ascending) -> "↑"
            Some(Descending) -> "↓"
            None -> "↕"
          }
          let content = [
            text(column.header),
            html.span([class(indicator_class()), attribute.aria_hidden(True)], [
              text(indicator),
            ]),
          ]
          html.th(
            [
              class(head_class()),
              attribute.attribute("scope", "col"),
              attribute.attribute("aria-sort", aria),
              ..align
            ],
            [
              case by {
                Links(href) ->
                  html.a(
                    [class(sort_class()), attribute.href(href(next))],
                    content,
                  )
                Events(message) ->
                  html.button(
                    [
                      class(sort_class()),
                      attribute.type_("button"),
                      event.on_click(message(next)),
                    ],
                    content,
                  )
              },
            ],
          )
        }
        _, _ ->
          html.th(
            [class(head_class()), attribute.attribute("scope", "col"), ..align],
            [text(column.header)],
          )
      }
    }),
  )
}

fn row(table: DataTable(row, msg), record: row) -> Element(msg) {
  let #(checkbox, selected) = case table.selection {
    None -> #([], [])
    Some(selection) -> {
      let key = selection.key(record)
      let checked = list.contains(selection.selected, key)
      #(
        [
          html.td([class(check_cell_class())], [
            html.input([
              class(checkbox_class()),
              attribute.type_("checkbox"),
              attribute.aria_label(table.words.select_row),
              attribute.checked(checked),
              ..selection.toggle(key)
            ]),
          ]),
        ],
        [attribute.aria_selected(checked)],
      )
    }
  }
  html.tr(
    [class(row_class()), ..selected],
    list.append(
      checkbox,
      list.map(table.columns, fn(column) {
        let align = case column.numeric {
          True -> [attribute.data("numeric", "")]
          False -> []
        }
        html.td([class(cell_class()), ..align], [column.cell(record)])
      }),
    ),
  )
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    scroll_class(),
    table_class(),
    caption_class(),
    head_class(),
    sort_class(),
    indicator_class(),
    row_class(),
    cell_class(),
    check_cell_class(),
    checkbox_class(),
    empty_class(),
  ]
}

pub fn scroll_class() -> Class {
  css.class([
    css.width(percent(100)),
    css.overflow_x("auto"),
    style.bordered(),
    style.radius(tokens.radius_medium),
  ])
}

pub fn table_class() -> Class {
  css.class([
    css.width(percent(100)),
    css.border_collapse("collapse"),
    css.font_size(rem(0.875)),
    css.color(tokens.text),
  ])
}

pub fn caption_class() -> Class {
  css.class([
    css.property("caption-side", "bottom"),
    css.padding(rem(0.75)),
    css.color(tokens.text_muted),
    style.bordered_side("top"),
  ])
}

pub fn head_class() -> Class {
  css.class([
    css.padding_(tokens.space_2 <> " " <> tokens.space_3),
    css.text_align("start"),
    css.font_weight("500"),
    css.white_space("nowrap"),
    style.bordered_side("bottom"),
    css.selector("[data-numeric]", [css.text_align("end")]),
  ])
}

pub fn sort_class() -> Class {
  css.class([
    css.display("inline-flex"),
    css.align_items("center"),
    css.gap(rem(0.375)),
    css.margin_("0 -" <> tokens.space_2),
    css.padding_(tokens.space_1 <> " " <> tokens.space_2),
    css.border("0"),
    style.radius(tokens.radius_small),
    css.background("transparent"),
    css.color("inherit"),
    css.font("inherit"),
    css.text_decoration("none"),
    css.cursor("pointer"),
    css.hover([css.background(tokens.muted)]),
    style.focus_ring(),
  ])
}

pub fn indicator_class() -> Class {
  css.class([css.color(tokens.text_muted), css.font_size(rem(0.75))])
}

pub fn row_class() -> Class {
  css.class([
    style.bordered_side("bottom"),
    css.last_child([css.property("border-bottom", "0")]),
    css.hover([css.background(tokens.muted)]),
    css.selector("[aria-selected=\"true\"]", [css.background(tokens.muted)]),
  ])
}

pub fn cell_class() -> Class {
  css.class([
    css.padding_(tokens.space_2 <> " " <> tokens.space_3),
    css.vertical_align("middle"),
    css.selector("[data-numeric]", [
      css.text_align("end"),
      css.property("font-variant-numeric", "tabular-nums"),
    ]),
  ])
}

pub fn check_cell_class() -> Class {
  css.class([
    css.property("width", "1%"),
    css.padding_(
      tokens.space_2 <> " 0 " <> tokens.space_2 <> " " <> tokens.space_3,
    ),
    style.bordered_side("bottom"),
    css.vertical_align("middle"),
  ])
}

pub fn checkbox_class() -> Class {
  css.class([
    css.display("block"),
    css.property("width", "1rem"),
    css.property("height", "1rem"),
    css.margin(rem(0.0)),
    css.property("accent-color", tokens.primary),
    css.cursor("pointer"),
  ])
}

pub fn empty_class() -> Class {
  css.class([
    css.padding_(tokens.space_8 <> " " <> tokens.space_4),
    css.text_align("center"),
    css.color(tokens.text_muted),
  ])
}
