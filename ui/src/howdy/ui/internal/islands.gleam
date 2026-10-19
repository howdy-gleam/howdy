//// Serving, building and bundling the browser code for `howdy/ui/island`.
////
//// Islands live in the app's own package, but that package also holds
//// server code that cannot compile for JavaScript. So the islands are
//// built in a hidden package, `build/howdy_islands`, whose `src` links to
//// the island modules and the app modules they import, and nothing else.
//// It shares the app's dependency versions and downloaded packages.
////
//// In development every request for the boot module rebuilds that
//// package first. Gleam skips the work when nothing changed, so the code
//// served always matches the source, under `gleam run` and `gleam dev`.
////
//// A release has no compiler, so `gleam run -m howdy/ui islands` bundles
//// the islands into `priv/howdy_islands` first. Its manifest records a
//// fingerprint of every module the islands were built from, and a release
//// refuses a bundle whose fingerprints differ from the running code.

import filepath
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import howdy/content.{type Content}
import howdy/controller.{type Controller, type GuardedContext}
import howdy/static
import simplifile

const prefix = "/_howdy/islands"

const hidden = "build/howdy_islands"

const output = "build/howdy_islands/build/dev/javascript"

const bundle_directory = "priv/howdy_islands"

const bundle_command = "gleam run -m howdy/ui islands"

/// The controller answering under `/_howdy/islands`.
pub fn controller() -> Controller {
  // A release checks its bundle as it starts, so a missing or stale one
  // is in the startup log rather than waiting for the first page view.
  case development() {
    True -> Nil
    False -> {
      let _ = release_boot()
      Nil
    }
  }
  controller.new(prefix)
  |> controller.get("/*path", fn(ctx) {
    let development = development()
    case controller.param(ctx, "path"), development {
      Ok("boot.mjs"), True -> javascript(ctx, development_boot())
      Ok("boot.mjs"), False -> javascript(ctx, release_boot())
      Ok(path), True -> file(ctx, output, path, "no-cache")
      Ok(path), False ->
        case bundle_root() {
          Ok(root) ->
            file(ctx, root, path, "public, max-age=31536000, immutable")
          Error(Nil) -> controller.status(ctx, 404)
        }
      Error(Nil), _ -> controller.status(ctx, 404)
    }
  })
}

fn development_boot() -> String {
  case build() {
    Ok(_) ->
      "import { boot } from '"
      <> prefix
      <> "/howdy_ui/howdy/ui/island.ffi.mjs';\nboot('"
      <> prefix
      <> "/', { overlay: true });\n"
    Error(output) -> failed(output, overlay: True)
  }
}

// The answer cannot change while the release runs, so work it out once.
fn release_boot() -> String {
  case cached_boot() {
    Ok(script) -> script
    Error(Nil) -> {
      let script = case release_manifest() {
        Ok(manifest) ->
          "import { boot } from '"
          <> prefix
          <> "/"
          <> manifest.boot
          <> "';\nboot('"
          <> prefix
          <> "/', { overlay: false, modules: "
          <> json.to_string(json.dict(
            manifest.modules,
            fn(key) { key },
            json.string,
          ))
          <> " });\n"
        Error(problem) -> {
          log_error("howdy islands: " <> problem)
          failed(problem, overlay: False)
        }
      }
      cache_boot(script)
      script
    }
  }
}

fn file(
  ctx: GuardedContext(guarded),
  root: String,
  path: String,
  cache: String,
) -> Response(Content) {
  let segments = string.split(path, "/")
  let unsafe =
    list.any(segments, fn(segment) {
      segment == ".." || segment == "." || segment == ""
    })
  use <- bool.guard(unsafe, controller.status(ctx, 404))
  static.file(ctx, root <> "/" <> path)
  |> response.set_header("cache-control", cache)
}

fn javascript(
  ctx: GuardedContext(guarded),
  script: String,
) -> Response(Content) {
  controller.text(ctx, script)
  |> response.set_header("content-type", "text/javascript; charset=utf-8")
  |> response.set_header("cache-control", "no-store")
}

// Self-contained, because a failed build may have left no boot code. A
// release only logs to the console: its visitors cannot fix anything.
fn failed(message: String, overlay overlay: Bool) -> String {
  let message = json.to_string(json.string("howdy islands: " <> message))
  case overlay {
    False -> "console.error(" <> message <> ");\n"
    True -> "const m = " <> message <> ";
console.error(m);
const d = document.createElement('div');
d.dataset.howdyIslandsErrors = '';
d.textContent = m;
d.setAttribute('style', 'position:fixed;inset:auto 1rem 1rem 1rem;max-height:60vh;overflow:auto;z-index:2147483647;padding:1rem;background:#7f1d1d;color:#fff;font:13px/1.45 ui-monospace,monospace;border-radius:.5rem;white-space:pre-wrap');
document.body.append(d);
"
  }
}

// -- Releases ----------------------------------------------------------------

type Manifest {
  Manifest(
    boot: String,
    modules: Dict(String, String),
    fingerprints: Dict(String, String),
  )
}

fn manifest_decoder() -> decode.Decoder(Manifest) {
  use boot <- decode.field("boot", decode.string)
  use modules <- decode.field(
    "modules",
    decode.dict(decode.string, decode.string),
  )
  use fingerprints <- decode.field(
    "fingerprints",
    decode.dict(decode.string, decode.string),
  )
  decode.success(Manifest(boot:, modules:, fingerprints:))
}

/// The bundle's manifest, if there is one and it was built from the code
/// that is running.
fn release_manifest() -> Result(Manifest, String) {
  use root <- result.try(
    bundle_root()
    |> result.replace_error(
      "this release has no islands bundle. Run `"
      <> bundle_command
      <> "` before exporting it.",
    ),
  )
  use text <- result.try(read(root <> "/manifest.json"))
  use manifest <- result.try(
    json.parse(text, manifest_decoder())
    |> result.replace_error("could not read " <> root <> "/manifest.json"),
  )
  let stale =
    dict.to_list(manifest.fingerprints)
    |> list.filter(fn(pair) { fingerprint(pair.0) != Ok(pair.1) })
    |> list.map(fn(pair) { string.replace(pair.0, "@", "/") })
  case stale {
    [] -> Ok(manifest)
    _ ->
      Error(
        "the islands bundle was built from different code than this release runs (changed: "
        <> string.join(stale, ", ")
        <> "). Run `"
        <> bundle_command
        <> "` again, then export.",
      )
  }
}

// -- Building ----------------------------------------------------------------

/// What a build produced: the package name, the island modules, and every
/// app module compiled with them.
type Built {
  Built(root: String, name: String, islands: List(String), modules: Set(String))
}

fn build() -> Result(Built, String) {
  use root <- result.try(
    simplifile.current_directory()
    |> result.replace_error("could not read the working directory"),
  )
  use toml <- result.try(read("gleam.toml"))
  use name <- result.try(package_name(toml))
  let islands = "src/" <> name <> "/islands"
  use files <- result.try(
    simplifile.get_files(islands)
    |> result.replace_error("no island modules found in " <> islands),
  )
  let entries =
    files
    |> list.filter(string.ends_with(_, ".gleam"))
    |> list.map(module_of)
    |> list.sort(string.compare)
  use <- bool.guard(
    entries == [],
    Error("no island modules found in " <> islands),
  )
  let modules = reachable(entries, set.new())
  use manifest <- result.try(read("manifest.toml"))
  use Nil <- result.try(sync(root, toml, manifest, modules))
  let #(status, printed) = build_javascript(hidden)
  case status {
    0 -> Ok(Built(root:, name:, islands: entries, modules:))
    _ -> Error(explain(string.replace(printed, root <> "/" <> hidden, root)))
  }
}

// -- Bundling ----------------------------------------------------------------

/// Build the islands, bundle them into `priv/howdy_islands` and describe
/// what was written. Run from the project root, with the app compiled for
/// Erlang, so the modules' fingerprints can be read.
pub fn bundle() -> Result(String, String) {
  use built <- result.try(build())
  use esbuild <- result.try(esbuild())
  let boot_entry = output <> "/howdy_ui/howdy/ui/island.ffi.mjs"
  let island_entries =
    list.map(built.islands, fn(module) {
      #(module, output <> "/" <> built.name <> "/" <> module <> ".mjs")
    })
  let _ = simplifile.delete(bundle_directory)
  let _ = simplifile.create_directory_all(bundle_directory)
  let metafile = hidden <> "/meta.json"
  let args = [
    boot_entry,
    ..list.map(island_entries, fn(entry) { entry.1 })
    |> list.append([
      "--bundle",
      "--splitting",
      "--format=esm",
      "--minify",
      "--log-level=warning",
      "--outbase=" <> output,
      "--outdir=" <> bundle_directory,
      "--entry-names=[dir]/[name]-[hash]",
      "--chunk-names=chunks/[name]-[hash]",
      "--metafile=" <> metafile,
    ])
  ]
  let #(status, printed) = run(esbuild, args)
  use <- bool.guard(status != 0, Error("esbuild failed:\n" <> printed))
  use meta <- result.try(read(metafile))
  use outputs <- result.try(
    json.parse(meta, metafile_decoder())
    |> result.replace_error("could not read esbuild's metafile"),
  )
  // Entry point -> the file written for it, relative to the bundle.
  let written =
    dict.to_list(outputs)
    |> list.filter_map(fn(pair) {
      case pair.1 {
        option.Some(entry) ->
          Ok(#(
            entry,
            string.drop_start(pair.0, string.length(bundle_directory) + 1),
          ))
        option.None -> Error(Nil)
      }
    })
    |> dict.from_list
  use boot <- result.try(
    dict.get(written, boot_entry)
    |> result.replace_error("esbuild wrote no boot module"),
  )
  use modules <- result.try(
    list.try_map(island_entries, fn(entry) {
      dict.get(written, entry.1)
      |> result.map(fn(file) { #(entry.0, file) })
      |> result.replace_error("esbuild wrote nothing for " <> entry.0)
    }),
  )
  use fingerprints <- result.try(
    set.to_list(built.modules)
    |> list.sort(string.compare)
    |> list.try_map(fn(module) {
      let module = string.replace(module, "/", "@")
      fingerprint(module)
      |> result.map(fn(print) { #(module, print) })
      |> result.replace_error(
        "could not find the compiled Erlang module "
        <> module
        <> ". Run this from the project root with `gleam run -m howdy/ui islands`.",
      )
    }),
  )
  let manifest =
    json.object([
      #("boot", json.string(boot)),
      #(
        "modules",
        json.object(list.map(modules, fn(m) { #(m.0, json.string(m.1)) })),
      ),
      #(
        "fingerprints",
        json.object(list.map(fingerprints, fn(f) { #(f.0, json.string(f.1)) })),
      ),
    ])
  use Nil <- result.try(
    simplifile.write(
      bundle_directory <> "/manifest.json",
      json.to_string(manifest),
    )
    |> result.replace_error(
      "could not write " <> bundle_directory <> "/manifest.json",
    ),
  )
  Ok(describe(outputs))
}

fn metafile_decoder() -> decode.Decoder(Dict(String, Option(String))) {
  decode.at(
    ["outputs"],
    decode.dict(
      decode.string,
      decode.optional_field(
        "entryPoint",
        option.None,
        decode.optional(decode.string),
        decode.success,
      ),
    ),
  )
}

fn describe(outputs: Dict(String, Option(String))) -> String {
  let files =
    dict.keys(outputs)
    |> list.sort(string.compare)
    |> list.map(fn(path) {
      let size = case simplifile.file_info(path) {
        Ok(info) if info.size < 1024 -> int.to_string(info.size) <> " B"
        Ok(info) -> int.to_string(info.size / 1024) <> " KB"
        Error(_) -> "?"
      }
      "  " <> path <> "  " <> size
    })
  "Bundled islands into "
  <> bundle_directory
  <> ":\n"
  <> string.join(files, "\n")
  <> "\n  "
  <> bundle_directory
  <> "/manifest.json\n\n`gleam export erlang-shipment` includes them. A release serves them from /_howdy/islands."
}

fn read(path: String) -> Result(String, String) {
  simplifile.read(path) |> result.replace_error("could not read " <> path)
}

fn package_name(toml: String) -> Result(String, String) {
  string.split(toml, "\n")
  |> list.find_map(fn(line) {
    case string.split_once(line, "=") {
      Ok(#(key, value)) if key == "name" || key == "name " ->
        case string.trim(value) {
          "\"" <> rest ->
            string.split_once(rest, "\"") |> result.map(fn(pair) { pair.0 })
          _ -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
  |> result.replace_error("could not find the package name in gleam.toml")
}

// "src/app/islands/counter.gleam" -> "app/islands/counter"
fn module_of(path: String) -> String {
  path
  |> string.drop_start(string.length("src/"))
  |> string.drop_end(string.length(".gleam"))
}

/// The modules `pending` import from the app's own sources, transitively,
/// with themselves.
fn reachable(pending: List(String), found: Set(String)) -> Set(String) {
  case pending {
    [] -> found
    [module, ..rest] ->
      case set.contains(found, module) {
        True -> reachable(rest, found)
        False -> {
          let found = set.insert(found, module)
          let imports = case simplifile.read("src/" <> module <> ".gleam") {
            Ok(source) -> local_imports(source)
            Error(_) -> []
          }
          reachable(list.append(imports, rest), found)
        }
      }
  }
}

fn local_imports(source: String) -> List(String) {
  string.split(source, "\n")
  |> list.filter_map(fn(line) {
    case string.trim_start(line) {
      "import " <> rest -> {
        let module = take_module(string.trim_start(rest), "")
        case simplifile.is_file("src/" <> module <> ".gleam") {
          Ok(True) -> Ok(module)
          _ -> Error(Nil)
        }
      }
      _ -> Error(Nil)
    }
  })
}

// The module path at the start of an import, up to `.{`, ` as` or the end.
fn take_module(rest: String, taken: String) -> String {
  case string.pop_grapheme(rest) {
    Ok(#(char, rest)) ->
      case char {
        " " | "." | "\t" | "\r" -> taken
        _ -> take_module(rest, taken <> char)
      }
    Error(Nil) -> taken
  }
}

/// Bring the hidden package up to date: its config mirrors the app's, its
/// `src` links to exactly the modules wanted plus the app's JavaScript FFI
/// files, and it reuses the app's downloaded packages.
fn sync(
  root: String,
  toml: String,
  manifest: String,
  modules: Set(String),
) -> Result(Nil, String) {
  let wanted =
    set.to_list(modules)
    |> list.map(fn(module) { module <> ".gleam" })
    |> list.append(javascript_ffi())
    |> set.from_list
  let src = hidden <> "/src"
  let _ = simplifile.create_directory_all(src)
  let _ = simplifile.create_directory_all(hidden <> "/build")
  use Nil <- result.try(write_if_changed(
    hidden <> "/gleam.toml",
    absolute_paths(toml, root),
  ))
  use Nil <- result.try(write_if_changed(
    hidden <> "/manifest.toml",
    absolute_paths(manifest, root),
  ))
  let packages = hidden <> "/build/packages"
  let _ = case simplifile.link_info(packages) {
    Ok(_) -> Ok(Nil)
    Error(_) ->
      simplifile.create_symlink(to: root <> "/build/packages", from: packages)
  }
  let existing =
    simplifile.get_files(src)
    |> result.unwrap([])
    |> list.map(string.drop_start(_, string.length(src) + 1))
    |> set.from_list
  set.difference(existing, wanted)
  |> set.each(fn(path) { simplifile.delete(src <> "/" <> path) })
  set.difference(wanted, existing)
  |> set.to_list
  |> list.try_each(fn(path) {
    let link = src <> "/" <> path
    let _ = simplifile.create_directory_all(filepath.directory_name(link))
    simplifile.create_symlink(to: root <> "/src/" <> path, from: link)
    |> result.replace_error("could not link " <> link)
  })
}

// Every .mjs file under src, relative to it. Island modules may use them
// as FFI; unused ones cost nothing.
fn javascript_ffi() -> List(String) {
  simplifile.get_files("src")
  |> result.unwrap([])
  |> list.filter(string.ends_with(_, ".mjs"))
  |> list.map(string.drop_start(_, string.length("src/")))
}

fn write_if_changed(path: String, contents: String) -> Result(Nil, String) {
  case simplifile.read(path) {
    Ok(current) if current == contents -> Ok(Nil)
    _ ->
      simplifile.write(path, contents)
      |> result.replace_error("could not write " <> path)
  }
}

// Path dependencies are relative to the app; the hidden package lives two
// directories deeper.
fn absolute_paths(toml: String, root: String) -> String {
  let assert [first, ..rest] = string.split(toml, "path = \"")
  list.fold(rest, first, fn(acc, part) {
    let part = case string.split_once(part, "\"") {
      Ok(#("/" <> _, _)) -> part
      Ok(#(path, after)) ->
        result.unwrap(filepath.expand(root <> "/" <> path), path)
        <> "\""
        <> after
      Error(Nil) -> part
    }
    acc <> "path = \"" <> part
  })
}

fn explain(output: String) -> String {
  let output =
    string.split(output, "\n")
    |> list.filter(fn(line) {
      !string.starts_with(string.trim_start(line), "Compiling ")
      && !string.starts_with(string.trim_start(line), "Downloading ")
    })
    |> string.join("\n")
    |> string.trim
  case string.contains(output, "Unsupported target") {
    False -> output
    True ->
      string.replace(
        output,
        "Hint: Did you mean to build for a different target?",
        "",
      )
      |> string.trim
      <> "\nIsland modules, and the app modules they import, are compiled for JavaScript, so every function in them must run in a browser. Move server-only code out of modules that islands import."
  }
}

@external(erlang, "howdy_ui_island_ffi", "build_javascript")
fn build_javascript(directory: String) -> #(Int, String)

@external(erlang, "howdy_ui_island_ffi", "development")
fn development() -> Bool

@external(erlang, "howdy_ui_island_ffi", "bundle_root")
fn bundle_root() -> Result(String, Nil)

@external(erlang, "howdy_ui_island_ffi", "fingerprint")
fn fingerprint(module: String) -> Result(String, Nil)

@external(erlang, "howdy_ui_island_ffi", "esbuild")
fn esbuild() -> Result(String, String)

@external(erlang, "howdy_ui_island_ffi", "run")
fn run(executable: String, args: List(String)) -> #(Int, String)

@external(erlang, "howdy_ui_island_ffi", "cached_boot")
fn cached_boot() -> Result(String, Nil)

@external(erlang, "howdy_ui_island_ffi", "cache_boot")
fn cache_boot(script: String) -> Nil

@external(erlang, "howdy_ui_island_ffi", "log_error")
fn log_error(message: String) -> Nil
