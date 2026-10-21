import gleam/list
import gleam/string
import howdy/ui/theme.{Colors}
import howdy/ui/theme/tokens

pub fn every_token_is_defined_by_every_theme_test() {
  let themes = [theme.light(), theme.dark()]
  use current <- list.each(themes)
  let defined = list.map(theme.variables(current), fn(pair) { pair.0 })
  use #(property, token) <- list.each(tokens.all())
  assert list.contains(defined, property)
  assert token == "var(" <> property <> ")"
}

pub fn default_theme_goes_on_root_test() {
  let css = theme.to_css(theme.default_themes())
  assert string.contains(
    css,
    ":root { color-scheme: light; --howdy-background: #f8fafc;",
  )
  assert string.contains(css, "[data-theme=\"light\"] { color-scheme: light;")
  assert string.contains(css, "[data-theme=\"dark\"] { color-scheme: dark;")
}

pub fn opposite_scheme_alternative_follows_system_preference_test() {
  let css = theme.to_css(theme.default_themes())
  assert string.contains(
    css,
    "@media (prefers-color-scheme: dark) { :root:not([data-theme]) { color-scheme: dark; --howdy-background: #0f172a;",
  )
}

pub fn no_media_query_without_an_opposite_scheme_test() {
  let css = theme.to_css(theme.themes(default: theme.light(), alternatives: []))
  assert !string.contains(css, "@media")
}

pub fn derived_theme_keeps_other_values_test() {
  let brand =
    theme.light()
    |> theme.named("brand")
    |> theme.colors(fn(c) { Colors(..c, primary: "#0f766e") })

  assert brand.name == "brand"
  assert brand.colors.primary == "#0f766e"
  assert brand.colors.background == theme.light().colors.background
  assert list.key_find(theme.variables(brand), "--howdy-primary")
    == Ok("#0f766e")
}
