import gleam/erlang/process
import gleam/list
import gleam/string
import howdy/ui
import howdy/ui/internal/stylesheet
import howdy/ui/theme/tokens
import lustre/element
import lustre/element/html
import sketch/css

fn badge(index: Int) -> element.Element(msg) {
  html.span(
    [
      ui.class(
        css.class([
          css.background(tokens.primary),
          css.property("--badge-index", string.inspect(index)),
        ]),
      ),
    ],
    [],
  )
}

fn range(n: Int) -> List(Int) {
  list.index_map(list.repeat(Nil, n), fn(_, i) { i + 1 })
}

pub fn many_processes_register_classes_at_once_test() {
  // 50 processes each render 20 distinct classes, all at the same time.
  let parent = process.new_subject()
  list.each(range(50), fn(_) {
    process.spawn(fn() {
      let html =
        range(20)
        |> list.map(badge)
        |> element.fragment
        |> element.to_string
      process.send(parent, html)
    })
  })

  let results =
    list.map(range(50), fn(_) {
      let assert Ok(html) = process.receive(parent, 2000)
      html
    })

  // Every process saw the same class names, and every class is in the CSS.
  assert list.unique(results) |> list.length == 1
  let css = ui.styles() |> element.to_string
  use index <- list.each(range(20))
  assert string.contains(css, "--badge-index: " <> string.inspect(index) <> ";")
}

pub fn a_class_is_rendered_once_test() {
  // A render scope sees only the classes used inside it, so this holds
  // whatever other tests have registered in the shared registry.
  let #(_, css) =
    stylesheet.scoped(fn() {
      [badge(1), badge(1)] |> element.fragment |> element.to_string
    })
  let occurrences = string.split(css, "--badge-index: 1;") |> list.length
  assert occurrences == 2
}
