//// Themes are plain records of colours, fonts and radii. Each one compiles to
//// a block of CSS custom properties, and every component in `howdy/ui` reads
//// those properties through `howdy/ui/theme/tokens` instead of naming a
//// colour directly. Change a theme and every element follows.
////
//// ```gleam
//// import howdy/ui/theme.{Colors}
////
//// pub fn brand() -> theme.Theme {
////   theme.light()
////   |> theme.colors(fn(c) { Colors(..c, primary: "#0f766e", on_primary: "#fff") })
//// }
////
//// theme.themes(default: brand(), alternatives: [theme.dark()])
//// ```
////
//// The default theme goes on `:root`. Every theme, including the default,
//// is also written under `[data-theme="name"]`, so setting that attribute
//// on the root element switches theme. When the attribute is absent, the
//// first alternative with the opposite colour scheme to the default is
//// applied through `prefers-color-scheme`.
////
//// Adding a field to `Colors`, `Font` or `Radius` is a compile error until
//// every theme supplies it. That is what keeps light and dark in step.

import gleam/list
import gleam/string

/// Whether a theme is light or dark. Sets the `color-scheme` property so
/// form controls and scrollbars match, and drives the system preference
/// media query.
pub type Scheme {
  Light
  Dark
}

/// A complete theme.
pub type Theme {
  Theme(
    /// The value of the `data-theme` attribute that selects this theme.
    name: String,
    scheme: Scheme,
    colors: Colors,
    font: Font,
    radius: Radius,
  )
}

/// Every colour a component may use. Values are any CSS colour.
pub type Colors {
  Colors(
    /// Page background.
    background: String,
    /// Cards, panels and inputs.
    surface: String,
    /// Subtle fills: secondary buttons and badges, hovered rows and ghost
    /// buttons, skeletons.
    muted: String,
    /// Lines around surfaces and inputs.
    border: String,
    /// Body text.
    text: String,
    /// Secondary text such as captions and placeholders.
    text_muted: String,
    /// Buttons and links.
    primary: String,
    /// `primary` when hovered.
    primary_hover: String,
    /// Text on top of `primary`.
    on_primary: String,
    /// Destructive actions and errors.
    danger: String,
    /// Text on top of `danger`.
    on_danger: String,
    /// Focus rings.
    focus: String,
    /// Chart series, in the order they are used. The built-in themes' five
    /// pass colour-vision-deficiency separation checks as an ordered set
    /// against their own surface; keep that order, and check any
    /// replacement, rather than shuffling them.
    chart_1: String,
    chart_2: String,
    chart_3: String,
    chart_4: String,
    chart_5: String,
  )
}

/// Font stacks.
pub type Font {
  Font(body: String, heading: String, mono: String)
}

/// Corner radii, as CSS lengths.
pub type Radius {
  Radius(small: String, medium: String, large: String)
}

/// The set of themes a page offers.
pub type Themes {
  Themes(default: Theme, alternatives: List(Theme))
}

/// Build a set of themes.
pub fn themes(
  default default: Theme,
  alternatives alternatives: List(Theme),
) -> Themes {
  Themes(default:, alternatives:)
}

/// `light()` by default with `dark()` as the alternative.
pub fn default_themes() -> Themes {
  Themes(default: light(), alternatives: [dark()])
}

// -- Built-in themes ---------------------------------------------------------

/// The built-in light theme, named `"light"`.
pub fn light() -> Theme {
  Theme(
    name: "light",
    scheme: Light,
    colors: Colors(
      background: "#f8fafc",
      surface: "#ffffff",
      muted: "#f1f5f9",
      border: "#e2e8f0",
      text: "#0f172a",
      text_muted: "#64748b",
      primary: "#2563eb",
      primary_hover: "#1d4ed8",
      on_primary: "#ffffff",
      danger: "#dc2626",
      on_danger: "#ffffff",
      focus: "#3b82f6",
      chart_1: "#2a78d6",
      chart_2: "#eb6834",
      chart_3: "#1baf7a",
      chart_4: "#eda100",
      chart_5: "#e87ba4",
    ),
    font: default_font(),
    radius: default_radius(),
  )
}

/// The built-in dark theme, named `"dark"`.
pub fn dark() -> Theme {
  Theme(
    name: "dark",
    scheme: Dark,
    colors: Colors(
      background: "#0f172a",
      surface: "#1e293b",
      muted: "#334155",
      border: "#334155",
      text: "#f1f5f9",
      text_muted: "#94a3b8",
      primary: "#60a5fa",
      primary_hover: "#93c5fd",
      on_primary: "#0f172a",
      danger: "#f87171",
      on_danger: "#0f172a",
      focus: "#3b82f6",
      chart_1: "#3987e5",
      chart_2: "#d95926",
      chart_3: "#199e70",
      chart_4: "#c98500",
      chart_5: "#d55181",
    ),
    font: default_font(),
    radius: default_radius(),
  )
}

fn default_font() -> Font {
  Font(
    body: "system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif",
    heading: "system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif",
    mono: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace",
  )
}

fn default_radius() -> Radius {
  Radius(small: "0.25rem", medium: "0.5rem", large: "1rem")
}

// -- Deriving themes ---------------------------------------------------------

/// A copy of the theme under a different name.
pub fn named(theme: Theme, name: String) -> Theme {
  Theme(..theme, name:)
}

/// Adjust the colours. Use record update syntax to change only some:
///
/// ```gleam
/// theme.colors(theme.light(), fn(c) { Colors(..c, primary: "#0f766e") })
/// ```
pub fn colors(theme: Theme, update: fn(Colors) -> Colors) -> Theme {
  Theme(..theme, colors: update(theme.colors))
}

/// Adjust the fonts.
pub fn font(theme: Theme, update: fn(Font) -> Font) -> Theme {
  Theme(..theme, font: update(theme.font))
}

/// Adjust the radii.
pub fn radius(theme: Theme, update: fn(Radius) -> Radius) -> Theme {
  Theme(..theme, radius: update(theme.radius))
}

// -- CSS ---------------------------------------------------------------------

/// The prefix of every custom property, as in `--howdy-primary`.
pub const prefix = "--howdy-"

/// The custom properties a theme defines, as `#(name, value)` pairs. This
/// is the single list `howdy/ui/theme/tokens` and the CSS output are both
/// built from.
pub fn variables(theme: Theme) -> List(#(String, String)) {
  let c = theme.colors
  let f = theme.font
  let r = theme.radius
  [
    #("background", c.background),
    #("surface", c.surface),
    #("muted", c.muted),
    #("border", c.border),
    #("text", c.text),
    #("text-muted", c.text_muted),
    #("primary", c.primary),
    #("primary-hover", c.primary_hover),
    #("on-primary", c.on_primary),
    #("danger", c.danger),
    #("on-danger", c.on_danger),
    #("focus", c.focus),
    #("chart-1", c.chart_1),
    #("chart-2", c.chart_2),
    #("chart-3", c.chart_3),
    #("chart-4", c.chart_4),
    #("chart-5", c.chart_5),
    #("font-body", f.body),
    #("font-heading", f.heading),
    #("font-mono", f.mono),
    #("radius-small", r.small),
    #("radius-medium", r.medium),
    #("radius-large", r.large),
  ]
  |> list.map(fn(pair) { #(prefix <> pair.0, pair.1) })
}

/// The CSS for a set of themes: the default on `:root`, every theme under
/// its `data-theme` selector, and a `prefers-color-scheme` fallback.
pub fn to_css(themes: Themes) -> String {
  let Themes(default:, alternatives:) = themes
  let all = [default, ..alternatives]

  let root = rule(":root", declarations(default))
  let named =
    list.map(all, fn(theme) {
      rule("[data-theme=\"" <> theme.name <> "\"]", declarations(theme))
    })
  let system = case
    list.find(alternatives, fn(theme) { theme.scheme != default.scheme })
  {
    Ok(theme) ->
      "@media (prefers-color-scheme: "
      <> scheme_name(theme.scheme)
      <> ") { "
      <> rule(":root:not([data-theme])", declarations(theme))
      <> " }"
    Error(Nil) -> ""
  }

  [root, ..named]
  |> list.append([system])
  |> list.filter(fn(css) { css != "" })
  |> string.join("\n")
}

fn declarations(theme: Theme) -> String {
  let scheme = "color-scheme: " <> scheme_name(theme.scheme) <> ";"
  theme
  |> variables
  |> list.map(fn(pair) { pair.0 <> ": " <> pair.1 <> ";" })
  |> list.prepend(scheme)
  |> string.join(" ")
}

fn rule(selector: String, body: String) -> String {
  selector <> " { " <> body <> " }"
}

fn scheme_name(scheme: Scheme) -> String {
  case scheme {
    Light -> "light"
    Dark -> "dark"
  }
}
