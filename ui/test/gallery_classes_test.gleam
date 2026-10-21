//// Every class a gallery example uses must be in `ui.classes()`, and every
//// rule it registers in `ui.rules()`, so the exported stylesheet covers
//// what the components draw.

import gleam/list
import gleam/set
import gleam/string
import howdy/ui
import howdy/ui/gallery/examples
import howdy/ui/internal/stylesheet
import howdy/ui/registry
import lustre/element

pub fn every_gallery_example_uses_only_exported_classes_test() {
  let exported =
    list.append(
      ui.classes() |> list.map(stylesheet.class_name),
      ui.rules() |> list.map(fn(rule) { rule.0 }),
    )
    |> set.from_list
  let gaps =
    registry.entries()
    |> list.flat_map(fn(entry) {
      use example <- list.flat_map(examples.for(entry.name))
      let #(_, used) =
        stylesheet.scoped_names(fn() { element.to_string(example.view()) })
      used
      |> list.unique
      |> list.filter(fn(name) { !set.contains(exported, name) })
      |> list.map(fn(name) {
        entry.name <> "/" <> example.function <> ": " <> name
      })
    })
  assert gaps == [] as string.join(gaps, "\n")
}
