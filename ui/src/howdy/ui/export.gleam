//// Write the CSS for a published site to a file.
////
//// The runtime route in `ui.stylesheet` only knows classes that have been
//// rendered, and differs between nodes. For publishing, write one file
//// from a known list of classes instead. Put a script module in your
//// project and run it with `gleam run -m tasks/css`:
////
//// ```gleam
//// // src/tasks/css.gleam
//// import howdy/ui/export
//// import howdy/ui/theme
//// import my_styles
////
//// pub fn main() {
////   let assert Ok(Nil) =
////     export.new(theme.default_themes())
////     |> export.classes(my_styles.all())
////     |> export.write(to: "priv/static/ui.css")
//// }
//// ```
////
//// The built-in components are always included. Serve the file with
//// `howdy/static` and link it from pages with `page.stylesheet`, adding
//// whatever cache-busting you use for other assets:
////
//// ```gleam
//// howdy.controller(static.new(from: "priv/static") |> static.at("/assets") |> static.max_age(seconds: 31_536_000) |> static.build)
//// ```
////
//// ```gleam
//// page.stylesheet(page, at: "/assets/ui.css?v=" <> my_app.version)
//// ```
////
//// The output is minified and deterministic: the same classes give the
//// same bytes on every machine, in the configured class-list order.

import gleam/list
import gleam/string
import howdy/ui
import howdy/ui/internal/stylesheet
import howdy/ui/theme.{type Themes}
import simplifile
import sketch/css.{type Class}

/// A file under construction.
pub opaque type Export {
  Export(themes: Themes, classes: List(Class), rules: List(#(String, String)))
}

/// Start with the themes the site offers and the built-in components: their
/// classes and the rules they register with `style.rule`.
pub fn new(themes: Themes) -> Export {
  Export(themes:, classes: ui.classes(), rules: ui.rules())
}

/// Add classes of your own, usually the `all` list of a styles module.
pub fn classes(export: Export, classes: List(Class)) -> Export {
  Export(..export, classes: list.append(export.classes, classes))
}

/// Add CSS of your own that components register with `style.rule`, such as
/// the `rules` list of a copied component. Each name is written once.
pub fn rules(export: Export, rules: List(#(String, String))) -> Export {
  Export(..export, rules: list.append(export.rules, rules))
}

/// The finished CSS in configured class order, then the rules,
/// conservatively minified.
pub fn to_css(export: Export) -> String {
  [
    theme.to_css(export.themes),
    stylesheet.base,
    stylesheet.css_of(export.classes),
    stylesheet.css_of_rules(export.rules),
  ]
  |> string.join("\n")
  |> minify
}

/// Write the CSS to `path`, creating parent directories as needed.
pub fn write(
  export: Export,
  to path: String,
) -> Result(Nil, simplifile.FileError) {
  let directory = string.drop_end(path, string.length(last_segment(path)))
  let _ = case directory {
    "" -> Ok(Nil)
    _ -> simplifile.create_directory_all(directory)
  }
  simplifile.write(path, to_css(export))
}

fn last_segment(path: String) -> String {
  case list.last(string.split(path, "/")) {
    Ok(segment) -> segment
    Error(Nil) -> path
  }
}

// -- Minifying ---------------------------------------------------------------

/// Conservatively compact generated CSS. Preserve descendant-selector spaces
/// before colons and whitespace inside strings and arithmetic expressions.
/// Inputs with escapes, comments or URLs are returned unchanged: handling
/// their token boundaries requires a full CSS tokenizer.
pub fn minify(css: String) -> String {
  case
    string.contains(css, "\\")
    || string.contains(css, "/*")
    || string.contains(string.lowercase(css), "url(")
  {
    True -> css
    False ->
      css
      |> string.to_graphemes
      |> minify_loop(Code(previous: "", pending_space: False), "")
  }
}

type State {
  /// Outside a string. `previous` is the last character written.
  Code(previous: String, pending_space: Bool)
  /// Inside a string opened with `quote`.
  Quoted(quote: String)
}

fn minify_loop(chars: List(String), state: State, out: String) -> String {
  case chars, state {
    [], _ -> out

    [c, ..rest], Quoted(quote) ->
      case c == quote {
        True ->
          minify_loop(rest, Code(previous: c, pending_space: False), out <> c)
        False -> minify_loop(rest, state, out <> c)
      }

    [c, ..rest], Code(previous:, pending_space:) ->
      case c {
        " " | "\n" | "\t" | "\r" ->
          minify_loop(rest, Code(previous:, pending_space: True), out)

        "\"" | "'" -> {
          let out = maybe_space(out, previous, pending_space, c)
          minify_loop(rest, Quoted(quote: c), out <> c)
        }

        "}" -> {
          // A block never needs its last semicolon.
          let out = case previous {
            ";" -> string.drop_end(out, 1)
            _ -> out
          }
          minify_loop(rest, Code(previous: c, pending_space: False), out <> c)
        }

        _ -> {
          let out = maybe_space(out, previous, pending_space, c)
          minify_loop(rest, Code(previous: c, pending_space: False), out <> c)
        }
      }
  }
}

/// Write a single space only where dropping it would change meaning:
/// between ordinary characters and before pseudo-selectors. A colon may
/// follow a descendant combinator, so whitespace before it must survive.
fn maybe_space(
  out: String,
  previous: String,
  pending: Bool,
  next: String,
) -> String {
  case
    pending
    && !punctuation(previous)
    && { next == ":" || !punctuation(next) }
    && previous != ""
  {
    True -> out <> " "
    False -> out
  }
}

fn punctuation(c: String) -> Bool {
  case c {
    "{" | "}" | ":" | ";" | "," | ">" -> True
    _ -> False
  }
}
