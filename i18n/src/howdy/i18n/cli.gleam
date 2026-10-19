//// The `gleam run -m howdy/i18n/cli` command line.
////
//// - `gen` checks the catalogues and writes a Gleam module with a function
////   for each message, by default `src/<app>/messages.gleam`.
//// - `check` reports problems without writing anything, and fails when
////   there are errors, for CI.
//// - `add <locale>` starts a catalogue for another locale, as a copy of the
////   source catalogue marked for review, for translators to work through.
////
//// Options:
////
//// - `--locales=<dir>`: where the catalogues are, by default `locales`.
////   Each is a JSON file named by its locale, such as `de.json`; see
////   `howdy/i18n` for what goes in them.
//// - `--out=<file>`: the module `gen` writes.
//// - `--source=<locale>`: the locale messages are written in first, by
////   default `en`. Its catalogue decides which messages exist and what
////   arguments they take; the others translate it, and any message they
////   lack falls back to it.
//// - `--standalone`: generate a module that depends only on the standard
////   library, taking the catalogue's locale as a string instead of a
////   translator. For libraries that offer translations without depending
////   on this package.
////
//// Errors are messages that cannot be generated, such as invalid ICU
//// syntax or an argument the source message lacks. Warnings, such as a
//// missing message or plural form, fall back and do not stop `gen`.

import argv
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import howdy/i18n/internal/catalogue
import howdy/i18n/internal/generate.{type Report}
import simplifile

pub fn main() -> Nil {
  run(argv.load().arguments)
}

/// Run a command and print what happened.
pub fn run(args: List(String)) -> Nil {
  case execute(args) {
    Ok(output) -> io.println(output)
    Error(output) -> {
      io.println_error(output)
      halt(1)
    }
  }
}

@external(erlang, "howdy_i18n_cli_ffi", "halt")
@external(javascript, "../../howdy_i18n_cli_ffi.mjs", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "howdy_i18n_cli_ffi", "format")
@external(javascript, "../../howdy_i18n_cli_ffi.mjs", "format")
fn format_file(path: String) -> Result(Nil, Nil)

type Settings {
  Settings(
    locales: String,
    out: Result(String, Nil),
    source: String,
    standalone: Bool,
  )
}

/// Run a command, returning what to print, or what went wrong.
pub fn execute(args: List(String)) -> Result(String, String) {
  let #(options, words) = list.partition(args, string.starts_with(_, "--"))
  use settings <- result.try(settings(options))
  use <- bool_guard(
    !catalogue.valid_locale(settings.source),
    "invalid source locale "
      <> settings.source
      <> ": use a tag such as en or pt-BR",
  )
  case words {
    ["gen"] -> gen(settings)
    ["check"] -> check(settings)
    ["add", locale] -> add(settings, locale)
    _ -> Error(usage)
  }
}

const usage = "Usage: gleam run -m howdy/i18n/cli -- <command> [options]

Commands:
  gen            write the messages module from the catalogues
  check          report problems in the catalogues without writing anything
  add <locale>   start a catalogue for another locale

Options:
  --locales=<dir>     where the catalogues are (default: locales)
  --out=<file>        the module gen writes (default: src/<app>/messages.gleam)
  --source=<locale>   the locale messages are written in first (default: en)
  --standalone        depend only on the standard library"

fn settings(options: List(String)) -> Result(Settings, String) {
  list.try_fold(
    options,
    Settings(
      locales: "locales",
      out: Error(Nil),
      source: "en",
      standalone: False,
    ),
    fn(settings, option) {
      case option {
        "--locales=" <> dir -> Ok(Settings(..settings, locales: dir))
        "--out=" <> file -> Ok(Settings(..settings, out: Ok(file)))
        "--source=" <> locale -> Ok(Settings(..settings, source: locale))
        "--standalone" -> Ok(Settings(..settings, standalone: True))
        _ -> Error("unknown option " <> option <> "\n\n" <> usage)
      }
    },
  )
}

fn options(settings: Settings) -> generate.Options {
  generate.Options(
    source: settings.source,
    standalone: settings.standalone,
    origin: settings.locales,
  )
}

fn gen(settings: Settings) -> Result(String, String) {
  use catalogues <- result.try(catalogue.load_directory(settings.locales))
  use out <- result.try(case settings.out {
    Ok(out) -> Ok(out)
    Error(Nil) -> default_out()
  })
  case generate.generate(catalogues, options(settings)) {
    Error(report) -> Error(describe(report))
    Ok(#(source, report)) -> {
      let directory = case string.split(out, "/") |> list.reverse {
        [_, ..rest] -> string.join(list.reverse(rest), "/")
        [] -> "."
      }
      use _ <- result.try(case directory {
        "" -> Ok(Nil)
        _ ->
          simplifile.create_directory_all(directory)
          |> result.map_error(fn(error) {
            "cannot create "
            <> directory
            <> ": "
            <> simplifile.describe_error(error)
          })
      })
      // Format a copy under build/ first, so a module whose messages have
      // not changed is left alone and does not set off a rebuild.
      let draft = "build/howdy_i18n/" <> file_name(out)
      let formatted =
        simplifile.create_directory_all("build/howdy_i18n")
        |> result.try(fn(_) { simplifile.write(draft, source) })
        |> result.replace_error(Nil)
        |> result.try(fn(_) { format_file(draft) })
        |> result.try(fn(_) {
          simplifile.read(draft) |> result.replace_error(Nil)
        })
      let #(source, note) = case formatted {
        Ok(formatted) -> #(formatted, "")
        Error(Nil) -> #(source, "\n(gleam format could not be run on it)")
      }
      let unchanged = simplifile.read(out) == Ok(source)
      use _ <- result.try(case unchanged {
        True -> Ok(Nil)
        False ->
          simplifile.write(out, source)
          |> result.map_error(fn(error) {
            "cannot write " <> out <> ": " <> simplifile.describe_error(error)
          })
      })
      let verb = case unchanged {
        True -> "Kept "
        False -> "Wrote "
      }
      let formatted = note
      Ok(
        verb
        <> out
        <> " from "
        <> plural(list.length(catalogues), "catalogue")
        <> formatted
        <> summary(report),
      )
    }
  }
}

fn check(settings: Settings) -> Result(String, String) {
  use catalogues <- result.try(catalogue.load_directory(settings.locales))
  let report = generate.check(catalogues, options(settings))
  case report.errors {
    [] ->
      Ok(
        "Checked "
        <> plural(list.length(catalogues), "catalogue")
        <> summary(report),
      )
    _ -> Error(describe(report))
  }
}

fn add(settings: Settings, locale: String) -> Result(String, String) {
  use <- bool_guard(
    !catalogue.valid_locale(locale),
    "invalid locale " <> locale <> ": use a tag such as de or pt-BR",
  )
  let path = settings.locales <> "/" <> locale <> ".json"
  let source_path = settings.locales <> "/" <> settings.source <> ".json"
  use exists <- result.try(
    simplifile.is_file(path) |> result.replace_error("cannot read " <> path),
  )
  use <- bool_guard(exists, path <> " already exists")
  use text <- result.try(
    simplifile.read(source_path)
    |> result.replace_error("cannot read the source catalogue " <> source_path),
  )
  use source <- result.try(catalogue.decode_catalogue(
    settings.source,
    settings.source <> ".json",
    text,
  ))
  let body =
    [
      #("@@locale", locale),
      #("@@x-review", "untranslated: copied from " <> settings.source),
      ..source.messages
    ]
    |> list.map(fn(entry) {
      "  "
      <> json.to_string(json.string(entry.0))
      <> ": "
      <> json.to_string(json.string(entry.1))
    })
    |> string.join(",\n")
  simplifile.write(path, "{\n" <> body <> "\n}\n")
  |> result.map(fn(_) {
    "Wrote "
    <> path
    <> " with "
    <> plural(list.length(source.messages), "message")
    <> " to translate. Remove @@x-review once it is done."
  })
  |> result.map_error(fn(error) {
    "cannot write " <> path <> ": " <> simplifile.describe_error(error)
  })
}

fn file_name(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [name, ..] -> name
    [] -> path
  }
}

fn bool_guard(
  failed: Bool,
  message: String,
  next: fn() -> Result(a, String),
) -> Result(a, String) {
  case failed {
    True -> Error(message)
    False -> next()
  }
}

fn default_out() -> Result(String, String) {
  use toml <- result.try(
    simplifile.read("gleam.toml")
    |> result.replace_error("cannot read gleam.toml: pass --out=<file>"),
  )
  string.split(toml, "\n")
  |> list.find_map(fn(line) {
    case string.split_once(string.trim(line), "=") {
      Ok(#(key, value)) ->
        case string.trim(key) {
          "name" -> {
            let name =
              value
              |> string.split("#")
              |> list.first
              |> result.unwrap("")
              |> string.trim
              |> string.replace("\"", "")
              |> string.replace("'", "")
            Ok("src/" <> name <> "/messages.gleam")
          }
          _ -> Error(Nil)
        }
      Error(Nil) -> Error(Nil)
    }
  })
  |> result.replace_error("gleam.toml has no name: pass --out=<file>")
}

fn summary(report: Report) -> String {
  let section = fn(title, lines) {
    case lines {
      [] -> ""
      _ ->
        "\n\n"
        <> title
        <> ":\n"
        <> string.join(list.map(lines, fn(l) { "  " <> l }), "\n")
    }
  }
  section("Warnings", report.warnings) <> section("Notes", report.notes)
}

fn describe(report: Report) -> String {
  "The catalogues have "
  <> plural(list.length(report.errors), "error")
  <> ":\n"
  <> string.join(list.map(report.errors, fn(l) { "  " <> l }), "\n")
  <> summary(report)
}

fn plural(count: Int, noun: String) -> String {
  case count {
    1 -> "1 " <> noun
    _ -> string.inspect(count) <> " " <> noun <> "s"
  }
}
