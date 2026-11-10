//// Compiler output points at generated modules; this points it back at
//// the templates they came from.

import gleam/int
import gleam/list
import gleam/result
import gleam/string
import howdy/templates/internal/format
import howdy/templates/internal/generate
import howdy/templates/internal/position
import howdy/templates/internal/project
import simplifile

/// Rewrites every location in a generated module to the template line it
/// came from. Anything else, and modules that are out of date with their
/// template, are left as they are.
pub fn rewrite(output: String) -> String {
  output
  |> string.split("\n")
  |> rewrite_lines([])
  |> add_hints
  |> string.join("\n")
}

const element_hint = "Hint: {…} is text, so it needs a String. To put an element there, use
the function as a tag, <Name … />, which needs labelled arguments, or
spread it as a list: {...[name(…)]}."

/// Extra help for a compiler message about a template, when there is some.
pub fn hint(message: String) -> Result(String, Nil) {
  case string.split_once(message, "Expected type:") {
    Ok(#(_, after)) ->
      case string.split_once(after, "Found type:") {
        Ok(#(expected, found)) ->
          case
            string.trim(expected) == "String"
            && string.contains(found, "Element(")
          {
            True -> Ok(element_hint)
            False -> Error(Nil)
          }
        Error(_) -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

/// Adds hints to the messages about templates that have one.
fn add_hints(lines: List(String)) -> List(String) {
  lines
  |> messages([], [])
  |> list.flat_map(fn(message) {
    let text = string.join(message, "\n")
    case string.contains(text, ".gsx:"), hint(text) {
      // The hint goes after the message, before the blank lines ending it.
      True, Ok(hint) -> {
        let #(blank, body) =
          list.reverse(message)
          |> list.split_while(fn(line) { string.trim(line) == "" })
        list.flatten([list.reverse(body), ["", hint], blank])
      }
      _, _ -> message
    }
  })
}

/// Splits output into messages, each starting at an `error:` or `warning:`.
fn messages(
  lines: List(String),
  current: List(String),
  acc: List(List(String)),
) -> List(List(String)) {
  case lines {
    [] -> list.reverse([list.reverse(current), ..acc])
    [line, ..rest] ->
      case
        string.starts_with(line, "error:")
        || string.starts_with(line, "warning:")
      {
        True -> messages(rest, [line], [list.reverse(current), ..acc])
        False -> messages(rest, [line, ..current], acc)
      }
  }
}

fn rewrite_lines(lines: List(String), acc: List(String)) -> List(String) {
  case lines {
    [] -> list.reverse(acc)
    [line, ..rest] ->
      case location(line) {
        Error(_) -> rewrite_lines(rest, [line, ..acc])
        Ok(#(path, row, column)) -> {
          let #(snippet, rest) = list.split_while(rest, string.contains(_, "│"))
          case rewritten(path, row, column, snippet) {
            Ok(replacement) ->
              rewrite_lines(rest, list.append(list.reverse(replacement), acc))
            Error(_) ->
              rewrite_lines(
                rest,
                list.append(list.reverse(snippet), [line, ..acc]),
              )
          }
        }
      }
  }
}

/// `┌─ path:row:column`
fn location(line: String) -> Result(#(String, Int, Int), Nil) {
  use #(_, place) <- result.try(string.split_once(line, "┌─ "))
  case string.split(string.trim(place), ":") |> list.reverse {
    [column, row, ..path] -> {
      use row <- result.try(int.parse(row))
      use column <- result.try(int.parse(column))
      let path = path |> list.reverse |> string.join(":")
      case string.ends_with(path, ".gleam") {
        True -> Ok(#(path, row, column))
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn rewritten(
  path: String,
  row: Int,
  column: Int,
  snippet: List(String),
) -> Result(List(String), Nil) {
  use #(project_, template_path) <- result.try(project.template_of_module(path))
  use module <- result.try(simplifile.read(path) |> result.replace_error(Nil))
  use <- bool_guard(!generate.is_generated(module))
  use text <- result.try(
    simplifile.read(template_path) |> result.replace_error(Nil),
  )
  let compiled = project.compile(project.label(project_, template_path), text)
  // Offsets only mean something if the module is what the template
  // generates now. It's usually formatted, so they go through the
  // formatter's alignment back to the generated code.
  use to_generated <- result.try(case compiled.output.code == module {
    True -> Ok(fn(offset) { offset })
    False ->
      case format.format(compiled.output.code) {
        Ok(formatted) if formatted.code == module ->
          Ok(fn(offset) { format.to_raw(formatted.runs, offset) })
        _ -> Error(Nil)
      }
  })
  let #(width, label) = carets(snippet)
  let start =
    to_generated(position.from_line_and_character(module, row, column))
  let end =
    to_generated(position.from_line_and_character(module, row, column + width))
  use template_start <- result.try(generate.to_template(
    compiled.output,
    start,
    False,
  ))
  let template_end =
    generate.to_template(compiled.output, end, True)
    |> result.unwrap(template_start)
  let #(line_text, line_start) = position.line_at(text, template_start)
  let template_end =
    int.min(template_end, line_start + string.byte_size(line_text))
  let first = position.character_column(text, template_start)
  let width = int.max(1, position.character_column(text, template_end) - first)
  let #(line, _) = position.from_offset(text, template_start)
  project.snippet(template_path, line + 1, first + 1, line_text, width, label)
  |> string.trim_end
  |> string.split("\n")
  |> Ok
}

/// How many carets the compiler drew on one line, and the label after
/// them. A span over several lines counts as one character.
fn carets(snippet: List(String)) -> #(Int, String) {
  let marked =
    snippet
    |> list.filter_map(fn(line) {
      case string.split_once(line, "│") {
        Ok(#(_, after)) ->
          case string.contains(after, "^") {
            True -> Ok(after)
            False -> Error(Nil)
          }
        Error(_) -> Error(Nil)
      }
    })
    |> list.last
  case marked {
    Error(_) -> #(1, "")
    Ok(after) -> {
      let #(_, from_carets) =
        string.split_once(after, "^") |> result.unwrap(#("", ""))
      let rest = "^" <> from_carets
      let carets = string.length(rest) - string.length(drop_carets(rest))
      let label = string.trim(drop_carets(rest))
      case string.contains(after, "╰") {
        True -> #(1, label)
        False -> #(carets, label)
      }
    }
  }
}

fn drop_carets(text: String) -> String {
  case text {
    "^" <> rest -> drop_carets(rest)
    _ -> text
  }
}

fn bool_guard(when: Bool, otherwise: fn() -> Result(a, Nil)) -> Result(a, Nil) {
  case when {
    True -> Error(Nil)
    False -> otherwise()
  }
}
