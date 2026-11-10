//// Templates in a project: finding them, writing their modules, and
//// reporting their problems the way the Gleam compiler reports its own.

import filepath
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import howdy/templates/internal/format
import howdy/templates/internal/generate.{type Output}
import howdy/templates/internal/parse
import howdy/templates/internal/position
import howdy/templates/internal/syntax.{type Problem, Problem, Span}
import simplifile

pub const extension = ".gsx"

/// A Gleam project: where it is and its package name.
pub type Project {
  Project(root: String, name: String)
}

/// The project at `root`, from its `gleam.toml`.
pub fn load(root: String) -> Result(Project, String) {
  let toml = join(root, "gleam.toml")
  case simplifile.read(toml) {
    Error(_) -> Error("howdy_templates: no gleam.toml in " <> root)
    Ok(text) ->
      text
      |> string.split("\n")
      |> list.find_map(fn(line) {
        case string.trim(line) {
          "name" <> rest ->
            case string.split(rest, "\"") {
              [_, name, ..] -> Ok(name)
              _ -> Error(Nil)
            }
          _ -> Error(Nil)
        }
      })
      |> result.map(fn(name) { Project(root:, name:) })
      |> result.replace_error("howdy_templates: no name in " <> toml)
  }
}

/// The project to work on from the current directory: `.`, or the nearest
/// directory above it with a `gleam.toml`, the way `gleam` finds it.
pub fn root() -> String {
  case simplifile.is_file("gleam.toml"), simplifile.current_directory() {
    Ok(True), _ | _, Error(_) -> "."
    _, Ok(directory) ->
      case project_of(join(directory, "gleam.toml")) {
        Ok(project) -> project.root
        Error(_) -> "."
      }
  }
}

/// The project a file is in: the nearest `gleam.toml` above it.
pub fn project_of(path: String) -> Result(Project, String) {
  let directory = filepath.directory_name(path)
  case simplifile.is_file(join(directory, "gleam.toml")) {
    Ok(True) -> load(directory)
    _ ->
      case directory == path || directory == "/" || directory == "" {
        True ->
          Error("howdy_templates: " <> path <> " isn't in a Gleam project")
        False -> project_of(directory)
      }
  }
}

fn join(root: String, path: String) -> String {
  case root {
    "." | "" -> path
    _ -> filepath.join(root, path)
  }
}

/// Where templates live: `templates/`, next to `src/`.
pub fn templates_directory(project: Project) -> String {
  join(project.root, "templates")
}

/// Where their modules are generated: `src/<package>/templates/`, which
/// holds nothing else.
pub fn modules_directory(project: Project) -> String {
  join(project.root, "src/" <> project.name <> "/templates")
}

/// A template's path from the templates directory, without its extension:
/// `admin/users` for `templates/admin/users.gsx`. Errors for a file
/// outside it.
fn template_name(project: Project, path: String) -> Result(String, Nil) {
  let prefix = templates_directory(project) <> "/"
  case string.starts_with(path, prefix), string.ends_with(path, extension) {
    True, True ->
      Ok(
        path
        |> string.drop_start(string.length(prefix))
        |> string.drop_end(string.length(extension)),
      )
    _, _ -> Error(Nil)
  }
}

/// How a template is named in reports and in its module's first line:
/// `templates/admin/users.gsx`.
pub fn label(project: Project, path: String) -> String {
  case template_name(project, path) {
    Ok(name) -> "templates/" <> name <> extension
    Error(_) -> path
  }
}

pub fn module_path(project: Project, template: String) -> Result(String, Nil) {
  use name <- result.map(template_name(project, template))
  modules_directory(project) <> "/" <> name <> ".gleam"
}

/// The template a generated module came from, found from the module's path:
/// `<root>/src/<package>/templates/<name>.gleam`.
pub fn template_of_module(module: String) -> Result(#(Project, String), Nil) {
  let segments = string.split(module, "/")
  segments
  |> list.index_map(fn(segment, i) { #(i, segment) })
  |> list.find_map(fn(entry) {
    let #(i, segment) = entry
    let rest = list.drop(segments, i + 1)
    case segment, rest {
      "src", [package, "templates", _, ..] -> {
        let root = case list.take(segments, i) {
          [] -> "."
          [""] -> "/"
          before -> string.join(before, "/")
        }
        use project <- result.try(load(root) |> result.replace_error(Nil))
        case project.name == package {
          False -> Error(Nil)
          True -> {
            let name =
              list.drop(rest, 2)
              |> string.join("/")
              |> string.drop_end(string.length(".gleam"))
            Ok(#(
              project,
              templates_directory(project) <> "/" <> name <> extension,
            ))
          }
        }
      }
      _, _ -> Error(Nil)
    }
  })
}

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

fn files(directory: String) -> List(String) {
  simplifile.get_files(directory)
  |> result.unwrap([])
  |> list.sort(string.compare)
}

pub fn find(project: Project) -> List(String) {
  files(templates_directory(project))
  |> list.filter(string.ends_with(_, extension))
}

/// Templates left in a source directory, where they aren't compiled.
fn misplaced(project: Project) -> List(String) {
  ["src", "test", "dev"]
  |> list.flat_map(fn(directory) { files(join(project.root, directory)) })
  |> list.filter(string.ends_with(_, extension))
  |> list.map(fn(path) {
    "error: "
    <> path
    <> " is in a source directory\nTemplates live in "
    <> templates_directory(project)
    <> "/, next to src/, and their modules are generated into "
    <> modules_directory(project)
    <> "/.\n"
  })
}

pub type Generated {
  Generated(
    templates: Int,
    /// Modules written, because they were new or their template changed.
    written: List(String),
    /// Modules deleted, because their template was.
    deleted: List(String),
  )
}

type Entry {
  Entry(path: String, module: String, text: String, compiled: Compiled)
}

fn read_all(project: Project) -> #(List(Entry), List(String)) {
  find(project)
  |> list.map(fn(path) {
    let assert Ok(module) = module_path(project, path)
      as "found in the templates directory"
    case simplifile.read(path) {
      Ok(text) ->
        Ok(Entry(path, module, text, compile(label(project, path), text)))
      Error(error) ->
        Error(path <> ": can't read: " <> simplifile.describe_error(error))
    }
  })
  |> result.partition
  |> fn(pair) { #(list.reverse(pair.0), list.reverse(pair.1)) }
}

fn problem_reports(project: Project, entries: List(Entry)) -> List(String) {
  list.filter_map(entries, fn(entry) {
    case entry.compiled.problems {
      [] -> Error(Nil)
      problems ->
        Ok(
          list.map(problems, report(label(project, entry.path), entry.text, _))
          |> string.join("\n"),
        )
    }
  })
}

/// Generates the module for every template in the project, and removes the
/// modules of templates that are gone. With `gitignore`, the modules'
/// directory ignores itself. A template with problems keeps its last
/// module; all of the problems come back as one report.
pub fn generate_all(
  project: Project,
  gitignore gitignore: Bool,
) -> Result(Generated, String) {
  let #(entries, read_errors) = read_all(project)
  let directory = modules_directory(project)
  // Only modules whose template changed are formatted and written: the
  // hash in the first line says what a module was generated from. A file
  // there that this didn't write is never replaced.
  let #(stale, foreign) =
    list.fold(entries, #([], []), fn(acc, entry) {
      let #(stale, foreign) = acc
      case entry.compiled.problems {
        [_, ..] -> acc
        [] ->
          case simplifile.read(entry.module) {
            Error(_) -> #([entry, ..stale], foreign)
            Ok(existing) ->
              case generate.marker_hash(existing) {
                Error(_) -> #(stale, [entry.module, ..foreign])
                hash ->
                  case
                    hash == generate.marker_hash(entry.compiled.output.code)
                  {
                    True -> acc
                    False -> #([entry, ..stale], foreign)
                  }
              }
          }
      }
    })
  let stale = list.reverse(stale)
  let formatted =
    format.format_all(list.map(stale, fn(entry) { entry.compiled.output.code }))
  let written =
    list.zip(stale, formatted)
    |> list.map(fn(pair) {
      let #(entry, formatted) = pair
      let code = case formatted {
        Ok(formatted) -> formatted.code
        Error(_) -> entry.compiled.output.code
      }
      let _ =
        simplifile.create_directory_all(filepath.directory_name(entry.module))
      case simplifile.write(entry.module, code) {
        Ok(Nil) -> Ok(entry.module)
        Error(error) ->
          Error(
            entry.module
            <> ": can't write: "
            <> simplifile.describe_error(error),
          )
      }
    })
  let deleted = remove_orphans(directory, list.map(entries, fn(e) { e.module }))
  let _ = case gitignore && entries != [] {
    True -> ignore_directory(directory)
    False -> Nil
  }
  let reports =
    list.flatten([
      misplaced(project),
      read_errors,
      problem_reports(project, entries),
      list.map(list.reverse(foreign), fn(module) {
        "error: "
        <> module
        <> " wasn't generated by howdy_templates\n"
        <> directory
        <> "/ holds generated modules only; move it somewhere else.\n"
      }),
      list.filter_map(written, result_error),
    ])
  case reports {
    [] ->
      Ok(Generated(
        templates: list.length(entries),
        written: list.filter_map(written, fn(r) { r }),
        deleted:,
      ))
    _ -> Error(string.join(reports, "\n"))
  }
}

fn result_error(result: Result(a, e)) -> Result(e, Nil) {
  case result {
    Ok(_) -> Error(Nil)
    Error(e) -> Ok(e)
  }
}

/// Fails if a template has problems or its module isn't what generating it
/// now would write. Returns how many templates there are.
pub fn check(project: Project) -> Result(Int, String) {
  let #(entries, read_errors) = read_all(project)
  let good = list.filter(entries, fn(entry) { entry.compiled.problems == [] })
  let formatted =
    format.format_all(list.map(good, fn(entry) { entry.compiled.output.code }))
  let out_of_date =
    list.zip(good, formatted)
    |> list.filter_map(fn(pair) {
      let #(entry, formatted) = pair
      let expected = case formatted {
        Ok(formatted) -> formatted.code
        Error(_) -> entry.compiled.output.code
      }
      let state = case simplifile.read(entry.module) {
        Ok(existing) if existing == expected -> Error(Nil)
        Ok(_) -> Ok(" is out of date with ")
        Error(_) -> Ok(" hasn't been generated from ")
      }
      use state <- result.map(state)
      "error: "
      <> entry.module
      <> state
      <> entry.path
      <> "\nRun: gleam run -m howdy/templates\n"
    })
  case
    list.flatten([
      misplaced(project),
      read_errors,
      problem_reports(project, entries),
      out_of_date,
    ])
  {
    [] -> Ok(list.length(entries))
    reports -> Error(string.join(reports, "\n"))
  }
}

/// Generated modules whose template is gone, then directories left empty.
/// Only files that start with the generated marker are touched.
fn remove_orphans(directory: String, modules: List(String)) -> List(String) {
  let deleted =
    files(directory)
    |> list.filter(fn(path) {
      string.ends_with(path, ".gleam") && !list.contains(modules, path)
    })
    |> list.filter(fn(path) {
      case simplifile.read(path) {
        Ok(code) -> generate.is_generated(code)
        Error(_) -> False
      }
    })
    |> list.filter(fn(path) { simplifile.delete(path) |> result.is_ok })
  remove_empty_directories(directory)
  deleted
}

fn remove_empty_directories(directory: String) -> Nil {
  case simplifile.read_directory(directory) {
    Error(_) -> Nil
    Ok(entries) ->
      list.each(entries, fn(entry) {
        let path = filepath.join(directory, entry)
        case simplifile.is_directory(path) {
          Ok(True) -> {
            let _ = remove_empty_directories(path)
            case simplifile.read_directory(path) {
              Ok([]) -> {
                let _ = simplifile.delete(path)
                Nil
              }
              _ -> Nil
            }
          }
          _ -> Nil
        }
      })
  }
}

/// A `.gitignore` of `*` ignores the directory, itself included.
fn ignore_directory(directory: String) -> Nil {
  let path = filepath.join(directory, ".gitignore")
  let contents =
    "# Generated by howdy_templates from templates/. Do not edit.\n*\n"
  case simplifile.read(path) {
    Ok(existing) if existing == contents -> Nil
    _ -> {
      let _ = simplifile.create_directory_all(directory)
      let _ = simplifile.write(path, contents)
      Nil
    }
  }
}

// REPORTS ---------------------------------------------------------------------

/// A problem in a template, laid out like the Gleam compiler's errors.
pub fn report(path: String, text: String, problem: Problem) -> String {
  let #(line, _) = position.from_offset(text, problem.span.start)
  let column = position.character_column(text, problem.span.start) + 1
  let #(line_text, line_start) = position.line_at(text, problem.span.start)
  let end = int.min(problem.span.end, line_start + string.byte_size(line_text))
  let width =
    int.max(
      1,
      position.character_column(text, end)
        - position.character_column(text, problem.span.start),
    )
  "error: "
  <> problem.message
  <> "\n"
  <> snippet(path, line + 1, column, line_text, width, "")
}

/// The location, the line and carets under `width` characters from
/// `column`, with `label` after them.
pub fn snippet(
  path: String,
  line: Int,
  column: Int,
  line_text: String,
  width: Int,
  label: String,
) -> String {
  let number = int.to_string(line)
  let gutter = string.repeat(" ", string.length(number))
  let carets = string.repeat("^", width)
  let label = case label {
    "" -> ""
    _ -> " " <> label
  }
  gutter
  <> " ┌─ "
  <> path
  <> ":"
  <> number
  <> ":"
  <> int.to_string(column)
  <> "\n"
  <> gutter
  <> " │\n"
  <> number
  <> " │ "
  <> line_text
  <> "\n"
  <> gutter
  <> " │ "
  <> string.repeat(" ", column - 1)
  <> carets
  <> label
  <> "\n"
}
