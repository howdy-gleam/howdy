//// Tabs: panels of content, one shown at a time, picked from a row of tabs.
////
//// ```gleam
//// tabs.tabs("account", selected: "profile", attributes: [], tabs: [
////   tabs.tab("profile", [], label: [text("Profile")], panel: [profile_form]),
////   tabs.tab("password", [], label: [text("Password")], panel: [password_form]),
//// ])
//// ```
////
//// Clicking a tab shows its panel; the arrow keys, Home and End move
//// between tabs. The browser switches panels itself, so a live view need
//// not handle anything. If it does keep the selected tab in its model,
//// update the model from a click on every tab, through the tab's
//// attributes, so the server's idea of which panel is shown never falls
//// behind the browser's.

import gleam/list
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

pub type Orientation {
  /// Tabs in a row above the panels. Left and right move between them.
  Horizontal
  /// Tabs in a column beside the panels. Up and down move between them.
  Vertical
}

/// How the tabs are drawn.
pub type Look {
  /// Tabs on a muted track, the selected one raised.
  Segmented
  /// Plain tabs over a line, the selected one underlined.
  Line
}

/// One tab and its panel.
pub opaque type Tab(msg) {
  Tab(
    value: String,
    attributes: List(Attribute(msg)),
    label: List(Element(msg)),
    panel: List(Element(msg)),
  )
}

/// A tab. `attributes` go on the tab's button, for example a click handler.
pub fn tab(
  value: String,
  attributes: List(Attribute(msg)),
  label label: List(Element(msg)),
  panel panel: List(Element(msg)),
) -> Tab(msg) {
  Tab(value:, attributes:, label:, panel:)
}

/// The tabs and their panels, showing the panel of the tab whose value is
/// `selected`. `id` must be unique in the document; the tabs' and panels'
/// ids are built from it.
pub fn tabs(
  id: String,
  selected selected: String,
  attributes attributes: List(Attribute(msg)),
  tabs tabs: List(Tab(msg)),
) -> Element(msg) {
  styled(
    id,
    selected:,
    orientation: Horizontal,
    look: Segmented,
    attributes:,
    tabs:,
  )
}

/// Tabs laid out and drawn another way.
pub fn styled(
  id: String,
  selected selected: String,
  orientation orientation: Orientation,
  look look: Look,
  attributes attributes: List(Attribute(msg)),
  tabs tabs: List(Tab(msg)),
) -> Element(msg) {
  let triggers =
    list.map(tabs, fn(tab) {
      let is_selected = tab.value == selected
      html.button(
        [
          class(tab_class(look, orientation)),
          attribute.type_("button"),
          attribute.role("tab"),
          attribute.id(tab_id(id, tab.value)),
          attribute.aria_controls(panel_id(id, tab.value)),
          attribute.aria_selected(is_selected),
          attribute.tabindex(case is_selected {
            True -> 0
            False -> -1
          }),
          ..tab.attributes
        ],
        tab.label,
      )
    })
  let panels =
    list.map(tabs, fn(tab) {
      html.div(
        [
          class(panel_class()),
          attribute.role("tabpanel"),
          attribute.id(panel_id(id, tab.value)),
          attribute.aria_labelledby(tab_id(id, tab.value)),
          attribute.tabindex(0),
          attribute.hidden(tab.value != selected),
        ],
        tab.panel,
      )
    })
  let orientation_name = case orientation {
    Horizontal -> "horizontal"
    Vertical -> "vertical"
  }
  html.div(
    [
      class(root_class(orientation)),
      attribute.id(id),
      attribute.data("howdy-tabs", ""),
      ..attributes
    ],
    [
      html.div(
        [
          class(list_class(look, orientation)),
          attribute.role("tablist"),
          attribute.aria_orientation(orientation_name),
        ],
        triggers,
      ),
      html.div([class(panels_class())], panels),
    ],
  )
}

fn tab_id(id: String, value: String) -> String {
  id <> "-tab-" <> value
}

fn panel_id(id: String, value: String) -> String {
  id <> "-panel-" <> value
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    root_class(Horizontal),
    root_class(Vertical),
    list_class(Segmented, Horizontal),
    list_class(Segmented, Vertical),
    list_class(Line, Horizontal),
    list_class(Line, Vertical),
    tab_class(Segmented, Horizontal),
    tab_class(Segmented, Vertical),
    tab_class(Line, Horizontal),
    tab_class(Line, Vertical),
    panels_class(),
    panel_class(),
  ]
}

pub fn root_class(orientation: Orientation) -> Class {
  case orientation {
    Horizontal -> css.class([css.display("block")])
    Vertical ->
      css.class([
        css.display("flex"),
        css.align_items("flex-start"),
        css.gap(rem(1.5)),
        css.selector(" > div > [role=\"tabpanel\"]", [css.margin(rem(0.0))]),
      ])
  }
}

pub fn list_class(look: Look, orientation: Orientation) -> Class {
  let direction = case orientation {
    Horizontal -> [
      css.display("inline-flex"),
      css.flex_direction("row"),
      css.align_items("center"),
      css.property("max-width", "100%"),
      css.overflow_x("auto"),
    ]
    Vertical -> [
      css.display("flex"),
      css.flex_direction("column"),
      css.align_items("stretch"),
      css.flex_shrink(0.0),
    ]
  }
  let drawn = case look, orientation {
    Segmented, _ -> [
      css.gap(rem(0.25)),
      css.padding(rem(0.25)),
      css.background(tokens.muted),
      style.radius(tokens.radius_medium),
    ]
    Line, Horizontal -> [
      css.gap(rem(1.0)),
      style.bordered_side("bottom"),
    ]
    Line, Vertical -> [
      css.gap(rem(0.25)),
      style.bordered_side("inline-start"),
    ]
  }
  css.class(list.append(direction, drawn))
}

pub fn tab_class(look: Look, orientation: Orientation) -> Class {
  let drawn = case look, orientation {
    Segmented, _ -> [
      css.padding_("0.375rem " <> tokens.space_3),
      style.radius(tokens.radius_small),
      css.selector("[aria-selected=\"true\"]", [
        css.background(tokens.surface),
        css.color(tokens.text),
        css.box_shadow("0 1px 3px rgb(0 0 0 / 0.12)"),
      ]),
    ]
    // The underline sits on the list's own line.
    Line, Horizontal -> [
      css.padding_(tokens.space_2 <> " " <> tokens.space_1),
      style.radius("0"),
      css.property("margin-block-end", "-1px"),
      css.property("border-bottom", "2px solid transparent"),
      css.selector("[aria-selected=\"true\"]", [
        css.color(tokens.text),
        css.property("border-color", tokens.primary),
      ]),
    ]
    Line, Vertical -> [
      css.padding_(tokens.space_2 <> " " <> tokens.space_3),
      style.radius("0"),
      css.property("margin-inline-start", "-1px"),
      css.property("border-inline-start", "2px solid transparent"),
      css.selector("[aria-selected=\"true\"]", [
        css.color(tokens.text),
        css.property("border-color", tokens.primary),
      ]),
    ]
  }
  css.class(list.append(
    [
      css.border("0"),
      css.background("transparent"),
      css.color(tokens.text_muted),
      css.font_family(tokens.font_body),
      css.font_size(rem(0.875)),
      css.font_weight("500"),
      css.line_height("1.25"),
      css.white_space("nowrap"),
      css.text_align("start"),
      css.cursor("pointer"),
      css.transition("background 120ms, color 120ms"),
      css.hover([css.color(tokens.text)]),
      style.focus_ring(),
      style.disabled_look_with(cursor: "default"),
    ],
    drawn,
  ))
}

pub fn panels_class() -> Class {
  css.class([css.property("flex", "1"), css.property("min-width", "0")])
}

pub fn panel_class() -> Class {
  css.class([
    css.margin_(tokens.space_4 <> " 0 0"),
    style.radius(tokens.radius_small),
    style.focus_ring(),
  ])
}
