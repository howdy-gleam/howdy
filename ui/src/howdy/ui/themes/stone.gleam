//// The stone theme preset. Warm greys with a near-black primary, a little softer than zinc.
////
//// ```gleam
//// import howdy/ui/themes/stone
////
//// page.new("Orders")
//// |> page.themes(stone.themes())
//// ```
////
//// The themes are named `light` and `dark`, like the built-in ones, so
//// `ui.theme_toggle` and a `theme` cookie work unchanged. Copy this module
//// with `gleam run -m howdy/ui add stone` to adjust it. Every text colour
//// meets WCAG AA contrast against the surfaces it sits on, and the focus
//// ring 3:1 against the page.

import howdy/ui/theme.{type Theme, type Themes, Colors, Dark, Light, Theme}

pub fn light() -> Theme {
  Theme(
    ..theme.light(),
    name: "light",
    scheme: Light,
    colors: Colors(
      background: "#fafaf9",
      surface: "#ffffff",
      muted: "#f5f5f4",
      border: "#e7e5e4",
      text: "#1c1917",
      text_muted: "#78716c",
      primary: "#292524",
      primary_hover: "#44403c",
      on_primary: "#fafaf9",
      danger: "#dc2626",
      on_danger: "#ffffff",
      focus: "#78716c",
      chart_1: "#2a78d6",
      chart_2: "#eb6834",
      chart_3: "#1baf7a",
      chart_4: "#eda100",
      chart_5: "#e87ba4",
    ),
  )
}

pub fn dark() -> Theme {
  Theme(
    ..theme.dark(),
    name: "dark",
    scheme: Dark,
    colors: Colors(
      background: "#0c0a09",
      surface: "#1c1917",
      muted: "#292524",
      border: "#44403c",
      text: "#fafaf9",
      text_muted: "#a8a29e",
      primary: "#fafaf9",
      primary_hover: "#e7e5e4",
      on_primary: "#1c1917",
      danger: "#f87171",
      on_danger: "#0c0a09",
      focus: "#78716c",
      chart_1: "#3987e5",
      chart_2: "#d95926",
      chart_3: "#199e70",
      chart_4: "#c98500",
      chart_5: "#d55181",
    ),
  )
}

/// Light by default, dark when the system prefers it.
pub fn themes() -> Themes {
  theme.themes(default: light(), alternatives: [dark()])
}
