//// Release bookkeeping for the Howdy packages. `scripts/release.sh` runs
//// it; see `RELEASING.md`.
////
//// Every package in this repository is released together, under one Howdy
//// version. `releases/releases.json` records each release and the version of
//// every package in it, and `releases/since.json` records the release that
//// first shipped each public module, function, constant and type, and the
//// release that deprecated or removed it. Both are written from the code,
//// never by hand.
////
//// ```sh
//// gleam run -m howdy_release -- check 1.0.0
//// gleam run -m howdy_release -- record 1.0.0 2026-10-01 /tmp/interfaces
//// ```
////
//// `record` reads one `gleam export package-interface` file per package,
//// named `<package>.json`, from the directory it is given.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order}
import gleam/result
import gleam/string
import simplifile

/// Every package released together, and where it lives.
pub const packages = [
  #("howdy", "."),
  #("howdy_dev", "howdy_dev"),
  #("howdy_ui", "ui"),
  #("howdy_database", "database"),
  #("howdy_auth", "auth"),
  #("howdy_mail", "mail"),
  #("howdy_storage", "storage"),
  #("howdy_admin", "admin"),
  #("howdy_remote", "remote"),
  #("howdy_telemetry", "telemetry"),
  #("howdy_openapi", "openapi"),
  #("howdy_flags", "flags"),
  #("howdy_jobs", "jobs"),
  #("howdy_notifications", "notifications"),
  #("howdy_cache", "cache"),
  #("howdy_i18n", "i18n"),
]

const releases_path = "releases/releases.json"

const since_path = "releases/since.json"

@external(erlang, "howdy_release_ffi", "arguments")
fn arguments() -> List(String)

@external(erlang, "howdy_release_ffi", "halt")
fn halt(code: Int) -> Nil

pub fn main() -> Nil {
  let outcome = case arguments() {
    ["check", version] -> check(version) |> result.map(print_table(version, _))
    ["record", version, date, interfaces] ->
      record(version, date, interfaces)
      |> result.map(fn(_) { io.println("recorded Howdy " <> version) })
    _ ->
      Error(
        "usage: gleam run -m howdy_release -- check VERSION\n"
        <> "       gleam run -m howdy_release -- record VERSION DATE INTERFACES_DIR",
      )
  }
  case outcome {
    Ok(Nil) -> Nil
    Error(message) -> {
      io.println_error("howdy_release: " <> message)
      halt(1)
    }
  }
}

// -- Versions ----------------------------------------------------------------

pub type Version {
  Version(major: Int, minor: Int, patch: Int)
}

pub fn parse_version(text: String) -> Result(Version, Nil) {
  case string.split(text, ".") |> list.map(int.parse) {
    [Ok(major), Ok(minor), Ok(patch)]
      if major >= 0 && minor >= 0 && patch >= 0
    -> Ok(Version(major:, minor:, patch:))
    _ -> Error(Nil)
  }
}

pub fn compare(a: Version, b: Version) -> Order {
  case int.compare(a.major, b.major) {
    order.Eq ->
      case int.compare(a.minor, b.minor) {
        order.Eq -> int.compare(a.patch, b.patch)
        other -> other
      }
    other -> other
  }
}

// -- Releases ----------------------------------------------------------------

pub type Release {
  Release(version: String, date: String, packages: List(#(String, String)))
}

pub fn read_releases() -> Result(List(Release), String) {
  case simplifile.read(releases_path) {
    Error(simplifile.Enoent) -> Ok([])
    Error(error) ->
      Error("could not read " <> releases_path <> ": " <> string.inspect(error))
    Ok(text) ->
      json.parse(text, releases_decoder())
      |> result.map_error(fn(error) {
        releases_path <> " is not valid: " <> string.inspect(error)
      })
  }
}

fn releases_decoder() -> decode.Decoder(List(Release)) {
  let release = {
    use version <- decode.field("version", decode.string)
    use date <- decode.field("date", decode.string)
    use packages <- decode.field(
      "packages",
      decode.dict(decode.string, decode.string),
    )
    decode.success(Release(version:, date:, packages: dict.to_list(packages)))
  }
  decode.field("releases", decode.list(release), decode.success)
}

fn releases_to_json(releases: List(Release)) -> Json {
  json.object([
    #(
      "releases",
      json.array(releases, fn(release) {
        json.object([
          #("version", json.string(release.version)),
          #("date", json.string(release.date)),
          #(
            "packages",
            json.object(
              release.packages
              |> list.sort(fn(a, b) {
                int.compare(package_position(a.0), package_position(b.0))
              })
              |> list.map(fn(pair) { #(pair.0, json.string(pair.1)) }),
            ),
          ),
        ])
      }),
    ),
  ])
}

/// Where a package comes in `packages`, so files list them in that order.
fn package_position(name: String) -> Int {
  packages
  |> list.index_map(fn(package, index) { #(package.0, index) })
  |> list.key_find(name)
  |> result.unwrap(list.length(packages))
}

/// The version each package's `gleam.toml` declares.
pub fn package_versions() -> Result(List(#(String, String)), String) {
  list.try_map(packages, fn(package) {
    let #(name, path) = package
    let file = path <> "/gleam.toml"
    use toml <- result.try(
      simplifile.read(file)
      |> result.replace_error("could not read " <> file),
    )
    let lines = string.split(toml, "\n")
    let value = fn(key) {
      list.find_map(lines, fn(line) {
        case string.split_once(line, "=") {
          Ok(#(k, v)) if k == key <> " " || k == key ->
            case string.split(string.trim(v), "\"") {
              ["", value, ""] -> Ok(value)
              _ -> Error(Nil)
            }
          _ -> Error(Nil)
        }
      })
    }
    use declared <- result.try(
      value("name") |> result.replace_error(file <> " has no name"),
    )
    use <- guard(
      declared != name,
      file <> " names " <> declared <> ", expected " <> name,
    )
    use version <- result.map(
      value("version") |> result.replace_error(file <> " has no version"),
    )
    #(name, version)
  })
}

/// Check `version` can be released: newer than every release so far, and
/// the core `howdy` package declares it.
pub fn check(version: String) -> Result(List(#(String, String)), String) {
  use parsed <- result.try(
    parse_version(version)
    |> result.replace_error(version <> " is not a version like 1.0.0"),
  )
  use releases <- result.try(read_releases())
  use _ <- result.try(
    list.try_each(releases, fn(release) {
      case parse_version(release.version) {
        Ok(earlier) ->
          case compare(parsed, earlier) {
            order.Gt -> Ok(Nil)
            _ ->
              Error(
                version <> " is not newer than the released " <> release.version,
              )
          }
        Error(Nil) ->
          Error(releases_path <> " has a bad version " <> release.version)
      }
    }),
  )
  use versions <- result.try(package_versions())
  use _ <- result.map(case list.key_find(versions, "howdy") {
    Ok(core) if core == version -> Ok(Nil)
    Ok(core) ->
      Error(
        "gleam.toml declares howdy "
        <> core
        <> ": set it to "
        <> version
        <> " before releasing",
      )
    Error(Nil) -> Error("no howdy package")
  })
  versions
}

fn print_table(version: String, versions: List(#(String, String))) -> Nil {
  io.println("Howdy " <> version <> " will release:")
  let width =
    list.fold(versions, 0, fn(width, pair) {
      int.max(width, string.length(pair.0))
    })
  list.each(versions, fn(pair) {
    io.println("  " <> string.pad_end(pair.0, width + 1, " ") <> pair.1)
  })
}

/// Record the release: add it to `releases.json` and bring `since.json` up
/// to date from the package interfaces in `interfaces`.
pub fn record(
  version: String,
  date: String,
  interfaces: String,
) -> Result(Nil, String) {
  use versions <- result.try(check(version))
  use releases <- result.try(read_releases())
  use previous <- result.try(read_since())
  use apis <- result.try(
    list.try_map(packages, fn(package) {
      let file = interfaces <> "/" <> package.0 <> ".json"
      use text <- result.try(
        simplifile.read(file) |> result.replace_error("could not read " <> file),
      )
      json.parse(text, interface_decoder())
      |> result.map(fn(modules) { #(package.0, modules) })
      |> result.map_error(fn(error) {
        file <> " is not a package interface: " <> string.inspect(error)
      })
    }),
  )
  let since = update_since(previous, apis, version)
  let releases =
    list.append(releases, [Release(version:, date:, packages: versions)])
  let _ = simplifile.create_directory_all("releases")
  use _ <- result.try(write_json(releases_path, releases_to_json(releases)))
  write_json(since_path, since_to_json(since))
}

fn write_json(path: String, value: Json) -> Result(Nil, String) {
  simplifile.write(path, pretty(json.to_string(value)) <> "\n")
  |> result.map_error(fn(error) {
    "could not write " <> path <> ": " <> string.inspect(error)
  })
}

// -- Public API over time ----------------------------------------------------

/// When something was added, and when it was deprecated or removed.
pub type Life {
  Life(since: String, deprecated: Option(String), removed: Option(String))
}

/// Per package, per module: the module's life and its items'.
pub type Since =
  Dict(String, Dict(String, #(Life, Dict(String, Life))))

/// A module's public items, from a package interface: each name, and
/// whether it is deprecated. Types keep their capital, so a type and a
/// function never share a name.
pub type Api =
  Dict(String, Dict(String, Bool))

fn interface_decoder() -> decode.Decoder(Api) {
  let deprecated =
    decode.optional_field(
      "deprecation",
      None,
      decode.optional(decode.dynamic),
      decode.success,
    )
    |> decode.map(option.is_some)
  let items = decode.dict(decode.string, deprecated)
  let module = {
    use functions <- decode.field("functions", items)
    use constants <- decode.field("constants", items)
    use types <- decode.field("types", items)
    use aliases <- decode.field("type-aliases", items)
    decode.success(
      functions
      |> dict.merge(constants)
      |> dict.merge(types)
      |> dict.merge(aliases),
    )
  }
  decode.field("modules", decode.dict(decode.string, module), decode.success)
}

/// Bring the record up to date with the API as it is at `version`: new
/// things are marked as added in it, newly deprecated ones as deprecated in
/// it, and ones that have gone as removed in it.
pub fn update_since(
  previous: Since,
  apis: List(#(String, Api)),
  version: String,
) -> Since {
  list.fold(apis, previous, fn(since, package) {
    let #(name, modules) = package
    let known =
      dict.get(since, name)
      |> result.unwrap(dict.new())
      |> dict.filter(fn(module, _) { !is_internal(module) })
    let present =
      dict.map_values(modules, fn(module, items) {
        let #(life, known_items) =
          dict.get(known, module)
          |> result.unwrap(#(Life(version, None, None), dict.new()))
        let life = Life(..life, removed: None)
        let items =
          dict.map_values(items, fn(item, deprecated) {
            let life =
              dict.get(known_items, item)
              |> result.unwrap(Life(version, None, None))
            let life = Life(..life, removed: None)
            case deprecated, life.deprecated {
              True, None -> Life(..life, deprecated: Some(version))
              False, Some(_) -> Life(..life, deprecated: None)
              _, _ -> life
            }
          })
        let gone =
          dict.filter(known_items, fn(item, _) { !dict.has_key(items, item) })
          |> dict.map_values(fn(_, life) { removed(life, version) })
        #(life, dict.merge(gone, items))
      })
    let gone =
      dict.filter(known, fn(module, _) { !dict.has_key(modules, module) })
      |> dict.map_values(fn(_, entry) {
        #(
          removed(entry.0, version),
          dict.map_values(entry.1, fn(_, life) { removed(life, version) }),
        )
      })
    dict.insert(since, name, dict.merge(gone, present))
  })
}

/// Package interfaces leave out internal modules. Ones recorded before their
/// package marked them internal are dropped rather than marked as removed:
/// they were never meant to be public.
fn is_internal(module: String) -> Bool {
  string.split(module, "/") |> list.contains("internal")
}

fn removed(life: Life, version: String) -> Life {
  case life.removed {
    Some(_) -> life
    None -> Life(..life, removed: Some(version))
  }
}

fn read_since() -> Result(Since, String) {
  case simplifile.read(since_path) {
    Error(simplifile.Enoent) -> Ok(dict.new())
    Error(error) ->
      Error("could not read " <> since_path <> ": " <> string.inspect(error))
    Ok(text) ->
      json.parse(text, since_decoder())
      |> result.map_error(fn(error) {
        since_path <> " is not valid: " <> string.inspect(error)
      })
  }
}

fn life_decoder() -> decode.Decoder(Life) {
  use since <- decode.field("since", decode.string)
  use deprecated <- decode.optional_field(
    "deprecated",
    None,
    decode.optional(decode.string),
  )
  use removed <- decode.optional_field(
    "removed",
    None,
    decode.optional(decode.string),
  )
  decode.success(Life(since:, deprecated:, removed:))
}

pub fn since_decoder() -> decode.Decoder(Since) {
  let module = {
    use life <- decode.then(life_decoder())
    use items <- decode.optional_field(
      "items",
      dict.new(),
      decode.dict(decode.string, life_decoder()),
    )
    decode.success(#(life, items))
  }
  decode.dict(decode.string, decode.dict(decode.string, module))
}

fn life_fields(life: Life) -> List(#(String, Json)) {
  list.flatten([
    [#("since", json.string(life.since))],
    case life.deprecated {
      Some(version) -> [#("deprecated", json.string(version))]
      None -> []
    },
    case life.removed {
      Some(version) -> [#("removed", json.string(version))]
      None -> []
    },
  ])
}

pub fn since_to_json(since: Since) -> Json {
  let sorted = fn(entries: Dict(String, a)) {
    dict.to_list(entries)
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  }
  json.object(
    list.map(sorted(since), fn(package) {
      #(
        package.0,
        json.object(
          list.map(sorted(package.1), fn(module) {
            let #(life, items) = module.1
            #(
              module.0,
              json.object(
                list.append(life_fields(life), [
                  #(
                    "items",
                    json.object(
                      list.map(sorted(items), fn(item) {
                        #(item.0, json.object(life_fields(item.1)))
                      }),
                    ),
                  ),
                ]),
              ),
            )
          }),
        ),
      )
    }),
  )
}

// -- Helpers -----------------------------------------------------------------

fn guard(
  refuse: Bool,
  message: String,
  next: fn() -> Result(a, String),
) -> Result(a, String) {
  case refuse {
    True -> Error(message)
    False -> next()
  }
}

/// Indent compact JSON two spaces a level, so the files read well in a
/// diff. Strings are copied as they are.
pub fn pretty(compact: String) -> String {
  pretty_loop(string.to_graphemes(compact), 0, False, False, "")
}

fn pretty_loop(
  chars: List(String),
  depth: Int,
  in_string: Bool,
  escaped: Bool,
  out: String,
) -> String {
  let newline = fn(depth) { "\n" <> string.repeat("  ", depth) }
  case chars {
    [] -> out
    [c, ..rest] if in_string ->
      case escaped, c {
        True, _ -> pretty_loop(rest, depth, True, False, out <> c)
        False, "\\" -> pretty_loop(rest, depth, True, True, out <> c)
        False, "\"" -> pretty_loop(rest, depth, False, False, out <> c)
        False, _ -> pretty_loop(rest, depth, True, False, out <> c)
      }
    ["\"", ..rest] -> pretty_loop(rest, depth, True, False, out <> "\"")
    ["{", "}", ..rest] -> pretty_loop(rest, depth, False, False, out <> "{}")
    ["[", "]", ..rest] -> pretty_loop(rest, depth, False, False, out <> "[]")
    [c, ..rest] if c == "{" || c == "[" ->
      pretty_loop(rest, depth + 1, False, False, out <> c <> newline(depth + 1))
    [c, ..rest] if c == "}" || c == "]" ->
      pretty_loop(rest, depth - 1, False, False, out <> newline(depth - 1) <> c)
    [",", ..rest] ->
      pretty_loop(rest, depth, False, False, out <> "," <> newline(depth))
    [":", ..rest] -> pretty_loop(rest, depth, False, False, out <> ": ")
    [c, ..rest] -> pretty_loop(rest, depth, False, False, out <> c)
  }
}
