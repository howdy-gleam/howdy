//// Axis scales for degenerate data: no spread, all zero, or values
//// whose range cannot be taken a logarithm of.

import gleam/string
import howdy/ui/chart
import lustre/element

fn render(series: List(chart.Series)) -> String {
  chart.bar(title: "Flat", labels: ["a", "b"], series:)
  |> chart.view
  |> element.to_string
}

pub fn equal_min_and_max_draw_a_unit_axis_test() {
  let html = render([chart.Series("s", [3.0, 3.0])])
  assert string.contains(html, "<svg")
}

pub fn all_zero_values_draw_an_axis_test() {
  let html = render([chart.Series("s", [0.0, 0.0])])
  assert string.contains(html, "<svg")
}

pub fn no_values_draw_an_axis_test() {
  let html = render([chart.Series("s", [])])
  assert string.contains(html, "<svg")
}

pub fn values_too_large_to_spread_by_one_draw_an_axis_test() {
  // `1.0e17 +. 1.0 == 1.0e17`, so a naive range here is zero.
  let html = render([chart.Series("s", [1.0e17, 1.0e17])])
  assert string.contains(html, "<svg")
}

pub fn a_tiny_spread_draws_an_axis_test() {
  let html = render([chart.Series("s", [1.0e-300, 2.0e-300])])
  assert string.contains(html, "<svg")
}
