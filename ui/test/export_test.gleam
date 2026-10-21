import gleam/list
import gleam/string
import howdy/ui/export
import howdy/ui/internal/stylesheet
import howdy/ui/theme
import howdy/ui/theme/tokens
import simplifile
import sketch/css

fn my_styles() -> List(css.Class) {
  [
    css.class([
      css.background(tokens.primary),
      css.property("--exported-badge", "yes"),
      css.hover([css.property("filter", "brightness(0.9)")]),
    ]),
  ]
}

pub fn export_has_themes_base_builtins_and_own_classes_test() {
  let css =
    export.new(theme.default_themes())
    |> export.classes(my_styles())
    |> export.to_css

  assert string.contains(
    css,
    ":root{color-scheme:light;--howdy-background:#f8fafc;",
  )
  assert string.contains(css, "[data-theme=\"dark\"]{color-scheme:dark;")
  assert string.contains(
    css,
    "body{margin:0;background:var(--howdy-background);",
  )
  // A built-in class and one of our own, with a nested selector.
  assert string.contains(css, "::placeholder{color:var(--howdy-text-muted)}")
  assert string.contains(css, "--exported-badge:yes}")
  assert string.contains(css, ":hover{filter:brightness(0.9)}")
}

pub fn export_is_minified_test() {
  let css = export.new(theme.default_themes()) |> export.to_css
  assert !string.contains(css, "\n")
  assert !string.contains(css, "; ")
  assert !string.contains(css, " {")
  assert !string.contains(css, ";}")
  // Whitespace that matters is kept: inside quotes and between values.
  assert string.contains(css, "'Segoe UI'")
  assert string.contains(css, "border:1px solid var(--howdy-border)")
  assert string.contains(css, "*,*::before,*::after{box-sizing:border-box}")
}

pub fn export_is_deterministic_test() {
  let first = export.new(theme.default_themes()) |> export.to_css
  let second = export.new(theme.default_themes()) |> export.to_css
  assert first == second
}

pub fn export_writes_the_file_test() {
  let path = "build/export_test/assets/ui.css"
  let _ = simplifile.delete("build/export_test")

  let assert Ok(Nil) =
    export.new(theme.default_themes())
    |> export.write(to: path)

  let assert Ok(written) = simplifile.read(path)
  assert written == export.new(theme.default_themes()) |> export.to_css
  let _ = simplifile.delete("build/export_test")
}

pub fn minify_leaves_quoted_text_alone_test() {
  assert export.minify("a { font: 'A  B' , \"C D\" ; }")
    == "a{font:'A  B',\"C D\"}"
  assert export.minify("a > b { x: 1 }\n\nc { y : 2 ; z: 3; }")
    == "a>b{x:1}c{y :2;z:3}"
}

pub fn minify_preserves_descendant_pseudo_selectors_test() {
  assert export.minify("div :hover { color: red; }") == "div :hover{color:red}"
  assert export.minify(
      ".card ::before, .card :is(:hover, :focus) { color: red; }",
    )
    == ".card ::before,.card :is(:hover,:focus){color:red}"
  assert export.minify("a { width: calc(100% - 2px); }")
    == "a{width:calc(100% - 2px)}"
}

pub fn minify_preserves_complex_lexical_content_test() {
  // Escapes, comment boundaries and unquoted URLs need CSS tokenization.
  let cases = [
    "a { content: \"a\\\"  ;  b\"; color: red; }",
    ".\\31  :hover { color: red; }",
    "a/**/b { color: red; }",
    "a { background: url(data:image/svg+xml;a: b); }",
  ]
  use source <- list.each(cases)
  assert export.minify(source) == source
}

pub fn export_order_is_independent_of_runtime_registration_test() {
  let a = css.class([css.property("--order-a", "first")])
  let b = css.class([css.property("--order-b", "second")])
  // Populate the runtime registry in the opposite order before export.
  let _ = stylesheet.class_name(b)
  let _ = stylesheet.class_name(a)
  let exported =
    export.new(theme.default_themes())
    |> export.classes([a, b, a])
    |> export.to_css
  let assert Ok(#(_, after_a)) = string.split_once(exported, "--order-a:first")
  assert string.contains(after_a, "--order-b:second")
  assert !string.contains(after_a, "--order-a:first")
  // Reversing the configured order deliberately reverses the cascade.
  let reversed =
    export.new(theme.default_themes())
    |> export.classes([b, a])
    |> export.to_css
  let assert Ok(#(_, after_b)) = string.split_once(reversed, "--order-b:second")
  assert string.contains(after_b, "--order-a:first")
}
