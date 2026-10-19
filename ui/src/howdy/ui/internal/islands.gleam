//// Serving, building and bundling the browser code for `howdy/ui/island`.
////
//// Islands live in the app's own package, but that package also holds
//// server code that cannot compile for JavaScript. So the islands are
//// built in a hidden package, `build/howdy_islands`, whose `src` links to
//// the island modules and the app modules they import, and nothing else.
//// It shares the app's dependency versions and downloaded packages.
////
//// Islands are the modules in any directory called `islands`, in the app
//// and in every dependency that depends on howdy_ui, so a package can ship
//// islands for apps to mount.
////
//// In development every request for the boot module rebuilds that
//// package first. Gleam skips the work when nothing changed, so the code
//// served always matches the source, under `gleam run` and `gleam dev`.
////
//// A release has no compiler, so `gleam run -m howdy/ui islands` bundles
//// the islands into `priv/howdy_islands` first. Its manifest records, for
//// every package with code in the bundle, the package's version and a
//// fingerprint of each module the bundle was built from, plus the
//// package's Erlang FFI, which shapes what the server renders. A release
//// refuses a bundle that differs from the code it runs.
////
//// A release holds no JavaScript sources, so an edit to a JavaScript FFI
//// file alone in the app or a path dependency cannot be seen from it.
//// `gleam run -m howdy/ui export` bundles and exports in one step, so
//// nothing can change in between.

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
import howdy/ui/island
import simplifile

const prefix = "/_howdy/islands"

const hidden = "build/howdy_islands"

const output = "build/howdy_islands/build/dev/javascript"

const bundle_directory = "priv/howdy_islands"

const bundle_command = "gleam run -m howdy/ui islands"

// What a release that cannot use its bundle should do instead.
const export_advice = "Export it with `gleam run -m howdy/ui export`, which bundles the islands first."

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
    fingerprints: Dict(String, Fingerprint),
  )
}

/// What a bundle was built from, in one package: its version and the
/// MD5 of each compiled Erlang module that matters.
type Fingerprint {
  Fingerprint(version: String, modules: Dict(String, String))
}

fn manifest_decoder() -> decode.Decoder(Manifest) {
  use boot <- decode.field("boot", decode.string)
  use modules <- decode.field(
    "modules",
    decode.dict(decode.string, decode.string),
  )
  use fingerprints <- decode.field(
    "fingerprints",
    decode.dict(decode.string, {
      use version <- decode.field("version", decode.string)
      use modules <- decode.field(
        "modules",
        decode.dict(decode.string, decode.string),
      )
      decode.success(Fingerprint(version:, modules:))
    }),
  )
  decode.success(Manifest(boot:, modules:, fingerprints:))
}

/// The bundle's manifest, if there is one and it was built from the code
/// that is running.
fn release_manifest() -> Result(Manifest, String) {
  use root <- result.try(
    bundle_root()
    |> result.replace_error(
      "this release has no islands bundle. " <> export_advice,
    ),
  )
  use text <- result.try(read(root <> "/manifest.json"))
  use manifest <- result.try(
    json.parse(text, manifest_decoder())
    |> result.replace_error(
      "could not read " <> root <> "/manifest.json. " <> export_advice,
    ),
  )
  let changes =
    dict.to_list(manifest.fingerprints)
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.flat_map(fn(pair) { changes(pair.0, pair.1) })
  case changes {
    [] -> Ok(manifest)
    _ ->
      Error(
        "the islands bundle was built from different code than this release runs (changed: "
        <> summarise(changes)
        <> "). "
        <> export_advice,
      )
  }
}

/// How the running code differs from what one package's part of the
/// bundle was built from.
fn changes(package: String, built: Fingerprint) -> List(String) {
  case version(package) {
    Ok(version) if version != built.version -> [
      package <> " " <> built.version <> ", now " <> version,
    ]
    Error(Nil) -> [package <> ", which this release does not have"]
    Ok(_) ->
      dict.to_list(built.modules)
      |> list.filter(fn(pair) { fingerprint(pair.0) != Ok(pair.1) })
      |> list.map(fn(pair) { string.replace(pair.0, "@", "/") })
      |> list.sort(string.compare)
  }
}

fn summarise(changes: List(String)) -> String {
  let shown = list.take(changes, 5)
  let more = list.length(changes) - list.length(shown)
  string.join(shown, ", ")
  <> case more {
    0 -> ""
    _ -> " and " <> int.to_string(more) <> " more"
  }
}

// -- Building ----------------------------------------------------------------

/// An island module and the package that defines it.
type Island {
  Island(package: String, module: String)
}

/// What a build produced: every island, from the app and its dependencies,
/// and where each package's sources are.
type Built {
  Built(islands: List(Island), sources: Dict(String, String))
}

fn build() -> Result(Built, String) {
  use root <- result.try(
    simplifile.current_directory()
    |> result.replace_error("could not read the working directory"),
  )
  use toml <- result.try(read("gleam.toml"))
  use name <- result.try(package_name(toml))
  use manifest <- result.try(read("manifest.toml"))
  let own = island_modules("src")
  let dependencies = dependency_sources(manifest)
  let islands =
    list.flatten([
      list.map(own, Island(name, _)),
      ..list.map(dependencies, fn(dependency) {
        case dependency.builds_islands {
          True ->
            list.map(island_modules(dependency.src), Island(dependency.name, _))
          False -> []
        }
      })
    ])
  use <- bool.guard(
    islands == [],
    Error(
      "no island modules found. Put them in a directory called islands under src, such as src/"
      <> name
      <> "/islands/.",
    ),
  )
  // Only the app's own modules go in the hidden package; dependencies are
  // compiled whole, as they are for the app.
  let own_modules = reachable("src", own, set.new())
  use Nil <- result.try(sync(root, toml, manifest, own_modules))
  let sources =
    list.map(dependencies, fn(dependency) { #(dependency.name, dependency.src) })
    |> dict.from_list
    |> dict.insert(name, "src")
  let #(status, printed) = build_target(hidden, "javascript")
  case status {
    0 -> Ok(Built(islands:, sources:))
    _ -> Error(explain(string.replace(printed, root <> "/" <> hidden, root)))
  }
}

/// The island modules under a `src` directory.
fn island_modules(src: String) -> List(String) {
  simplifile.get_files(src)
  |> result.unwrap([])
  |> list.filter(string.ends_with(_, ".gleam"))
  |> list.map(module_of(src, _))
  |> list.filter(island.is_island_module)
  |> list.sort(string.compare)
}

/// A dependency and where its sources are.
type Dependency {
  Dependency(name: String, src: String, builds_islands: Bool)
}

/// Every dependency's `src` directory. Hex and git packages are
/// downloaded under `build/packages`; path dependencies are where the
/// manifest says. Only those that depend on howdy_ui can define islands,
/// since an island is built with it, and howdy_ui itself.
fn dependency_sources(manifest: String) -> List(Dependency) {
  string.split(manifest, "\n")
  |> list.filter_map(fn(line) {
    use name <- result.try(manifest_field(line, "name"))
    let directory = case
      manifest_field(line, "source"),
      manifest_field(line, "path")
    {
      Ok("local"), Ok(path) -> path
      _, _ -> "build/packages/" <> name
    }
    Ok(Dependency(
      name:,
      src: directory <> "/src",
      builds_islands: name == "howdy_ui" || requires(line, "howdy_ui"),
    ))
  })
}

// `key = "value"` in a manifest package line.
fn manifest_field(line: String, key: String) -> Result(String, Nil) {
  use #(_, rest) <- result.try(string.split_once(line, " " <> key <> " = \""))
  use #(value, _) <- result.try(string.split_once(rest, "\""))
  Ok(value)
}

fn requires(line: String, package: String) -> Bool {
  case string.split_once(line, "requirements = [") {
    Ok(#(_, rest)) ->
      case string.split_once(rest, "]") {
        Ok(#(requirements, _)) ->
          string.contains(requirements, "\"" <> package <> "\"")
        Error(Nil) -> False
      }
    Error(Nil) -> False
  }
}

// -- Bundling ----------------------------------------------------------------

/// Build the islands, bundle them into `priv/howdy_islands` and describe
/// what was written. Run from the project root.
///
/// The app is compiled for Erlang first, as the export will compile it, so
/// the fingerprints describe the code the release will run. `gleam run -m`
/// on a dependency's module does not always rebuild the app.
pub fn bundle() -> Result(String, String) {
  let #(status, printed) = build_target(".", "erlang")
  use <- bool.guard(
    status != 0,
    Error("could not compile the app for Erlang:\n" <> quiet(printed)),
  )
  use built <- result.try(build())
  use esbuild <- result.try(esbuild())
  let boot_entry = output <> "/howdy_ui/howdy/ui/island.ffi.mjs"
  let island_entries =
    list.map(built.islands, fn(island) {
      #(
        island.module,
        output <> "/" <> island.package <> "/" <> island.module <> ".mjs",
      )
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
  use #(inputs, outputs) <- result.try(
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
  use fingerprints <- result.try(fingerprints(inputs, built.sources))
  let manifest =
    json.object([
      #("boot", json.string(boot)),
      #(
        "modules",
        json.object(list.map(modules, fn(m) { #(m.0, json.string(m.1)) })),
      ),
      #(
        "fingerprints",
        json.object(
          list.map(fingerprints, fn(pair) {
            let #(package, Fingerprint(version:, modules:)) = pair
            #(
              package,
              json.object([
                #("version", json.string(version)),
                #("modules", json.dict(modules, fn(key) { key }, json.string)),
              ]),
            )
          }),
        ),
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

/// Bundle the islands, then export the release with
/// `gleam export erlang-shipment`, so nothing can change in between.
pub fn export() -> Result(String, String) {
  use bundled <- result.try(bundle())
  let #(status, printed) = gleam(["export", "erlang-shipment"])
  case status {
    0 -> Ok(bundled <> "\n\n" <> quiet(printed))
    _ ->
      Error(
        bundled
        <> "\n\n`gleam export erlang-shipment` failed:\n"
        <> quiet(printed),
      )
  }
}

/// What the bundle was built from, for each package with code in it.
///
/// Every input is a compiled module or a JavaScript FFI file, at
/// `<package>/<path>.mjs` in the JavaScript build. Compiled modules have
/// Erlang twins, whose fingerprints a release can check. The package's
/// Erlang FFI is included too: it is not in the bundle, but it shapes what
/// the server renders. JavaScript FFI has no twin; for dependencies from
/// Hex the version stands in for it.
fn fingerprints(
  inputs: List(String),
  sources: Dict(String, String),
) -> Result(List(#(String, Fingerprint)), String) {
  let by_package =
    list.filter_map(inputs, fn(input) {
      use rest <- result.try(case string.starts_with(input, output <> "/") {
        True -> Ok(string.drop_start(input, string.length(output) + 1))
        False -> Error(Nil)
      })
      string.split_once(rest, "/")
    })
    |> list.group(fn(pair) { pair.0 })
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  list.try_map(by_package, fn(group) {
    let #(package, files) = group
    use src <- result.try(
      dict.get(sources, package)
      |> result.replace_error(
        "could not find the sources of " <> package <> " in manifest.toml",
      ),
    )
    let compiled =
      list.filter_map(files, fn(file) {
        let module = string.drop_end(file.1, string.length(".mjs"))
        case simplifile.is_file(src <> "/" <> module <> ".gleam") {
          Ok(True) -> Ok(string.replace(module, "/", "@"))
          _ -> Error(Nil)
        }
      })
    let native =
      simplifile.get_files(src)
      |> result.unwrap([])
      |> list.filter(string.ends_with(_, ".erl"))
      |> list.map(fn(path) {
        filepath.base_name(path) |> string.drop_end(string.length(".erl"))
      })
    use version <- result.try(
      compiled_version(package)
      |> result.replace_error(
        "could not find the version of " <> package <> " under build/dev/erlang",
      ),
    )
    use compiled <- result.try(
      list.try_map(compiled, fn(module) {
        compiled_fingerprint(module)
        |> result.map(fn(print) { #(module, print) })
        |> result.replace_error(
          "could not find the compiled Erlang module "
          <> module
          <> " under build/dev/erlang. Run `"
          <> bundle_command
          <> "` from the project root.",
        )
      }),
    )
    // An .erl file in src that is never compiled, such as one a package
    // only includes, has nothing to check.
    let native =
      list.filter_map(native, fn(module) {
        compiled_fingerprint(module)
        |> result.map(fn(print) { #(module, print) })
      })
    let modules = dict.from_list(list.append(compiled, native))
    Ok(#(package, Fingerprint(version:, modules:)))
  })
}

/// The files esbuild read, and the files it wrote with the entry point
/// each one was written for.
fn metafile_decoder() -> decode.Decoder(
  #(List(String), Dict(String, Option(String))),
) {
  use inputs <- decode.field(
    "inputs",
    decode.dict(decode.string, decode.dynamic) |> decode.map(dict.keys),
  )
  use outputs <- decode.field(
    "outputs",
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
  decode.success(#(inputs, outputs))
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

// ("src", "src/app/islands/counter.gleam") -> "app/islands/counter"
fn module_of(src: String, path: String) -> String {
  path
  |> string.drop_start(string.length(src) + 1)
  |> string.drop_end(string.length(".gleam"))
}

/// The modules `pending` import from the same package's sources in `src`,
/// transitively, with themselves.
fn reachable(
  src: String,
  pending: List(String),
  found: Set(String),
) -> Set(String) {
  case pending {
    [] -> found
    [module, ..rest] ->
      case set.contains(found, module) {
        True -> reachable(src, rest, found)
        False -> {
          let found = set.insert(found, module)
          let imports = case simplifile.read(src <> "/" <> module <> ".gleam") {
            Ok(source) -> local_imports(src, source)
            Error(_) -> []
          }
          reachable(src, list.append(imports, rest), found)
        }
      }
  }
}

fn local_imports(src: String, source: String) -> List(String) {
  string.split(source, "\n")
  |> list.filter_map(fn(line) {
    case string.trim_start(line) {
      "import " <> rest -> {
        let module = take_module(string.trim_start(rest), "")
        case simplifile.is_file(src <> "/" <> module <> ".gleam") {
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
  let existing = links(src, "") |> set.from_list
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

// The links under the hidden package's `src`, relative to it. Unlike
// `simplifile.get_files`, this does not follow them, so a link to a module
// since deleted or renamed is found, and removed, rather than failing the
// listing.
fn links(directory: String, relative: String) -> List(String) {
  simplifile.read_directory(directory)
  |> result.unwrap([])
  |> list.flat_map(fn(name) {
    let path = directory <> "/" <> name
    let relative = case relative {
      "" -> name
      _ -> relative <> "/" <> name
    }
    case simplifile.is_symlink(path), simplifile.is_directory(path) {
      Ok(False), Ok(True) -> links(path, relative)
      _, _ -> [relative]
    }
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
  let output = quiet(output)
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

// What the compiler printed, without its progress lines.
fn quiet(output: String) -> String {
  string.split(output, "\n")
  |> list.filter(fn(line) {
    !string.starts_with(string.trim_start(line), "Compiling ")
    && !string.starts_with(string.trim_start(line), "Downloading ")
  })
  |> string.join("\n")
  |> string.trim
}

@external(erlang, "howdy_ui_island_ffi", "build")
fn build_target(directory: String, target: String) -> #(Int, String)

@external(erlang, "howdy_ui_island_ffi", "gleam")
fn gleam(args: List(String)) -> #(Int, String)

@external(erlang, "howdy_ui_island_ffi", "development")
fn development() -> Bool

@external(erlang, "howdy_ui_island_ffi", "bundle_root")
fn bundle_root() -> Result(String, Nil)

@external(erlang, "howdy_ui_island_ffi", "fingerprint")
fn fingerprint(module: String) -> Result(String, Nil)

@external(erlang, "howdy_ui_island_ffi", "compiled_fingerprint")
fn compiled_fingerprint(module: String) -> Result(String, Nil)

@external(erlang, "howdy_ui_island_ffi", "version")
fn version(package: String) -> Result(String, Nil)

@external(erlang, "howdy_ui_island_ffi", "compiled_version")
fn compiled_version(package: String) -> Result(String, Nil)

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
