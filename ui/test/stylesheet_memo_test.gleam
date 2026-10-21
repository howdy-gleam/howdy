//// Class names are memoised per style definition. The memo must never
//// change a name, so every name is checked against a fresh computation.

import gleam/int
import gleam/list
import gleam/string
import howdy/ui
import howdy/ui/data_table
import howdy/ui/internal/stylesheet
import lustre/element.{text}
import sketch/css.{type Class}
import sketch/css/length

/// A class's name, computed from scratch every time.
fn uncached_name(class: Class) -> String {
  stylesheet.render(class).0
}

pub fn memoised_names_match_fresh_computation_test() {
  let classes = ui.classes()
  // Twice: the first pass fills the memo, the second reads it.
  use _ <- list.each([1, 2])
  use class <- list.each(classes)
  assert stylesheet.class_name(class) == uncached_name(class)
}

/// Islands render the same view on the server and in the browser, so a
/// class must get the same name on both. This value is what Erlang and
/// JavaScript both compute; Sketch's own naming differs between them.
pub fn names_are_the_same_on_every_target_test() {
  let class = css.class([css.padding(length.px(4)), css.color("red")])
  assert stylesheet.render(class).0 == "css-345FE14C"
}

type Row {
  Row(name: String, seats: Int)
}

/// A rendered table of `count` rows, used for timing renders.
pub fn table_html(count: Int) -> String {
  let rows =
    list.index_map(list.repeat(Nil, count), fn(_, i) {
      Row("Row " <> int.to_string(i + 1), i + 1)
    })
  data_table.new(
    [
      data_table.column("name", "Name", fn(row: Row) { text(row.name) }),
      data_table.column("seats", "Seats", fn(row: Row) {
        text(int.to_string(row.seats))
      })
        |> data_table.numeric,
    ],
    rows,
  )
  |> data_table.view
  |> element.to_string
}

pub fn repeated_renders_are_byte_identical_test() {
  let first = table_html(1000)
  let second = table_html(1000)
  assert first == second
  assert string.contains(first, "Row 1000")
}
