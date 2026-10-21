//// Translations for Howdy apps.
////
//// A `Translator` is a locale with everything needed to write in it:
//// the locales to fall back to, plural rules, and the CLDR data that
//// `howdy/i18n/format` writes numbers, dates and lists with.
////
//// ```gleam
//// let t = i18n.new("de-CH")
//// messages.cart_items(t, count: 3)   // "3 Artikel"
//// format.date(t, today, format.Long)  // "19. Oktober 2026"
//// ```
////
//// Messages live in JSON catalogues, one per locale, written in ICU
//// MessageFormat, and `gleam run -m howdy/i18n/cli gen` turns them into a
//// Gleam module with a function for each message. See `howdy/i18n/cli`.
////
//// Pass the tag `howdy/locale` chose for the request: `i18n.new(
//// locale.to_string(locale.detect(ctx, locales)))`. This package does not
//// depend on Howdy itself, so it also works in code compiled to
//// JavaScript.

import gleam/list
import gleam/result
import gleam/string
import howdy/i18n/internal/cldr
import howdy/i18n/internal/data.{type Data}

pub opaque type Translator {
  Translator(locale: String, fallbacks: List(String), data: Data)
}

/// A translator for a BCP 47 tag such as `pt-BR`. Any tag works: one
/// without data of its own uses the nearest locale that has some, and
/// English in the end.
pub fn new(locale: String) -> Translator {
  let locale = canonical(locale)
  let fallbacks = fallbacks_of(locale)
  let data =
    list.find_map(fallbacks, cldr.lookup)
    |> result.lazy_or(fn() {
      case has_script(locale) {
        True -> Error(Nil)
        False ->
          list.find(cldr.locales, same_language(_, locale))
          |> result.try(cldr.lookup)
      }
    })
    |> result.lazy_unwrap(fn() {
      let assert Ok(english) = cldr.lookup("en")
      english
    })
  Translator(locale:, fallbacks:, data:)
}

/// The tag, in canonical case: `pt-BR`.
pub fn locale(translator: Translator) -> String {
  translator.locale
}

/// The locale and those it falls back to, most specific first:
/// `es-AR`, `es-419`, `es`.
pub fn fallbacks(translator: Translator) -> List(String) {
  translator.fallbacks
}

/// The locale whose formatting data the translator uses.
pub fn data_locale(translator: Translator) -> String {
  translator.data.tag
}

/// The locales with formatting data of their own.
pub fn data_locales() -> List(String) {
  cldr.locales
}

/// The version of CLDR the data and plural rules come from.
pub fn cldr_version() -> String {
  cldr.version
}

/// The name of a locale in its own language, such as `Deutsch` for `de`,
/// for a language switcher. `Error` for a locale without data.
pub fn language_name(locale: String) -> Result(String, Nil) {
  cldr.lookup(canonical(locale)) |> result.map(fn(data) { data.name })
}

/// Which of `available` catalogue locales to use: the first the
/// translator falls back to, or one of the same language, or `""` when
/// there is none. Generated catalogues call this to choose their words.
pub fn pick(translator: Translator, available: List(String)) -> String {
  list.find_map(translator.fallbacks, fn(fallback) {
    list.find(available, fn(candidate) { canonical(candidate) == fallback })
  })
  |> result.lazy_or(fn() {
    case has_script(translator.locale) {
      True -> Error(Nil)
      False ->
        list.find(available, fn(candidate) {
          same_language(canonical(candidate), translator.locale)
        })
    }
  })
  |> result.unwrap("")
}

@internal
pub fn data(translator: Translator) -> Data {
  translator.data
}

// -- Tags --------------------------------------------------------------------

/// A tag in canonical case, with `_` read as `-`: `zh-Hant-TW`. Chinese for
/// Taiwan, Hong Kong and Macau gains its traditional script.
pub fn canonical(tag: String) -> String {
  let parts =
    tag
    |> string.trim
    |> string.replace("_", "-")
    |> string.split("-")
    |> list.filter(fn(part) { part != "" })
  case parts {
    [] -> "und"
    [language, ..rest] -> {
      let rest =
        list.map(rest, fn(part) {
          case string.length(part) {
            4 ->
              string.uppercase(string.slice(part, 0, 1))
              <> string.lowercase(string.drop_start(part, 1))
            2 | 3 -> string.uppercase(part)
            _ -> string.lowercase(part)
          }
        })
      let language = string.lowercase(language)
      let rest = case language, rest {
        "zh", [region] if region == "TW" || region == "HK" || region == "MO" -> [
          "Hant",
          region,
        ]
        _, _ -> rest
      }
      string.join([language, ..rest], "-")
    }
  }
}

fn fallbacks_of(tag: String) -> List(String) {
  case cldr.parent(tag) {
    Ok("und") | Ok("root") -> [tag]
    Ok(parent) -> [tag, ..fallbacks_of(parent)]
    Error(Nil) ->
      case string.split(tag, "-") |> list.reverse {
        [_] | [] -> [tag]
        [_, ..rest] -> [
          tag,
          ..fallbacks_of(string.join(list.reverse(rest), "-"))
        ]
      }
  }
}

fn language_of(tag: String) -> String {
  case string.split_once(tag, "-") {
    Ok(#(language, _)) -> language
    Error(Nil) -> tag
  }
}

fn same_language(tag: String, other: String) -> Bool {
  language_of(tag) == language_of(other)
}

fn has_script(tag: String) -> Bool {
  string.split(tag, "-")
  |> list.drop(1)
  |> list.any(fn(part) { string.length(part) == 4 })
}
