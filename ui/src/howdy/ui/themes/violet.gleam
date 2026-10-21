//// The violet theme preset. Neutral greys with a violet primary.
////
//// ```gleam
//// import howdy/ui/themes/violet
////
//// page.new("Orders")
//// |> page.themes(violet.themes())
//// ```
////
//// The themes are named `light` and `dark`, like the built-in ones, so
//// `ui.theme_toggle` and a `theme` cookie work unchanged. Copy this module
//// with `gleam run -m howdy/ui add violet` to adjust it. Every text colour
//// meets WCAG AA contrast against the surfaces it sits on, and the focus
//// ring 3:1 against the page.

import howdy/ui/theme.{type Theme, type Themes, Colors, Dark, Light, Theme}

pub fn light() -> Theme {
  Theme(
    ..theme.light(),
    name: "light",
    scheme: Light,
    colors: Colors(
      background: "#ffffff",
      surface: "#ffffff",
      muted: "#f4f4f5",
      border: "#e4e4e7",
      text: "#09090b",
      text_muted: "#71717a",
      primary: "#7c3aed",
      primary_hover: "#6d28d9",
      on_primary: "#ffffff",
      danger: "#dc2626",
      on_danger: "#ffffff",
      focus: "#8b5cf6",
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
      background: "#09090b",
      surface: "#18181b",
      muted: "#27272a",
      border: "#3f3f46",
      text: "#fafafa",
      text_muted: "#a1a1aa",
      primary: "#a78bfa",
      primary_hover: "#c4b5fd",
      on_primary: "#1e1b4b",
      danger: "#f87171",
      on_danger: "#09090b",
      focus: "#7c3aed",
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
