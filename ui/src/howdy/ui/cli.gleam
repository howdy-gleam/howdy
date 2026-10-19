//// The `gleam run -m howdy/ui` command line.
////
//// - `list` shows what can be copied: components, blocks and theme presets.
//// - `search <words>` finds entries by name, description or category.
//// - `view <name>` shows an entry's description, what it depends on, and
////   its source.
//// - `add <name>...` copies entries into the project, by default under
////   `src/<app>/ui/`, with every component they depend on, and regenerates
////   `all.gleam` there so the export picks them up.
//// - `diff <name>...` compares a copy with the version it came from.
//// - `init` prepares a project: the directory, `all.gleam`, the packages
////   copies need, and optionally a theme preset.
//// - `registry` writes the catalogue as JSON and `llms.txt`, for tools and
////   for publishing a registry of your own.
//// - `export` bundles the app's islands into `priv/howdy_islands`, then
////   runs `gleam export erlang-shipment`.
//// - `islands` only bundles the islands, for builds that export
////   separately. Run it just before `gleam export erlang-shipment`.
////
//// Options: `--to=<dir>` chooses the directory, `--force` overwrites,
//// `--dry-run` shows what would change without changing it, `--install`
//// runs `gleam add` for missing packages, and `--registry=<url or dir>`
//// takes entries from another registry published with `registry`.

import gleam/bool
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import howdy/ui/internal/islands
import howdy/ui/registry
import simplifile

/// This package's version, written into every generated file. Read from
/// the loaded application, so it cannot drift from `gleam.toml`; the
/// constant is only for a raw Erlang caller that never loaded it.
pub fn version() -> String {
  case loaded_version() {
    Ok(version) -> version
    Error(Nil) -> fallback_version
  }
}

const fallback_version = "2.0.0"

@external(erlang, "howdy_ui_cli_ffi", "version")
fn loaded_version() -> Result(String, Nil)

/// Run a command and print what happened.
pub fn run(args: List(String)) -> Nil {
  case execute(args) {
    Ok(output) -> io.println(output)
    Error(message) -> {
      io.println_error(message)
      halt(1)
    }
  }
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

/// What a command wants done, before any file is touched.
pub type Options {
  Options(
    names: List(String),
    to: Option(String),
    force: Bool,
    dry_run: Bool,
    install: Bool,
    registry: Option(String),
    insecure: Bool,
    theme: Option(String),
    out: Option(String),
  )
}

/// Run a command and return its output, or the reason it could not.
pub fn execute(args: List(String)) -> Result(String, String) {
  case args {
    [command, ..rest] -> {
      use options <- result.try(parse(rest))
      case command {
        "list" -> list_entries(options)
        "search" -> search(options)
        "view" -> view(options)
        "add" -> add(options)
        "diff" -> diff(options)
        "init" -> init(options)
        "registry" -> publish(options)
        "islands" -> islands.bundle()
        "export" -> islands.export()
        _ -> Error(usage)
      }
    }
    [] -> Error(usage)
  }
}

const usage = "usage: gleam run -m howdy/ui <command>

  list                      show the components, blocks and themes you can copy
  search <words>            find entries by name, description or category
  view <name>               show an entry's details and source
  add <name>... [options]   copy entries, and what they depend on, into your project
  diff <name>... [options]  compare your copies with the versions they came from
  init [options]            prepare a project for copies
  registry [--out=<dir>]    write the catalogue as JSON and llms.txt
  export                    bundle the app's islands, then export a release
  islands                   bundle the app's islands, to export separately

options:
  --to=<dir>              where the copies live (default: src/<app>/ui)
  --force                 overwrite copies that differ
  --dry-run               show what would change, and change nothing
  --install               run `gleam add` for packages the copies need
  --registry=<url|dir>    take entries from a registry published with `registry`
  --insecure              allow a plain http:// registry
  --theme=<name>          with init, copy a theme preset
  --out=<dir>             with registry, where to write (default: registry)"

fn parse(args: List(String)) -> Result(Options, String) {
  let options =
    Options(
      names: [],
      to: None,
      force: False,
      dry_run: False,
      install: False,
      registry: None,
      insecure: False,
      theme: None,
      out: None,
    )
  list.try_fold(args, options, fn(options, arg) {
    case arg {
      "--force" -> Ok(Options(..options, force: True))
      "--dry-run" -> Ok(Options(..options, dry_run: True))
      "--install" -> Ok(Options(..options, install: True))
      "--to=" <> dir -> Ok(Options(..options, to: Some(dir)))
      "--registry=" <> source -> Ok(Options(..options, registry: Some(source)))
      "--insecure" -> Ok(Options(..options, insecure: True))
      "--theme=" <> name -> Ok(Options(..options, theme: Some(name)))
      "--out=" <> dir -> Ok(Options(..options, out: Some(dir)))
      "--" <> _ -> Error("unknown option " <> arg <> "\n\n" <> usage)
      name -> Ok(Options(..options, names: list.append(options.names, [name])))
    }
  })
}

fn names(options: Options) -> Result(List(String), String) {
  case options.names {
    [] -> Error("give at least one name\n\n" <> usage)
    names -> Ok(names)
  }
}

// -- Items -------------------------------------------------------------------

/// Something that can be copied: a built-in entry with its source, or an
/// entry from another registry.
pub type Item {
  Item(
    name: String,
    kind: String,
    category: String,
    description: String,
    module: String,
    source: String,
    dependencies: List(String),
    packages: List(String),
    /// Where it came from, for the header of a copy.
    origin: String,
  )
}

fn builtin(name: String) -> Result(Item, String) {
  use entry <- result.try(
    registry.find(name)
    |> result.replace_error(
      "unknown name "
      <> name
      <> ". Run `gleam run -m howdy/ui list` to see what is available.",
    ),
  )
  use source <- result.try(template(entry.module))
  Ok(Item(
    name: entry.name,
    kind: registry.kind_name(entry.kind),
    category: entry.category,
    description: registry.description(source),
    module: entry.module,
    source:,
    dependencies: registry.dependencies(source),
    packages: registry.packages(source),
    origin: "howdy_ui " <> version(),
  ))
}

/// An entry from `registry` if one is given, else a built-in one. An entry
/// in another registry may depend on built-in ones.
fn item(name: String, options: Options) -> Result(Item, String) {
  case options.registry {
    None -> builtin(name)
    Some(source) ->
      case remote(source, name, options) {
        Ok(item) -> Ok(item)
        Error(remote_error) ->
          builtin(name)
          |> result.replace_error(remote_error)
      }
  }
}

/// The named entries followed by, first, everything they depend on.
fn resolve(
  names: List(String),
  options: Options,
) -> Result(List(Item), String) {
  use #(items, _) <- result.try(
    list.try_fold(names, #([], []), fn(acc, name) { visit(name, options, acc) }),
  )
  Ok(list.reverse(items))
}

fn visit(
  name: String,
  options: Options,
  acc: #(List(Item), List(String)),
) -> Result(#(List(Item), List(String)), String) {
  let #(items, seen) = acc
  case list.contains(seen, name) {
    True -> Ok(acc)
    False -> {
      use item <- result.try(item(name, options))
      use #(items, seen) <- result.try(
        list.try_fold(item.dependencies, #(items, [name, ..seen]), fn(acc, dep) {
          visit(dep, options, acc)
        }),
      )
      Ok(#([item, ..items], seen))
    }
  }
}

// -- list, search and view ---------------------------------------------------

type Summary {
  Summary(name: String, kind: String, category: String, description: String)
}

fn summaries(options: Options) -> Result(List(Summary), String) {
  case options.registry {
    Some(source) -> remote_index(source, options)
    None ->
      registry.entries()
      |> list.map(fn(entry) {
        let description =
          template(entry.module)
          |> result.map(registry.description)
          |> result.unwrap("")
        Summary(
          name: entry.name,
          kind: registry.kind_name(entry.kind),
          category: entry.category,
          description:,
        )
      })
      |> Ok
  }
}

fn list_entries(options: Options) -> Result(String, String) {
  use summaries <- result.map(summaries(options))
  show_summaries(summaries)
}

fn show_summaries(summaries: List(Summary)) -> String {
  let width =
    list.fold(summaries, 0, fn(widest, summary) {
      int.max(widest, string.length(summary.name))
    })
    + 2
  summaries
  |> list.chunk(fn(summary) { summary.category })
  |> list.map(fn(group) {
    let assert [first, ..] = group
    [
      first.category,
      ..list.map(group, fn(summary) {
        "  "
        <> string.pad_end(summary.name, width, " ")
        <> registry.summary(summary.description)
      })
    ]
    |> string.join("\n")
  })
  |> string.join("\n\n")
}

fn search(options: Options) -> Result(String, String) {
  use words <- result.try(names(options))
  use summaries <- result.try(summaries(options))
  let words = list.map(words, string.lowercase)
  let found =
    list.filter(summaries, fn(summary) {
      let haystack =
        string.lowercase(
          summary.name <> " " <> summary.category <> " " <> summary.description,
        )
      list.all(words, string.contains(haystack, _))
    })
  case found {
    [] -> Ok("nothing matches " <> string.join(words, " "))
    found -> Ok(show_summaries(found))
  }
}

fn view(options: Options) -> Result(String, String) {
  use names <- result.try(names(options))
  use items <- result.try(list.try_map(names, item(_, options)))
  use dir <- result.map(target_dir(options))
  items
  |> list.map(fn(item) {
    let listed = fn(names) {
      case names {
        [] -> "none"
        names -> string.join(names, ", ")
      }
    }
    [
      item.name <> " (" <> item.kind <> ", " <> item.category <> ")",
      item.description,
      "",
      "depends on: " <> listed(item.dependencies),
      "packages:   " <> listed(item.packages),
      "adds:       " <> dir <> "/" <> item.name <> ".gleam",
      "",
      item.source,
    ]
    |> string.join("\n")
  })
  |> string.join("\n\n")
}

// -- add ---------------------------------------------------------------------

fn add(options: Options) -> Result(String, String) {
  use requested <- result.try(names(options))
  use dir <- result.try(target_dir(options))
  use items <- result.try(resolve(requested, options))
  let module_path = module_path(dir)
  let _ = case options.dry_run {
    True -> Ok(Nil)
    False -> simplifile.create_directory_all(dir)
  }
  use lines <- result.try(
    list.try_map(items, fn(item) {
      let is_requested = list.contains(requested, item.name)
      copy(item, items, dir, module_path, is_requested, options)
    }),
  )
  use index <- result.try(case options.dry_run {
    True -> Ok([])
    False -> write_index(dir) |> result.map(list.wrap)
  })
  use packages <- result.map(packages(
    list.unique(list.flat_map(items, fn(item) { item.packages })),
    options,
  ))
  string.join(list.flatten([lines, index, packages]), "\n")
}

fn copy(
  item: Item,
  items: List(Item),
  dir: String,
  module_path: String,
  is_requested: Bool,
  options: Options,
) -> Result(String, String) {
  let path = dir <> "/" <> item.name <> ".gleam"
  let fresh = generated(item, items, module_path)
  let would = case options.dry_run {
    True -> "would write "
    False -> "wrote "
  }
  let write = fn() {
    case options.dry_run {
      True -> Ok(would <> path)
      False ->
        simplifile.write(path, fresh)
        |> result.replace(would <> path)
        |> result.map_error(fn(error) {
          "could not write " <> path <> ": " <> string.inspect(error)
        })
    }
  }
  case simplifile.read(path), options.force {
    Ok(existing), _ if existing == fresh -> Ok(path <> " is up to date")
    Ok(existing), False ->
      case is_requested {
        True ->
          Ok(
            path
            <> " exists and differs from "
            <> item.origin
            <> "; left as is. Use --force to overwrite.\n"
            <> render_diff(path, existing, fresh, item.origin),
          )
        // A dependency you have edited is yours; the new copy uses it.
        False -> Ok(path <> " exists and differs; kept your version")
      }
    _, _ -> write()
  }
}

/// The file `add` writes: the source with a header, and its imports of
/// the entries it depends on pointed at the copies beside it.
pub fn generated(item: Item, items: List(Item), module_path: String) -> String {
  let header =
    "//// Generated by "
    <> item.origin
    <> " from `"
    <> item.module
    <> "`. This file is yours: edit it\n"
    <> "//// freely. `gleam run -m howdy/ui diff "
    <> item.name
    <> "` compares it with the version\n"
    <> "//// it came from.\n"
    <> "////\n"
  let source =
    list.fold(item.dependencies, item.source, fn(source, dep) {
      case list.find(items, fn(other) { other.name == dep }) {
        Ok(other) ->
          repoint(source, other.module, module_path <> "/" <> other.name)
        Error(Nil) -> source
      }
    })
  header <> source
}

/// Change `import from` to `import to`, whatever follows it.
fn repoint(source: String, from: String, to: String) -> String {
  source
  |> string.split("\n")
  |> list.map(fn(line) {
    case string.starts_with(line, "import " <> from) {
      True -> {
        let rest = string.drop_start(line, string.length("import " <> from))
        case rest {
          "" | "." <> _ | " " <> _ -> "import " <> to <> rest
          _ -> line
        }
      }
      False -> line
    }
  })
  |> string.join("\n")
}

/// Copies import the packages their sources do, so those must be direct
/// dependencies of the project. With `--install`, add them.
fn packages(
  needed: List(String),
  options: Options,
) -> Result(List(String), String) {
  let missing = case simplifile.read("gleam.toml") {
    Error(_) -> []
    Ok(toml) ->
      list.filter(needed, fn(package) { !has_dependency(toml, package) })
  }
  case missing, options.install, options.dry_run {
    [], _, _ -> Ok([])
    _, True, True -> Ok(["would run: gleam add " <> string.join(missing, " ")])
    _, True, False ->
      case run_program("gleam", ["add", ..missing]) {
        #(0, _) -> Ok(["added " <> string.join(missing, ", ")])
        #(_, output) -> Error("gleam add failed:\n" <> output)
      }
    _, False, _ ->
      Ok([
        "The copies import "
        <> string.join(missing, " and ")
        <> " directly. Add them with `gleam add "
        <> string.join(missing, " ")
        <> "`, or run again with --install.",
      ])
  }
}

fn has_dependency(toml: String, package: String) -> Bool {
  list.any(string.split(toml, "\n"), fn(line) {
    let line = string.trim(line)
    string.starts_with(line, package <> " ")
    || string.starts_with(line, package <> "=")
  })
}

@external(erlang, "howdy_ui_cli_ffi", "run")
fn run_program(program: String, args: List(String)) -> #(Int, String)

/// The `all.gleam` module: the classes of every module in the directory
/// that has a `classes` function, for `howdy/ui/export`.
fn write_index(dir: String) -> Result(String, String) {
  use files <- result.try(
    simplifile.read_directory(dir)
    |> result.map_error(fn(error) {
      "could not read " <> dir <> ": " <> string.inspect(error)
    }),
  )
  let modules =
    files
    |> list.filter(fn(file) {
      string.ends_with(file, ".gleam") && file != "all.gleam"
    })
    |> list.filter(fn(file) {
      case simplifile.read(dir <> "/" <> file) {
        Ok(source) -> string.contains(source, "pub fn classes()")
        Error(_) -> False
      }
    })
    |> list.map(string.drop_end(_, string.length(".gleam")))
    |> list.sort(string.compare)
  let module_path = module_path(dir)
  let imports =
    modules
    |> list.map(fn(name) { "import " <> module_path <> "/" <> name })
  let calls =
    modules
    |> list.map(fn(name) { "    " <> name <> ".classes()," })
  let source =
    string.join(
      list.flatten([
        [
          "//// Generated by howdy_ui " <> version() <> ". The classes of every",
          "//// component in this directory, for `howdy/ui/export`. Regenerated",
          "//// by `gleam run -m howdy/ui add`; do not edit.",
          "",
          "import gleam/list",
        ],
        imports,
        [
          "import sketch/css.{type Class}",
          "",
          "pub fn classes() -> List(Class) {",
          "  list.flatten([",
        ],
        calls,
        ["  ])", "}", ""],
      ]),
      "\n",
    )
  let path = dir <> "/all.gleam"
  case simplifile.write(path, source) {
    Ok(Nil) -> Ok("wrote " <> path)
    Error(error) ->
      Error("could not write " <> path <> ": " <> string.inspect(error))
  }
}

/// `src/my_app/ui` is the module path `my_app/ui`: everything after the
/// last `src/`.
fn module_path(dir: String) -> String {
  case string.split(strip_slash(dir), "src/") |> list.last {
    Ok(rest) -> rest
    Error(Nil) -> dir
  }
}

// -- diff --------------------------------------------------------------------

fn diff(options: Options) -> Result(String, String) {
  use requested <- result.try(names(options))
  use dir <- result.try(target_dir(options))
  use items <- result.try(resolve(requested, options))
  let module_path = module_path(dir)
  items
  |> list.filter(fn(item) { list.contains(requested, item.name) })
  |> list.map(fn(item) {
    let path = dir <> "/" <> item.name <> ".gleam"
    let fresh = generated(item, items, module_path)
    case simplifile.read(path) {
      Error(_) ->
        path <> " does not exist; `add " <> item.name <> "` would create it"
      Ok(existing) if existing == fresh -> path <> " matches " <> item.origin
      Ok(existing) -> render_diff(path, existing, fresh, item.origin)
    }
  })
  |> string.join("\n")
  |> Ok
}

fn render_diff(
  path: String,
  existing: String,
  fresh: String,
  origin: String,
) -> String {
  let from = case generated_by(existing) {
    Some(by) -> " (generated by " <> by <> ")"
    None -> ""
  }
  [
    "--- " <> path <> from,
    "+++ " <> origin,
    ..hunks(string.split(existing, "\n"), string.split(fresh, "\n"))
  ]
  |> string.join("\n")
}

fn generated_by(source: String) -> Option(String) {
  case source {
    "//// Generated by " <> rest ->
      rest
      |> string.split_once(" from `")
      |> result.map(fn(pair) { Some(pair.0) })
      |> result.unwrap(None)
    _ -> None
  }
}

// -- init --------------------------------------------------------------------

fn init(options: Options) -> Result(String, String) {
  use dir <- result.try(target_dir(options))
  let exists = simplifile.is_directory(dir) == Ok(True)
  use made <- result.try(case options.dry_run, exists {
    _, True -> Ok(dir <> " exists")
    True, False -> Ok("would create " <> dir)
    False, False ->
      simplifile.create_directory_all(dir)
      |> result.replace("created " <> dir)
      |> result.map_error(fn(error) {
        "could not create " <> dir <> ": " <> string.inspect(error)
      })
  })
  use theme <- result.try(case options.theme {
    None -> Ok([])
    Some(name) ->
      add(Options(..options, names: [name]))
      |> result.map(fn(output) { [output] })
  })
  use index <- result.try(case options.dry_run, options.theme {
    True, _ -> Ok(["would write " <> dir <> "/all.gleam"])
    // Adding the theme wrote the index already.
    False, Some(_) -> Ok([])
    False, None -> write_index(dir) |> result.map(list.wrap)
  })
  use packages <- result.map(packages(["lustre", "sketch"], options))
  let module_path = module_path(dir)
  let next = [
    "",
    "Next:",
    "  gleam run -m howdy/ui list          see what you can copy",
    "  gleam run -m howdy/ui add button    copy a component into " <> dir,
    case options.theme {
      Some(name) ->
        "  page.themes(" <> module_path <> "/" <> name <> ".themes())"
      None -> "  gleam run -m howdy/ui init --theme=zinc   start from a preset"
    },
    "  export.classes(" <> module_path <> "/all.classes())   publish the CSS",
  ]
  string.join(list.flatten([[made], theme, index, packages, next]), "\n")
}

// -- registry ----------------------------------------------------------------

/// Write `index.json`, one `<name>.json` per entry with its source, and
/// `llms.txt`. Serve the directory, and `--registry=<its url>` installs
/// from it.
fn publish(options: Options) -> Result(String, String) {
  let out = strip_slash(option.unwrap(options.out, "registry"))
  use items <- result.try(
    list.try_map(registry.entries(), fn(entry) { builtin(entry.name) }),
  )
  let files = [
    #("index.json", json.to_string(index_json(items))),
    #("llms.txt", llms(items)),
    ..list.map(items, fn(item) {
      #(item.name <> ".json", json.to_string(item_json(item)))
    })
  ]
  case options.dry_run {
    True ->
      Ok(
        files
        |> list.map(fn(file) { "would write " <> out <> "/" <> file.0 })
        |> string.join("\n"),
      )
    False -> {
      use _ <- result.try(
        simplifile.create_directory_all(out)
        |> result.map_error(fn(error) {
          "could not create " <> out <> ": " <> string.inspect(error)
        }),
      )
      use _ <- result.map(
        list.try_each(files, fn(file) {
          simplifile.write(out <> "/" <> file.0, file.1)
          |> result.map_error(fn(error) {
            "could not write " <> file.0 <> ": " <> string.inspect(error)
          })
        }),
      )
      "wrote "
      <> int.to_string(list.length(files))
      <> " files to "
      <> out
      <> ": index.json, llms.txt and one JSON file per entry"
    }
  }
}

fn index_json(items: List(Item)) -> json.Json {
  json.object([
    #("name", json.string("howdy_ui")),
    #("version", json.string(version())),
    #(
      "items",
      json.array(items, fn(item) {
        json.object([
          #("name", json.string(item.name)),
          #("kind", json.string(item.kind)),
          #("category", json.string(item.category)),
          #("description", json.string(item.description)),
          #("dependencies", json.array(item.dependencies, json.string)),
        ])
      }),
    ),
  ])
}

pub fn item_json(item: Item) -> json.Json {
  json.object([
    #("name", json.string(item.name)),
    #("kind", json.string(item.kind)),
    #("category", json.string(item.category)),
    #("description", json.string(item.description)),
    #("module", json.string(item.module)),
    #("dependencies", json.array(item.dependencies, json.string)),
    #("packages", json.array(item.packages, json.string)),
    #("source", json.string(item.source)),
  ])
}

fn llms(items: List(Item)) -> String {
  let entries =
    items
    |> list.chunk(fn(item) { item.category })
    |> list.map(fn(group) {
      let assert [first, ..] = group
      [
        "## " <> first.category,
        "",
        ..list.map(group, fn(item) {
          "- ["
          <> item.name
          <> "]("
          <> item.name
          <> ".json): "
          <> item.description
          <> " Module `"
          <> item.module
          <> "`; copy with `gleam run -m howdy/ui add "
          <> item.name
          <> "`."
        })
      ]
      |> string.join("\n")
    })
  string.join(
    [
      "# howdy_ui " <> version(),
      "",
      "> Pages, themes, components and live server components for the howdy web framework, in Gleam, built on Lustre and Sketch.",
      "",
      "- Every component is a function returning a Lustre element, styled with Sketch classes built from theme tokens (`howdy/ui/theme/tokens`); never name a colour directly.",
      "- `howdy/ui` re-exports the components; each also lives in its own module, and blocks and themes are separate modules.",
      "- `howdy/ui/page` renders a document with the theme, CSS and the behaviour script; `howdy/ui/live` serves Lustre server components over WebSockets.",
      "- Interactive components use native HTML (dialog, popover, details) plus `howdy/ui/behaviour`, which works inside live views. A live view reads a select, combobox or calendar with `live.on_value`.",
      "- Copies made with `add` depend only on `howdy/ui/style` and tokens; blocks import the copies of the components they use.",
      "- Each JSON file linked below holds the entry's full source.",
      "",
      ..entries
    ],
    "\n",
  )
  <> "\n"
}

// -- Other registries --------------------------------------------------------

fn fetch_text(
  source: String,
  file: String,
  options: Options,
) -> Result(String, String) {
  let location = strip_slash(source) <> "/" <> file
  case
    string.starts_with(source, "https://"),
    string.starts_with(source, "http://")
  {
    False, True if !options.insecure -> Error(plaintext_refused(source))
    True, _ | _, True ->
      fetch(location)
      |> result.map_error(fn(reason) {
        "could not fetch " <> location <> ": " <> reason
      })
    False, False ->
      simplifile.read(location)
      |> result.map_error(fn(_) { "could not read " <> location })
  }
}

/// Code copied from a registry runs in the project, so it is only fetched
/// over a connection that cannot be altered in transit unless asked.
fn plaintext_refused(source: String) -> String {
  "refusing to fetch code from "
  <> source
  <> " over plain http: it could be altered in transit.\n"
  <> "Use an https:// registry, or pass --insecure to accept the risk."
}

@external(erlang, "howdy_ui_cli_ffi", "fetch")
fn fetch(url: String) -> Result(String, String)

fn remote(
  source: String,
  name: String,
  options: Options,
) -> Result(Item, String) {
  use text <- result.try(fetch_text(source, name <> ".json", options))
  let decoder = {
    use name <- decode.field("name", decode.string)
    use kind <- decode.optional_field("kind", "component", decode.string)
    use category <- decode.optional_field("category", "Other", decode.string)
    use description <- decode.optional_field("description", "", decode.string)
    use module <- decode.field("module", decode.string)
    use dependencies <- decode.optional_field(
      "dependencies",
      [],
      decode.list(decode.string),
    )
    use packages <- decode.optional_field(
      "packages",
      [],
      decode.list(decode.string),
    )
    use source_text <- decode.field("source", decode.string)
    decode.success(Item(
      name:,
      kind:,
      category:,
      description:,
      module:,
      source: source_text,
      dependencies:,
      packages:,
      origin: source,
    ))
  }
  json.parse(text, decoder)
  |> result.map_error(fn(_) {
    source <> "/" <> name <> ".json is not a registry entry"
  })
}

fn remote_index(
  source: String,
  options: Options,
) -> Result(List(Summary), String) {
  use text <- result.try(fetch_text(source, "index.json", options))
  let summary = {
    use name <- decode.field("name", decode.string)
    use kind <- decode.optional_field("kind", "component", decode.string)
    use category <- decode.optional_field("category", "Other", decode.string)
    use description <- decode.optional_field("description", "", decode.string)
    decode.success(Summary(name:, kind:, category:, description:))
  }
  json.parse(text, decode.at(["items"], decode.list(summary)))
  |> result.map_error(fn(_) { source <> "/index.json is not a registry index" })
}

// -- Templates ---------------------------------------------------------------

/// The shipped source of a module: from the project's build directory for
/// a hex dependency, from the path in `manifest.toml` for a path
/// dependency, or from `src` when developing howdy_ui itself.
pub fn template(module: String) -> Result(String, String) {
  let file = module <> ".gleam"
  [
    Some("build/packages/howdy_ui/src/" <> file),
    option.map(local_package_path(), fn(root) { root <> "/src/" <> file }),
    Some("src/" <> file),
  ]
  |> option.values
  |> list.find_map(simplifile.read)
  |> result.map_error(fn(_) {
    "could not find " <> file <> ". Is howdy_ui a dependency and built?"
  })
}

/// The `path` of howdy_ui in `manifest.toml`, when it is a path dependency.
fn local_package_path() -> Option(String) {
  use manifest <- option.then(
    option.from_result(simplifile.read("manifest.toml")),
  )
  manifest
  |> string.split("\n")
  |> list.find(fn(line) { string.contains(line, "name = \"howdy_ui\"") })
  |> option.from_result
  |> option.then(fn(line) {
    case string.split_once(line, "path = \"") {
      Ok(#(_, rest)) ->
        string.split_once(rest, "\"")
        |> option.from_result
        |> option.map(fn(pair) { pair.0 })
      Error(Nil) -> None
    }
  })
}

fn target_dir(options: Options) -> Result(String, String) {
  case options.to {
    Some(dir) -> Ok(strip_slash(dir))
    None -> {
      use name <- result.try(app_name())
      Ok("src/" <> name <> "/ui")
    }
  }
}

fn strip_slash(dir: String) -> String {
  case string.ends_with(dir, "/") {
    True -> strip_slash(string.drop_end(dir, 1))
    False -> dir
  }
}

fn app_name() -> Result(String, String) {
  use toml <- result.try(
    simplifile.read("gleam.toml")
    |> result.map_error(fn(_) {
      "could not read gleam.toml; run this from the project root or pass --to=<dir>"
    }),
  )
  toml
  |> string.split("\n")
  |> list.find_map(fn(line) {
    case string.split_once(line, "=") {
      Ok(#(key, value)) if key == "name " || key == "name" ->
        Ok(string.trim(value) |> string.replace("\"", ""))
      _ -> Error(Nil)
    }
  })
  |> result.map_error(fn(_) { "gleam.toml has no name; pass --to=<dir>" })
}

// -- Line diff ---------------------------------------------------------------

/// Changed regions with two lines of context, in unified style.
fn hunks(old: List(String), new: List(String)) -> List(String) {
  let edits = edits(old, new)
  let context = 2
  // Which edit indices are within `context` of a change.
  let changed =
    list.index_map(edits, fn(edit, i) {
      case edit {
        Keep(_) -> None
        _ -> Some(i)
      }
    })
    |> option.values
  use <- bool.guard(when: changed == [], return: ["(no differences)"])
  let near = fn(i) {
    list.any(changed, fn(c) { int.absolute_value(c - i) <= context })
  }
  edits
  |> list.index_map(fn(edit, i) { #(edit, near(i)) })
  |> list.fold(#([], False), fn(acc, pair) {
    let #(lines, was_near) = acc
    let #(edit, is_near) = pair
    case is_near, was_near {
      False, True -> #(["...", ..lines], False)
      False, False -> #(lines, False)
      True, _ -> #([render_edit(edit), ..lines], True)
    }
  })
  |> fn(acc) { acc.0 }
  |> list.reverse
}

type Edit {
  Keep(String)
  Remove(String)
  Insert(String)
}

fn render_edit(edit: Edit) -> String {
  case edit {
    Keep(line) -> " " <> line
    Remove(line) -> "-" <> line
    Insert(line) -> "+" <> line
  }
}

/// A shortest edit script by longest common subsequence, in linear space
/// (Hirschberg): split the old lines in half, find where the new lines
/// split to match from LCS lengths computed forwards and backwards, and
/// recurse on each half.
fn edits(old: List(String), new: List(String)) -> List(Edit) {
  case old, new {
    [], _ -> list.map(new, Insert)
    _, [] -> list.map(old, Remove)
    [line], _ ->
      case list.split_while(new, fn(other) { other != line }) {
        #(before, [_, ..after]) ->
          list.flatten([
            list.map(before, Insert),
            [Keep(line)],
            list.map(after, Insert),
          ])
        #(_, []) -> [Remove(line), ..list.map(new, Insert)]
      }
    _, _ -> {
      let #(old_head, old_tail) = list.split(old, list.length(old) / 2)
      let forward = lcs_lengths(old_head, new)
      let backward =
        lcs_lengths(list.reverse(old_tail), list.reverse(new)) |> list.reverse
      let #(new_head, new_tail) = list.split(new, best_split(forward, backward))
      list.append(edits(old_head, new_head), edits(old_tail, new_tail))
    }
  }
}

/// The LCS length of `xs` and each prefix of `ys`: `m + 1` numbers, from
/// the empty prefix to all of `ys`.
fn lcs_lengths(xs: List(String), ys: List(String)) -> List(Int) {
  let empty = list.map([[], ..list.map(ys, fn(_) { [] })], fn(_) { 0 })
  use previous, x <- list.fold(xs, empty)
  let assert [diagonal, ..above] = previous
  next_row(x, ys, diagonal, above, 0, [0])
}

fn next_row(
  x: String,
  ys: List(String),
  diagonal: Int,
  above: List(Int),
  left: Int,
  acc: List(Int),
) -> List(Int) {
  case ys, above {
    [y, ..ys], [up, ..above] -> {
      let value = case x == y {
        True -> diagonal + 1
        False -> int.max(up, left)
      }
      next_row(x, ys, up, above, value, [value, ..acc])
    }
    _, _ -> list.reverse(acc)
  }
}

/// The index into the new lines where the two halves meet: the first
/// point with the greatest combined LCS length.
fn best_split(forward: List(Int), backward: List(Int)) -> Int {
  list.zip(forward, backward)
  |> list.index_map(fn(pair, i) { #(pair.0 + pair.1, i) })
  |> list.fold(#(-1, 0), fn(best, candidate) {
    case candidate.0 > best.0 {
      True -> candidate
      False -> best
    }
  })
  |> fn(best) { best.1 }
}
