//// Templates in a project: compiling each into the module it becomes.

import filepath
import gleam/list
import gleam/string
import howdy/templates/internal/generate.{type Output}
import howdy/templates/internal/parse
import howdy/templates/internal/syntax.{type Problem, Problem, Span}

pub const extension = ".gsx"

pub type Compiled {
  Compiled(output: Output, problems: List(Problem), template: syntax.Template)
}

/// Parses and generates one template. `label` names the function, after
/// its file, and the module's first line; nothing is read or written.
pub fn compile(label: String, text: String) -> Compiled {
  let #(template, problems) = parse.parse(text)
  let name = function_name(label)
  let output = generate.generate(template, name, label)
  let directories =
    string.split(label, "/") |> list.drop(1) |> list.reverse |> list.drop(1)
  let name_problems =
    list.flatten([
      case is_function_name(name) {
        True -> []
        False -> [
          Problem(
            "A template is a function named after its file, so "
              <> filepath.base_name(label)
              <> " needs a lowercase_with_underscores name",
            Span(0, 0),
          ),
        ]
      },
      list.filter_map(directories, fn(directory) {
        case is_function_name(directory) {
          True -> Error(Nil)
          False ->
            Ok(Problem(
              "Directories of templates are module names, so "
                <> directory
                <> " needs a lowercase_with_underscores name",
              Span(0, 0),
            ))
        }
      }),
    ])
  Compiled(
    output:,
    problems: list.flatten([name_problems, problems, output.problems]),
    template:,
  )
}

pub fn function_name(path: String) -> String {
  filepath.base_name(path) |> string.drop_end(string.length(extension))
}

fn is_function_name(name: String) -> Bool {
  case string.pop_grapheme(name) {
    Ok(#(first, rest)) ->
      string.lowercase(first) == first
      && string.uppercase(first) != first
      && list.all(string.to_graphemes(rest), fn(c) {
        c == "_"
        || { string.lowercase(c) == c && string.uppercase(c) != c }
        || string.contains("0123456789", c)
      })
      && !list.contains(
        [
          "as", "assert", "auto", "case", "const", "delegate", "derive", "echo",
          "else", "fn", "if", "implement", "import", "let", "macro", "opaque",
          "panic", "pub", "test", "todo", "type", "use",
        ],
        name,
      )
    Error(_) -> False
  }
}
