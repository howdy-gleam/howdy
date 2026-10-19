//// CSS that Sketch classes cannot carry, such as `@keyframes`, is
//// registered as a named rule and emitted once per document, however many
//// elements need it.

import gleam/list
import gleam/string
import howdy/ui
import howdy/ui/drawer
import howdy/ui/effects
import howdy/ui/export
import howdy/ui/internal/stylesheet
import howdy/ui/loading
import howdy/ui/page
import howdy/ui/progress
import howdy/ui/theme
import howdy/ui/toast
import howdy/ui/words
import lustre/element.{type Element, text}
import lustre/element/html

fn render(element: Element(msg)) -> String {
  element.to_string(element)
}

fn count(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}

fn skeletons(n: Int) -> List(Element(msg)) {
  list.repeat(Nil, n) |> list.map(fn(_) { loading.skeleton([]) })
}

pub fn a_single_instance_registers_its_animation_once_test() {
  let #(html, css) = stylesheet.scoped(fn() { render(loading.skeleton([])) })
  // The element no longer carries a <style> of its own.
  assert !string.contains(html, "<style")
  assert string.contains(html, "data-howdy-skeleton")
  assert count(css, "@keyframes howdy-pulse") == 1
  assert string.contains(css, "[data-howdy-skeleton]{animation:howdy-pulse")
}

pub fn a_page_with_many_instances_carries_the_block_once_test() {
  let html =
    page.new("Loading")
    |> page.body(skeletons(50))
    |> page.to_string
  // Elements carry the marker; only the one CSS block selects on it.
  assert count(html, "data-howdy-skeleton>") == 50
  assert count(html, "@keyframes howdy-pulse") == 1
  assert count(html, "@keyframes howdy-spin") == 1
}

pub fn a_render_scope_sees_only_the_rules_its_view_used_test() {
  // A live view's stylesheet carries the block only when the view needs
  // it, whatever earlier renders registered.
  let _ = render(loading.spinner("Loading", []))
  let #(_, without) =
    stylesheet.scoped(fn() { render(html.div([], [text("Plain")])) })
  assert !string.contains(without, "@keyframes")
  let #(_, with) =
    stylesheet.scoped(fn() {
      render(html.div([], [progress.indeterminate(label: "Working")]))
    })
  assert count(with, "@keyframes howdy-sweep") == 1
  assert !string.contains(with, "@keyframes howdy-pulse")
}

pub fn every_built_in_rule_is_registered_by_its_component_test() {
  let #(_, css) =
    stylesheet.scoped(fn() {
      render(
        html.div([], [
          effects.shimmer([text("Thinking")]),
          loading.skeleton([]),
          progress.indeterminate(label: "Working"),
          toast.region(words.english(), [], []),
          drawer.drawer(words.english(), "sheet", [], []),
        ]),
      )
    })
  use #(name, body) <- list.each(ui.rules())
  assert name != ""
  assert string.contains(css, body)
}

pub fn the_rendered_css_for_one_instance_is_unchanged_test() {
  // The block is the same text that used to travel inline; only where it
  // lives has changed.
  let #(_, css) =
    stylesheet.scoped(fn() { render(toast.region(words.english(), [], [])) })
  let assert [#("howdy-toast", body)] = toast.rules()
  assert string.contains(css, body)
  assert count(css, "@keyframes howdy-toast-in") == 1
}

pub fn a_published_stylesheet_includes_the_rules_once_test() {
  let css = export.new(theme.default_themes()) |> export.to_css
  use #(_, body) <- list.each(ui.rules())
  assert count(css, export.minify(body)) == 1
  let own =
    export.new(theme.default_themes())
    |> export.rules([
      #("mine", "@keyframes mine{to{opacity:0}}"),
      #("mine", "@keyframes mine{to{opacity:1}}"),
    ])
    |> export.to_css
  // First occurrence of a name wins, as for classes.
  assert count(own, "@keyframes mine") == 1
  assert string.contains(own, "@keyframes mine{to{opacity:0}}")
}
