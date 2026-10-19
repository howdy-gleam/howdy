//// Reading catalogues: one JSON file per locale, named by its tag, such as
//// `locales/de.json`, holding messages by key.
////
//// ```json
//// {
////   "@@locale": "de",
////   "@@x-review": "machine translation, not yet reviewed",
////   "cart.items": "{count, plural, one {# Artikel} other {# Artikel}}",
////   "nav": { "home": "Startseite" }
//// }
//// ```
////
//// Nested objects are flattened with dots, so the last message's key is
//// `nav.home`. Keys starting with `@` are notes for people and tools, as in
//// the ARB format, and are not messages; `@@x-review` marks a catalogue
//// whose messages still need checking by a native speaker.

import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

pub type Catalogue {
  Catalogue(
    locale: String,
    file: String,
    messages: List(#(String, String)),
    review: Option(String),
  )
}

/// Every catalogue in a directory, sorted by locale.
pub fn load_directory(directory: String) -> Result(List(Catalogue), String) {
  use files <- result.try(
    simplifile.read_directory(directory)
    |> result.map_error(fn(error) {
      "cannot read " <> directory <> ": " <> simplifile.describe_error(error)
    }),
  )
  files
  |> list.filter(string.ends_with(_, ".json"))
  |> list.sort(string.compare)
  |> list.try_map(fn(file) {
    let path = directory <> "/" <> file
    use text <- result.try(
      simplifile.read(path)
      |> result.map_error(fn(error) {
        "cannot read " <> path <> ": " <> simplifile.describe_error(error)
      }),
    )
    decode_catalogue(string.drop_end(file, 5), file, text)
  })
}

pub fn decode_catalogue(
  locale: String,
  file: String,
  text: String,
) -> Result(Catalogue, String) {
  use top <- result.try(
    json.parse(text, decode.dict(decode.string, decode.dynamic))
    |> result.replace_error(file <> " is not a JSON object"),
  )
  use entries <- result.try(flatten(dict.to_list(top), ""))
  let messages =
    list.filter(entries, fn(entry) { !string.starts_with(entry.0, "@") })
  let note = fn(name) { list.key_find(entries, name) |> option.from_result }
  use <- check(
    case note("@@locale") {
      Some(declared) -> declared == locale
      None -> True
    },
    file <> " says it is for another locale in @@locale",
  )
  Ok(Catalogue(
    locale:,
    file:,
    messages: list.sort(messages, fn(a, b) { string.compare(a.0, b.0) }),
    review: note("@@x-review"),
  ))
}

fn flatten(
  entries: List(#(String, dynamic.Dynamic)),
  prefix: String,
) -> Result(List(#(String, String)), String) {
  list.try_map(entries, fn(entry) {
    let #(name, value) = entry
    let key = prefix <> name
    let text = decode.run(value, decode.string)
    case string.starts_with(name, "@"), text {
      // Notes about the whole catalogue, such as @@locale, are kept; notes
      // about one message, such as ARB's "@key": {...}, are not.
      True, Ok(text) if prefix == "" -> Ok([#(key, text)])
      True, _ -> Ok([])
      False, Ok(text) -> Ok([#(key, text)])
      False, Error(_) ->
        case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
          Ok(nested) -> flatten(dict.to_list(nested), key <> ".")
          Error(_) -> Error(key <> " must be a string or an object")
        }
    }
  })
  |> result.map(list.flatten)
}

fn check(ok: Bool, message: String, next: fn() -> Result(a, String)) {
  case ok {
    True -> next()
    False -> Error(message)
  }
}

/// A safe catalogue filename tag, such as de or zh-Hant-TW.
pub fn valid_locale(tag: String) -> Bool {
  case string.split(tag, "-") {
    [language, ..rest] ->
      string.length(language) >= 2
      && string.length(language) <= 8
      && list.all(string.to_graphemes(language), fn(g) {
        ascii_between(g, 97, 122)
      })
      && list.all(rest, fn(part) {
        string.length(part) >= 1
        && string.length(part) <= 8
        && list.all(string.to_graphemes(part), fn(g) {
          ascii_between(g, 97, 122)
          || ascii_between(g, 65, 90)
          || ascii_between(g, 48, 57)
        })
      })
    [] -> False
  }
}

fn ascii_between(g: String, first: Int, last: Int) -> Bool {
  case string.to_utf_codepoints(g) {
    [codepoint] -> {
      let value = string.utf_codepoint_to_int(codepoint)
      value >= first && value <= last
    }
    _ -> False
  }
}
