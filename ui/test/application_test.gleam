import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import howdy/flash
import howdy/ui
import howdy/ui/calendar.{Date}
import howdy/ui/chart
import howdy/ui/data_table.{Ascending, Descending, Events, Links, Sort}
import howdy/ui/internal/stylesheet
import howdy/ui/live
import howdy/ui/pagination
import howdy/ui/toast
import howdy/ui/words
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html

fn render(element: Element(msg)) -> String {
  element.to_string(element)
}

// -- Calendar ----------------------------------------------------------------

pub fn weekdays_are_right_across_eras_test() {
  // Monday is 1 and Sunday is 7.
  assert calendar.weekday(Date(1970, 1, 1)) == 4
  assert calendar.weekday(Date(1969, 12, 28)) == 7
  assert calendar.weekday(Date(2000, 2, 29)) == 2
  assert calendar.weekday(Date(2026, 9, 24)) == 4
  assert calendar.weekday(Date(1600, 3, 1)) == 3
}

pub fn days_and_months_add_up_test() {
  assert calendar.add_days(Date(2026, 12, 31), 1) == Date(2027, 1, 1)
  assert calendar.add_days(Date(2024, 3, 1), -1) == Date(2024, 2, 29)
  assert calendar.add_days(Date(1970, 1, 1), -1) == Date(1969, 12, 31)
  assert calendar.add_months(Date(2026, 1, 31), 1) == Date(2026, 2, 28)
  assert calendar.add_months(Date(2026, 1, 15), -1) == Date(2025, 12, 15)
  assert calendar.add_months(Date(2026, 11, 1), 14) == Date(2028, 1, 1)
  assert calendar.days_in_month(1900, 2) == 28
  assert calendar.days_in_month(2000, 2) == 29
}

pub fn iso_dates_round_trip_test() {
  assert calendar.to_iso(Date(987, 3, 9)) == "0987-03-09"
  assert calendar.from_iso("2026-09-24") == Ok(Date(2026, 9, 24))
  assert calendar.from_iso("2026-02-30") == Error(Nil)
  assert calendar.from_iso("2026-13-01") == Error(Nil)
  assert calendar.from_iso("24/09/2026") == Error(Nil)
}

pub fn a_month_is_whole_weeks_from_the_right_day_test() {
  let html =
    calendar.new("due", year: 2026, month: 9)
    |> calendar.today(Date(2026, 9, 24))
    |> calendar.selected(Some(Date(2026, 9, 10)))
    |> calendar.disabled(fn(date) { date.day == 1 })
    |> calendar.name("due")
    |> calendar.view
    |> render
  // September 2026 starts on a Tuesday: Monday 31 August leads the grid,
  // and five weeks end on Sunday 4 October.
  assert list.length(string.split(html, "data-date=")) == 36
  let assert Ok(#(_, first)) = string.split_once(html, "data-date=\"")
  assert string.starts_with(first, "2026-08-31")
  assert string.contains(html, "data-date=\"2026-10-04\"")
  assert string.contains(html, "aria-label=\"Thursday, 24 September 2026\"")
  assert string.contains(html, "aria-current=\"date\"")
  // The selected day is pressed and the only one in the tab order.
  assert list.length(string.split(html, "aria-pressed=\"true\"")) == 2
  assert list.length(string.split(html, "tabindex=\"0\"")) == 2
  assert string.contains(html, "name=\"due\"")
  assert string.contains(html, "value=\"2026-09-10\"")

  let sunday =
    calendar.new("due", year: 2026, month: 9)
    |> calendar.sunday_first
    |> calendar.view
    |> render
  let assert Ok(#(_, first)) = string.split_once(sunday, "data-date=\"")
  assert string.starts_with(first, "2026-08-30")
}

pub fn a_picker_shows_the_choice_or_placeholder_test() {
  let html =
    calendar.new("due", year: 2026, month: 9)
    |> calendar.selected(Some(Date(2026, 9, 10)))
    |> calendar.name("due")
    |> calendar.picker(placeholder: "Pick a day")
    |> render
  assert string.contains(html, "data-howdy-select")
  assert string.contains(html, ">10 September 2026</span>")
  assert string.contains(html, "popovertarget=\"due-popover\"")

  let html =
    calendar.new("due", year: 2026, month: 9)
    |> calendar.picker(placeholder: "Pick a day")
    |> render
  assert string.contains(html, ">Pick a day</span>")
  assert string.contains(html, "data-placeholder")
}

// -- Pagination --------------------------------------------------------------

fn page_labels(current: Int, total: Int) -> List(String) {
  pagination.pagination(
    words: words.english(),
    current:,
    total:,
    href: fn(page) { "?page=" <> int.to_string(page) },
  )
  |> render
  |> string.split("<li>")
  |> list.drop(2)
  |> list.map(fn(item) {
    let is = string.contains(item, _)
    case is("…"), is("aria-disabled"), is("rel=\"next\""), is("rel=\"prev\"") {
      True, _, _, _ -> "…"
      _, True, _, _ -> "-"
      _, _, True, _ -> "Next"
      _, _, _, True -> "Previous"
      _, _, _, _ ->
        case string.split_once(item, "</a>") {
          Ok(#(before, _)) ->
            string.split(before, ">") |> list.last |> result.unwrap("?")
          Error(Nil) -> "?"
        }
    }
  })
}

pub fn pagination_shows_the_ends_and_the_neighbourhood_test() {
  // The first item, Previous, is dropped; "-" is a disabled Next.
  assert page_labels(1, 1) == ["1", "-"]
  assert page_labels(6, 12) == ["1", "…", "5", "6", "7", "…", "12", "Next"]
  // A gap of one page shows that page rather than an ellipsis.
  assert page_labels(4, 12) == ["1", "2", "3", "4", "5", "…", "12", "Next"]
  assert page_labels(12, 12) == ["1", "…", "11", "12", "-"]
}

pub fn pagination_marks_the_current_page_and_ends_test() {
  let html =
    pagination.pagination(words.english(), current: 1, total: 3, href: fn(page) {
      "/p/" <> int.to_string(page)
    })
    |> render
  assert string.contains(html, "aria-label=\"Pagination\"")
  assert string.contains(html, "aria-current=\"page\" class=")
  assert string.contains(html, "aria-disabled=\"true\"")
  assert string.contains(html, "href=\"/p/2\" rel=\"next\"")
}

// -- Data table --------------------------------------------------------------

type Row {
  Row(name: String, seats: Int)
}

fn columns() {
  [
    data_table.column("name", "Name", fn(row: Row) { text(row.name) })
      |> data_table.sortable(fn(a: Row, b: Row) {
        string.compare(a.name, b.name)
      }),
    data_table.column("seats", "Seats", fn(row: Row) {
      text(int.to_string(row.seats))
    })
      |> data_table.sortable(fn(a: Row, b: Row) {
        int.compare(a.seats, b.seats)
      })
      |> data_table.numeric,
    data_table.column("note", "Note", fn(_) { text("") }),
  ]
}

const rows = [Row("Globex", 48), Row("Acme", 12), Row("Initech", 7)]

pub fn tables_sort_rows_by_the_column_asked_for_test() {
  let names = fn(sort) {
    data_table.new(columns(), rows)
    |> data_table.sort(sort, by: Links(fn(_) { "" }))
    |> data_table.sorted_rows
    |> list.map(fn(row) { row.name })
  }
  assert names(None) == ["Globex", "Acme", "Initech"]
  assert names(Some(Sort("name", Ascending))) == ["Acme", "Globex", "Initech"]
  assert names(Some(Sort("seats", Descending))) == ["Globex", "Acme", "Initech"]
  // An unknown or unsortable column leaves the order alone.
  assert names(Some(Sort("note", Ascending))) == ["Globex", "Acme", "Initech"]
}

pub fn sortable_headers_ask_for_the_next_sort_test() {
  let html =
    data_table.new(columns(), rows)
    |> data_table.sort(
      Some(Sort("seats", Ascending)),
      by: Links(fn(sort) {
        "?sort="
        <> sort.column
        <> case sort.direction {
          Ascending -> "&dir=asc"
          Descending -> "&dir=desc"
        }
      }),
    )
    |> data_table.view
    |> render
  assert string.contains(html, "aria-sort=\"ascending\"")
  assert string.contains(html, "href=\"?sort=seats&amp;dir=desc\"")
  assert string.contains(html, "aria-sort=\"none\"")
  assert string.contains(html, "href=\"?sort=name&amp;dir=asc\"")
  // Unsortable columns have a plain header.
  assert string.contains(html, "scope=\"col\">Note</th>")
}

pub fn selectable_tables_check_rows_test() {
  let html =
    data_table.new(columns(), rows)
    |> data_table.sort(None, by: Events(fn(_) { Nil }))
    |> data_table.selectable(
      key: fn(row: Row) { row.name },
      selected: ["Acme"],
      toggle: fn(_) { [] },
      toggle_all: [],
    )
    |> data_table.view
    |> render
  assert string.contains(html, "aria-label=\"Select all rows\"")
  assert list.length(string.split(html, "aria-selected=\"true\"")) == 2
  assert list.length(string.split(html, "aria-label=\"Select row\"")) == 4
}

pub fn empty_tables_say_so_test() {
  let html =
    data_table.new(columns(), [])
    |> data_table.empty([text("Nothing here.")])
    |> data_table.view
    |> render
  assert string.contains(html, "colspan=\"3\"")
  assert string.contains(html, "Nothing here.")
}

// -- Charts ------------------------------------------------------------------

pub fn numbers_are_written_plainly_test() {
  assert chart.format_number(0.0) == "0"
  assert chart.format_number(1_234_567.0) == "1,234,567"
  assert chart.format_number(-4200.5) == "-4,200.5"
  assert chart.format_number(3.14159) == "3.14"
  assert chart.format_number(999.999) == "1,000"
}

pub fn charts_carry_readouts_and_a_table_test() {
  let html =
    chart.line(title: "Visitors", labels: ["Mon", "Tue"], series: [
      chart.Series("Desktop", [1200.0, 1500.0]),
      chart.Series("Mobile", [800.0, 950.0]),
    ])
    |> chart.view
    |> render
  assert string.contains(html, "role=\"group\"")
  assert string.contains(html, "aria-label=\"Visitors\"")
  // One readout per label, reachable by keyboard and screen reader.
  assert string.contains(html, "aria-label=\"Mon: Desktop 1,200, Mobile 800\"")
  assert list.length(string.split(html, "tabindex=\"0\"")) == 3
  // A legend, because there are two series, and the table behind it.
  assert string.contains(html, ">Desktop</li>")
  assert string.contains(html, "<summary")
  assert string.contains(html, "<caption")
  // Series take the theme's chart colours in order.
  assert string.contains(html, "var(--howdy-chart-1)")
  assert string.contains(html, "var(--howdy-chart-2)")
}

pub fn a_single_series_needs_no_legend_test() {
  let html =
    chart.bar(title: "Orders", labels: ["Mon"], series: [
      chart.Series("Orders", [3.0]),
    ])
    |> chart.view
    |> render
  assert !string.contains(html, "</li>")
}

pub fn colours_follow_the_series_not_its_position_test() {
  let html =
    chart.bar(title: "Orders", labels: ["Mon"], series: [
      chart.Series("Online", [3.0]),
      chart.Series("Phone", [2.0]),
    ])
    |> chart.colours([1, 3])
    |> chart.view
    |> render
  assert string.contains(html, "var(--howdy-chart-3)")
  assert !string.contains(html, "var(--howdy-chart-2)")
}

// -- Toasts, command menus and live values -----------------------------------

pub fn toasts_live_in_a_polite_region_test() {
  let #(html, css) =
    stylesheet.scoped(fn() {
      toast.region(words.english(), [], [
        toast.toast(toast.Info, [toast.duration(8000), toast.persistent()], [
          toast.title([text("Saved")]),
          toast.close([attribute.aria_label("Dismiss")]),
        ]),
      ])
      |> render
    })
  assert string.contains(html, "aria-live=\"polite\"")
  // The countdown animation is registered once for the document.
  assert string.contains(css, "@keyframes howdy-toast-out")
  assert string.contains(html, "--howdy-toast-duration:8000ms")
  assert string.contains(html, "data-persistent")
  assert string.contains(html, "data-howdy-toast-close")
}

pub fn flash_messages_become_toasts_test() {
  let messages = [
    flash.Message(flash.Success, "Saved"),
    flash.Message(flash.Danger, "<b>Failed</b>"),
  ]
  let html =
    toast.region(words.english(), [], toast.flashed(words.english(), messages))
    |> render
  assert string.contains(html, "Saved")
  // Text, never markup.
  assert string.contains(html, "&lt;b&gt;Failed&lt;/b&gt;")
  assert string.contains(html, "data-toast-icon")
  assert string.contains(html, "aria-label=\"Dismiss\"")

  let queue = toast.push_flashed(toast.queue(), messages, 0)
  let assert [first, second] = toast.items(queue)
  assert first.variant == toast.Success
  assert first.title == "Saved"
  assert second.variant == toast.Danger
}

pub fn command_menus_are_comboboxes_over_listboxes_test() {
  let html =
    ui.command("go", placeholder: "Search", attributes: [], children: [
      ui.command_group("Pages", [ui.command_link("/", [], [text("Home")])]),
      ui.command_empty([text("None")]),
    ])
    |> render
  assert string.contains(html, "role=\"combobox\"")
  assert string.contains(html, "aria-controls=\"go-list\"")
  assert string.contains(html, "id=\"go-list\" role=\"listbox\"")
  assert string.contains(html, "href=\"/\"")
  assert string.contains(html, "data-howdy-command-empty")

  let html =
    ui.command_dialog(
      words.english(),
      "search",
      shortcut: "K",
      attributes: [],
      command: html.div([], []),
    )
    |> render
  assert string.contains(html, "data-howdy-shortcut=\"k\"")
}

pub fn sidebars_remember_their_state_test() {
  let html =
    ui.sidebar_layout(
      collapsed: True,
      attributes: [],
      sidebar: ui.sidebar("nav", [], [
        ui.sidebar_group("App", [
          ui.sidebar_link("/", active: True, attributes: [], children: [
            text("Home"),
          ]),
        ]),
      ]),
      main: [],
    )
    |> render
  assert string.contains(html, "data-state=\"collapsed\"")
  assert string.contains(html, "popover=\"auto\"")
  assert string.contains(html, "aria-current=\"page\"")
}

pub fn live_values_ask_for_the_target_name_and_value_test() {
  // The attribute renders as nothing on the server; what matters is that it
  // builds. Its behaviour is exercised in the gallery example.
  let html = render(html.div([live.on_value("plan", fn(value) { value })], []))
  assert html == "<div></div>"
}
