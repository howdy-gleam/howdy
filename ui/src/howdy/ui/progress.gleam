//// Progress bars: how much of some work is done, or that work is under
//// way when how much is unknown.
////
//// ```gleam
//// progress.progress(label: "Uploading report.pdf", value: 40, max: 100)
//// progress.indeterminate(label: "Preparing export")
//// ```

import gleam/int
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{percent}

/// A bar filled `value` out of `max`. `label` names it for screen readers.
pub fn progress(
  label label: String,
  value value: Int,
  max max: Int,
) -> Element(msg) {
  let max = int.max(max, 1)
  let value = int.clamp(value, 0, max)
  html.div(
    [
      class(track_class()),
      attribute.role("progressbar"),
      attribute.aria_label(label),
      attribute.attribute("aria-valuemin", "0"),
      attribute.attribute("aria-valuemax", int.to_string(max)),
      attribute.attribute("aria-valuenow", int.to_string(value)),
    ],
    [
      html.div(
        [
          class(bar_class()),
          attribute.style("width", int.to_string(value * 100 / max) <> "%"),
        ],
        [],
      ),
    ],
  )
}

/// A bar for work whose size is not known yet. It sweeps while the work
/// goes on, and holds still for people who ask for reduced motion.
pub fn indeterminate(label label: String) -> Element(msg) {
  style.rule(sweep_rule, sweep_css)
  html.div(
    [
      class(track_class()),
      attribute.role("progressbar"),
      attribute.aria_label(label),
      attribute.data("howdy-indeterminate-progress", ""),
    ],
    [html.div([class(sweep_class())], [])],
  )
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [track_class(), bar_class(), sweep_class()]
}

/// The CSS this module registers with `style.rule`, for `howdy/ui/export`.
pub fn rules() -> List(#(String, String)) {
  [#(sweep_rule, sweep_css)]
}

pub fn sweep_class() -> Class {
  css.class([
    css.width(percent(40)),
    css.height(percent(100)),
    style.pill(),
    css.background(tokens.primary),
  ])
}

// Sketch classes cannot carry `@keyframes`, so the animation is registered
// as a rule, emitted once per document.
const sweep_rule = "howdy-progress-sweep"

const sweep_css = "@keyframes howdy-sweep{from{transform:translateX(-100%)}to{transform:translateX(250%)}}[data-howdy-indeterminate-progress]>div{animation:howdy-sweep 1.4s ease-in-out infinite}@media (prefers-reduced-motion:reduce){[data-howdy-indeterminate-progress]>div{animation:none;transform:translateX(75%)}}"

pub fn track_class() -> Class {
  css.class([
    css.width(percent(100)),
    css.property("height", "0.5rem"),
    css.overflow("hidden"),
    style.pill(),
    css.background(tokens.muted),
  ])
}

pub fn bar_class() -> Class {
  css.class([
    css.height(percent(100)),
    style.pill(),
    css.background(tokens.primary),
    css.transition("width 200ms"),
  ])
}
