//// Where classes are registered and their CSS collected.
////
//// Sketch class names are content hashes, so a name can be computed in the
//// calling process with a throwaway stylesheet. The name and CSS for each
//// distinct class are computed once and kept in ETS tables owned by a
//// supervised process in the howdy_ui application. After startup, cache
//// access is direct, so rendering does not queue on the owner process.
////
//// Inside an island the same functions run in the browser, where the
//// registry is a Map and new CSS is added to the page as it appears.

import gleam/int
import gleam/list
import gleam/set
import gleam/string
import howdy/ui/theme.{type Themes}
import howdy/ui/theme/tokens
import murmur3a
import sketch
import sketch/css.{type Class}

@external(erlang, "howdy_ui_ffi", "known")
@external(javascript, "./stylesheet.ffi.mjs", "known")
fn known(name: String) -> Bool

@external(erlang, "howdy_ui_ffi", "register")
@external(javascript, "./stylesheet.ffi.mjs", "register")
fn register(name: String, css: String) -> Nil

@external(erlang, "howdy_ui_ffi", "name_of")
@external(javascript, "./stylesheet.ffi.mjs", "name_of")
fn name_of(class: Class) -> Result(String, Nil)

@external(erlang, "howdy_ui_ffi", "remember_name")
@external(javascript, "./stylesheet.ffi.mjs", "remember_name")
fn remember_name(class: Class, name: String) -> Nil

@external(erlang, "howdy_ui_ffi", "all_css")
@external(javascript, "./stylesheet.ffi.mjs", "all_css")
fn all_css() -> String

@external(erlang, "howdy_ui_ffi", "css_for")
@external(javascript, "./stylesheet.ffi.mjs", "css_for")
fn css_for(names: List(String)) -> String

@external(erlang, "howdy_ui_ffi", "scope_begin")
@external(javascript, "./stylesheet.ffi.mjs", "scope_begin")
fn scope_begin() -> Nil

@external(erlang, "howdy_ui_ffi", "scope_end")
@external(javascript, "./stylesheet.ffi.mjs", "scope_end")
fn scope_end() -> List(String)

@external(erlang, "howdy_ui_ffi", "note")
@external(javascript, "./stylesheet.ffi.mjs", "note")
fn note(name: String) -> Nil

@external(erlang, "erlang", "phash2")
fn phash2(term: String, range: Int) -> Int

/// Register a class and return its generated name. If a render scope is
/// open in this process, the name is recorded in it.
///
/// The name is a content hash, so it is computed once per distinct class
/// and then read from the cache alongside the CSS.
pub fn class_name(class: Class) -> String {
  let name = case name_of(class) {
    Ok(name) -> name
    Error(Nil) -> {
      let #(name, css) = render(class)
      case name == "" || known(name) {
        True -> Nil
        False -> register(name, css)
      }
      remember_name(class, name)
      name
    }
  }
  note(name)
  name
}

/// A class's name and CSS, the same on every target.
///
/// Sketch names a class by hashing `string.inspect` of its styles, which
/// prints record labels on JavaScript and not on Erlang, so the two targets
/// disagree. An island renders the same view on both, so the name here is
/// a hash of the CSS Sketch renders, with Sketch's own name taken out.
/// Classes Sketch names explicitly keep their names.
pub fn render(class: Class) -> #(String, String) {
  let assert Ok(sheet) = sketch.stylesheet(strategy: sketch.Ephemeral)
  let #(sheet, generated) = sketch.class_name(class, sheet)
  let css = sketch.render(sheet)
  case generated {
    "css-" <> _ -> {
      let name =
        string.replace(css, generated, "")
        |> murmur3a.hash_string(1)
        |> murmur3a.hex_digest
      let name = "css-" <> name
      #(name, string.replace(css, generated, name))
    }
    _ -> #(generated, css)
  }
}

/// Register a block of CSS that is not a class, such as `@keyframes`, under
/// a stable name. It is emitted once per document, alongside the classes,
/// wherever the CSS registered so far is collected. If a render scope is
/// open in this process, the name is recorded in it, so a live view's
/// stylesheet carries the block when its view needs it.
pub fn rule(name: String, css: String) -> Nil {
  case known(name) {
    True -> Nil
    False -> register(name, css)
  }
  note(name)
}

/// Render an explicit list of rules independently of the runtime registry,
/// in the given order, first occurrence of a name winning.
pub fn css_of_rules(rules: List(#(String, String))) -> String {
  let #(_, parts) =
    list.fold(rules, #(set.new(), []), fn(acc, rule) {
      let #(seen, parts) = acc
      let #(name, css) = rule
      case set.contains(seen, name) {
        True -> acc
        False -> #(set.insert(seen, name), [css, ..parts])
      }
    })
  parts |> list.reverse |> string.join("\n\n")
}

/// Run `render` and return its result with the CSS for exactly the classes
/// it used.
pub fn scoped(render: fn() -> a) -> #(a, String) {
  let #(result, names) = scoped_names(render)
  #(result, css_for(names))
}

/// Run `render` and return its result with the names of the classes it
/// used, in the order they were first seen.
pub fn scoped_names(render: fn() -> a) -> #(a, List(String)) {
  scope_begin()
  let result = render()
  #(result, scope_end())
}

/// The CSS for every class registered so far, in the order first seen.
pub fn css() -> String {
  all_css()
}

/// Render an explicit class list independently of the runtime registry.
/// First occurrence wins, preserving the caller's deliberate cascade order.
pub fn css_of(classes: List(Class)) -> String {
  let #(_, parts) =
    list.fold(classes, #(set.new(), []), fn(acc, class) {
      let #(seen, parts) = acc
      let #(name, css) = render(class)
      case name == "" || set.contains(seen, name) {
        True -> acc
        False -> #(set.insert(seen, name), [css, ..parts])
      }
    })
  parts |> list.reverse |> string.join("\n\n")
}

/// Everything a document needs: theme variables, base styles and the
/// component CSS registered so far.
pub fn document_css(themes: Themes) -> String {
  theme.to_css(themes) <> "\n" <> base <> "\n" <> css()
}

/// A short hash of some CSS, used as an ETag.
pub fn etag(css: String) -> String {
  "\"" <> int.to_base16(phash2(css, 4_294_967_296)) <> "\""
}

/// Styles for the elements a page does not create through `howdy/ui`,
/// such as `<body>` and raw text.
pub const base = "*, *::before, *::after { box-sizing: border-box; }
body { margin: 0; background: "
  <> tokens.background
  <> "; color: "
  <> tokens.text
  <> "; font-family: "
  <> tokens.font_body
  <> "; line-height: 1.5; -webkit-font-smoothing: antialiased; }
h1, h2, h3, h4, h5, h6 { font-family: "
  <> tokens.font_heading
  <> "; line-height: 1.2; }
code, pre, kbd { font-family: "
  <> tokens.font_mono
  <> "; }
a { color: "
  <> tokens.primary
  <> "; }"
