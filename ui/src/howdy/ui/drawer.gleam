//// Drawers: a panel that slides up from the bottom of the screen, and
//// can be dragged by its handle to resize or dismiss it. Suited to phones,
//// and to actions or details that belong beside the page.
////
//// ```gleam
//// ui.button(Outline, drawer.trigger("filters"), [text("Filters")]),
//// drawer.drawer(words.english(), "filters", [drawer.snap_points([40, 90])], [
////   drawer.header([
////     drawer.title("filters", [text("Filters")]),
////     drawer.description("filters", [text("Narrow the list of orders.")]),
////   ]),
////   filter_form,
//// ])
//// ```
////
//// A drawer is a modal `<dialog>`: focus stays inside it, Escape and a
//// click outside close it, and focus returns to its trigger. Dragging the
//// handle down far enough closes it too. With `snap_points`, it opens at
//// the first height, given as percentages of the screen, and settles at
//// whichever height is nearest when the handle is let go. The handle can
//// also be focused and moved with the up and down arrow keys.

import gleam/int
import gleam/list
import gleam/string
import howdy/ui/dialog
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import howdy/ui/words.{type Words}
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{percent, rem}

/// Attributes for a button that opens the drawer with this id.
pub fn trigger(id: String) -> List(Attribute(msg)) {
  dialog.trigger(id)
}

/// Attributes for a button that closes the drawer with this id.
pub fn close(id: String) -> List(Attribute(msg)) {
  dialog.close(id)
}

/// Heights the drawer settles at, as percentages of the screen's height,
/// such as `[40, 90]`. It opens at the first.
pub fn snap_points(heights: List(Int)) -> Attribute(msg) {
  attribute.data(
    "snaps",
    heights |> list.map(int.to_string) |> string.join(","),
  )
}

/// The drawer. `words` name its handle for screen readers.
pub fn drawer(
  words: Words,
  id: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  style.rule(motion_rule, motion_css)
  html.dialog(
    [
      class(drawer_class()),
      attribute.id(id),
      attribute.attribute("closedby", "any"),
      attribute.aria_labelledby(id <> "-title"),
      attribute.aria_describedby(id <> "-description"),
      attribute.data("howdy-drawer", ""),
      ..attributes
    ],
    [
      html.div(
        [
          class(handle_class()),
          attribute.data("howdy-drawer-handle", ""),
          attribute.role("separator"),
          attribute.aria_orientation("horizontal"),
          attribute.aria_label(words.resize),
          attribute.tabindex(0),
        ],
        [],
      ),
      html.div([class(body_class())], children),
    ],
  )
}

/// The title and description at the top.
pub fn header(children: List(Element(msg))) -> Element(msg) {
  dialog.header(children)
}

/// The drawer's name, read out when it opens. Pass the drawer's id.
pub fn title(id: String, children: List(Element(msg))) -> Element(msg) {
  dialog.title(id, children)
}

pub fn description(id: String, children: List(Element(msg))) -> Element(msg) {
  dialog.description(id, children)
}

/// A row of buttons at the bottom.
pub fn footer(children: List(Element(msg))) -> Element(msg) {
  dialog.footer(children)
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [drawer_class(), handle_class(), body_class()]
}

/// The CSS this module registers with `style.rule`, for `howdy/ui/export`.
pub fn rules() -> List(#(String, String)) {
  [#(motion_rule, motion_css)]
}

pub fn drawer_class() -> Class {
  css.class([
    css.inset("auto 0 0 0"),
    css.margin_("0 auto"),
    css.width(percent(100)),
    css.property("max-width", "min(40rem, 100%)"),
    css.property("max-height", "92dvh"),
    css.property("height", "var(--howdy-drawer-height, auto)"),
    css.display("flex"),
    css.flex_direction("column"),
    css.padding(rem(0.0)),
    css.background(tokens.surface),
    css.color(tokens.text),
    style.bordered(),
    css.property("border-bottom", "0"),
    style.radius(tokens.radius_large <> " " <> tokens.radius_large <> " 0 0"),
    css.box_shadow("0 -12px 40px -12px rgb(0 0 0 / 0.35)"),
    css.overflow("hidden"),
    css.property("overscroll-behavior", "contain"),
    css.selector(":not([open])", [css.display("none")]),
    css.backdrop([css.background("rgb(0 0 0 / 0.5)")]),
    css.focus_visible([css.outline("none")]),
  ])
}

pub fn handle_class() -> Class {
  css.class([
    css.flex_shrink(0.0),
    css.property("align-self", "center"),
    css.property("width", "3rem"),
    css.property("height", "0.375rem"),
    css.margin_(tokens.space_3 <> " 0 " <> tokens.space_1),
    style.pill(),
    css.background(tokens.border),
    css.cursor("grab"),
    css.property("touch-action", "none"),
    // A larger grip than the bar it draws.
    css.position("relative"),
    css.after([
      css.content("\"\""),
      css.position("absolute"),
      css.inset("-0.75rem -2rem"),
    ]),
    style.focus_ring_offset("4px"),
  ])
}

pub fn body_class() -> Class {
  css.class([
    css.property("flex", "1"),
    css.property("min-height", "0"),
    css.overflow_y("auto"),
    css.padding_(
      tokens.space_2 <> " " <> tokens.space_6 <> " " <> tokens.space_6,
    ),
  ])
}

// Sliding in and out. Sketch classes cannot carry `@starting-style`, so the
// rules are registered when a drawer is drawn, emitted once per document.
const motion_rule = "howdy-drawer"

const motion_css = "[data-howdy-drawer]{transform:translateY(var(--howdy-drawer-drag,0px));transition:transform .25s ease,display .25s allow-discrete,overlay .25s allow-discrete}[data-howdy-drawer][data-dragging]{transition:none}@starting-style{[data-howdy-drawer][open]{transform:translateY(100%)}}[data-howdy-drawer]:not([open]){transform:translateY(100%)}@media (prefers-reduced-motion:reduce){[data-howdy-drawer]{transition:none}}"
