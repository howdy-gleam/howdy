//// Which language to answer a request in.
////
//// A negotiator lists the locales an app supports and where to look for
//// the one a request wants, in order. The first source that names a
//// supported locale wins; when none does, the default is used.
////
//// ```gleam
//// let locales =
////   locale.negotiator(["en", "de", "fr-CA", "ar"], default: "en")
////   |> locale.from_param("locale")
////   |> locale.from_cookie("locale")
////   |> locale.from_accept_language
////
//// fn show(ctx: Context) {
////   let l = locale.detect(ctx, locales)
////   controller.html(ctx, page(l))
//// }
//// ```
////
//// Matching follows the lookup of RFC 4647: `de-CH` falls back to `de`.
//// A request for a bare language also takes a regional locale of it, so
//// `en` matches an app that only supports `en-GB`.
////
//// Add `middleware` to stamp responses with `content-language`, and with
//// `vary` naming the headers the choice came from, so shared caches keep
//// one copy per language. `remember` stores a visitor's choice in the
//// cookie named by `from_cookie`, for a language switcher.

import gleam/dict.{type Dict}
import gleam/float
import gleam/http
import gleam/http/cookie
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/uri
import howdy/content.{type Content}
import howdy/context.{type Body, type Context}

/// A language, optionally with a script and a region, such as `en`,
/// `pt-BR` or `zh-Hant-TW`. Variants and extensions are dropped when
/// parsing, since nothing in Howdy uses them.
pub opaque type Locale {
  Locale(language: String, script: Option(String), region: Option(String))
}

/// Parse a BCP 47 language tag. Case is normalised, so `EN-us` becomes
/// `en-US`, and `_` is accepted in place of `-`.
pub fn parse(tag: String) -> Result(Locale, Nil) {
  let parts =
    tag
    |> string.trim
    |> string.replace("_", "-")
    |> string.split("-")
  case parts {
    [language, ..rest] -> {
      use language <- result.try(parse_language(language))
      let #(script, rest) = case rest {
        [part, ..after] ->
          case is_script(part) {
            True -> #(Some(title_case(part)), after)
            False -> #(None, rest)
          }
        [] -> #(None, [])
      }
      let region = case rest {
        [part, ..] ->
          case is_region(part) {
            True -> Some(string.uppercase(part))
            False -> None
          }
        [] -> None
      }
      Ok(Locale(language:, script:, region:))
    }
    [] -> Error(Nil)
  }
}

/// The tag, in canonical case: `pt-BR`.
pub fn to_string(locale: Locale) -> String {
  [Some(locale.language), locale.script, locale.region]
  |> option.values
  |> string.join("-")
}

/// The language subtag: `pt` for `pt-BR`.
pub fn language(locale: Locale) -> String {
  locale.language
}

pub fn script(locale: Locale) -> Option(String) {
  locale.script
}

pub fn region(locale: Locale) -> Option(String) {
  locale.region
}

/// The locale and the less specific ones it falls back to, most specific
/// first: `zh-Hant-TW`, `zh-Hant`, `zh`.
pub fn fallbacks(locale: Locale) -> List(Locale) {
  let Locale(language:, script:, region:) = locale
  let bare = Locale(language:, script: None, region: None)
  case script, region {
    None, None -> [locale]
    Some(_), Some(_) -> [locale, Locale(..locale, region: None), bare]
    _, _ -> [locale, bare]
  }
}

/// Whether text in this locale runs right to left, as Arabic, Hebrew and
/// Persian do. An explicit script decides when there is one.
pub fn right_to_left(locale: Locale) -> Bool {
  case locale.script {
    Some(script) -> list.contains(rtl_scripts, script)
    None -> list.contains(rtl_languages, locale.language)
  }
}

const rtl_scripts = ["Arab", "Hebr", "Thaa", "Syrc", "Nkoo", "Adlm", "Rohg"]

const rtl_languages = [
  "ar", "arc", "ckb", "dv", "fa", "he", "iw", "ks", "ps", "sd", "syr", "ug",
  "ur", "yi",
]

fn parse_language(part: String) -> Result(String, Nil) {
  let length = string.length(part)
  case length >= 2 && length <= 8 && all_letters(part) {
    True -> Ok(string.lowercase(part))
    False -> Error(Nil)
  }
}

fn is_script(part: String) -> Bool {
  string.length(part) == 4 && all_letters(part)
}

fn is_region(part: String) -> Bool {
  case string.length(part) {
    2 -> all_letters(part)
    3 -> all_digits(part)
    _ -> False
  }
}

fn all_letters(part: String) -> Bool {
  part
  |> string.to_utf_codepoints
  |> list.all(fn(c) {
    let c = string.utf_codepoint_to_int(c)
    { c >= 65 && c <= 90 } || { c >= 97 && c <= 122 }
  })
}

fn title_case(part: String) -> String {
  string.uppercase(string.slice(part, 0, 1))
  <> string.lowercase(string.drop_start(part, 1))
}

// -- Negotiation -------------------------------------------------------------

/// The locales an app supports and where to look for a request's choice.
pub opaque type Negotiator {
  Negotiator(supported: List(Locale), default: Locale, sources: List(Source))
}

type Source {
  Param(String)
  PathSegment
  Query(String)
  Cookie(String)
  Custom(fn(Request(Body)) -> Option(String))
  AcceptLanguage
}

/// A negotiator for `supported` locales, falling back to `default`, which
/// is supported even when not listed. With no sources added it always
/// answers the default. Invalid tags panic, as they are configuration.
pub fn negotiator(
  supported: List(String),
  default default: String,
) -> Negotiator {
  let parse_config = fn(tag) {
    let assert Ok(locale) = parse(tag)
      as { "invalid locale in negotiator: " <> tag }
    locale
  }
  let default = parse_config(default)
  let supported = list.map(supported, parse_config)
  let supported = case list.contains(supported, default) {
    True -> supported
    False -> list.append(supported, [default])
  }
  Negotiator(supported:, default:, sources: [])
}

/// Look in the route parameter `name`, such as `locale` for routes under
/// `/:locale`. Route parameters are not known to app-wide middleware; use
/// `from_path_segment` there.
pub fn from_param(negotiator: Negotiator, name: String) -> Negotiator {
  add(negotiator, Param(name))
}

/// Look at the first segment of the path, so `/de/shop` asks for `de`.
pub fn from_path_segment(negotiator: Negotiator) -> Negotiator {
  add(negotiator, PathSegment)
}

/// Look in the query parameter `name`, such as `?lang=de`.
pub fn from_query(negotiator: Negotiator, name: String) -> Negotiator {
  add(negotiator, Query(name))
}

/// Look in the cookie `name`, which `remember` sets.
pub fn from_cookie(negotiator: Negotiator, name: String) -> Negotiator {
  add(negotiator, Cookie(name))
}

/// Look wherever `find` does, such as in a signed-in user's saved
/// preference. `None`, or a tag that is not supported, moves on to the next
/// source. Since a custom source may read any header, `middleware` sets
/// `vary: *` to keep its responses out of shared caches.
pub fn from(
  negotiator: Negotiator,
  find: fn(Request(Body)) -> Option(String),
) -> Negotiator {
  add(negotiator, Custom(find))
}

/// Look in the `accept-language` header the browser sends, trying each
/// language in order of preference.
pub fn from_accept_language(negotiator: Negotiator) -> Negotiator {
  add(negotiator, AcceptLanguage)
}

fn add(negotiator: Negotiator, source: Source) -> Negotiator {
  Negotiator(..negotiator, sources: list.append(negotiator.sources, [source]))
}

pub fn supported(negotiator: Negotiator) -> List(Locale) {
  negotiator.supported
}

pub fn default(negotiator: Negotiator) -> Locale {
  negotiator.default
}

/// The locale for a request.
pub fn detect(ctx: Context(guarded), negotiator: Negotiator) -> Locale {
  detect_request(ctx.request, ctx.params, negotiator)
}

/// The locale for a request outside a handler, such as when a live view
/// mounts. `params` are the route parameters, if any.
pub fn detect_request(
  request: Request(Body),
  params: Dict(String, String),
  negotiator: Negotiator,
) -> Locale {
  list.find_map(negotiator.sources, fn(source) {
    candidates(source, request, params)
    |> list.find_map(fn(tag) { option.to_result(match(negotiator, tag), Nil) })
  })
  |> result.unwrap(negotiator.default)
}

/// The supported locale for the first of `tags` that has one, or the
/// default.
pub fn negotiate(negotiator: Negotiator, tags: List(String)) -> Locale {
  list.find_map(tags, fn(tag) { option.to_result(match(negotiator, tag), Nil) })
  |> result.unwrap(negotiator.default)
}

/// The supported locale a tag asks for, if any: the tag itself, then each
/// of its fallbacks, then any supported locale of the same language.
pub fn match(negotiator: Negotiator, tag: String) -> Option(Locale) {
  case parse(tag) {
    Error(Nil) -> None
    Ok(wanted) -> {
      let exact =
        list.find(fallbacks(wanted), list.contains(negotiator.supported, _))
      case exact {
        Ok(found) -> Some(found)
        Error(Nil) ->
          list.find(negotiator.supported, fn(l) {
            l.language == wanted.language
          })
          |> option.from_result
      }
    }
  }
}

fn candidates(
  source: Source,
  request: Request(Body),
  params: Dict(String, String),
) -> List(String) {
  case source {
    Param(name) -> dict.get(params, name) |> result.map(list.wrap) |> or_none
    PathSegment ->
      case string.split(request.path, "/") {
        ["", segment, ..] if segment != "" -> [segment]
        _ -> []
      }
    Query(name) ->
      request.get_query(request)
      |> result.try(list.key_find(_, name))
      |> result.map(list.wrap)
      |> or_none
    Cookie(name) ->
      request.get_cookies(request)
      |> list.key_find(name)
      |> result.try(uri.percent_decode)
      |> result.map(list.wrap)
      |> or_none
    Custom(find) ->
      option.to_result(find(request), Nil) |> result.map(list.wrap) |> or_none
    AcceptLanguage ->
      request.get_header(request, "accept-language")
      |> result.map(accept_language)
      |> or_none
  }
}

fn or_none(found: Result(List(String), Nil)) -> List(String) {
  result.unwrap(found, [])
}

/// The language ranges in an `accept-language` header, most wanted first.
/// Ranges with `q=0`, and the `*` wildcard, are left out.
pub fn accept_language(header: String) -> List(String) {
  header
  |> string.split(",")
  |> list.index_map(fn(part, index) {
    case string.split(part, ";") {
      [range, ..parameters] -> {
        let quality =
          list.find_map(parameters, fn(parameter) {
            case string.split(string.trim(parameter), "=") {
              ["q", value] | ["Q", value] -> parse_quality(value)
              _ -> Error(Nil)
            }
          })
          |> result.unwrap(1.0)
        #(string.trim(range), quality, index)
      }
      [] -> #("", 0.0, index)
    }
  })
  |> list.filter(fn(item) { item.1 >. 0.0 && item.0 != "" && item.0 != "*" })
  // Most wanted first; equal qualities keep the order they were sent in.
  |> list.sort(fn(a, b) {
    case float.compare(b.1, a.1) {
      order.Eq -> int.compare(a.2, b.2)
      other -> other
    }
  })
  |> list.map(fn(item) { item.0 })
}

fn parse_quality(value: String) -> Result(Float, Nil) {
  let value = string.trim(value)
  let valid = case string.split(value, ".") {
    ["0"] | ["1"] -> True
    ["0", digits] -> string.length(digits) <= 3 && all_digits(digits)
    ["1", digits] ->
      string.length(digits) <= 3
      && list.all(string.to_graphemes(digits), fn(d) { d == "0" })
    _ -> False
  }
  case valid {
    False -> Ok(0.0)
    True ->
      case float.parse(value), int.parse(value) {
        Ok(quality), _ -> Ok(quality)
        _, Ok(quality) -> Ok(int.to_float(quality))
        _, _ -> Ok(0.0)
      }
  }
}

fn all_digits(text: String) -> Bool {
  string.to_utf_codepoints(text)
  |> list.all(fn(c) {
    let c = string.utf_codepoint_to_int(c)
    c >= 48 && c <= 57
  })
}

// -- Responses ---------------------------------------------------------------

/// Stamp every response with `content-language`, unless the handler set
/// one, and add to `vary` the request headers the negotiator reads, so a
/// shared cache keeps a copy per language.
pub fn middleware(
  negotiator: Negotiator,
) -> fn(Context(Nil), fn(Context(Nil)) -> Response(Content)) ->
  Response(Content) {
  fn(ctx, next) {
    let locale = detect(ctx, negotiator)
    let answer = next(ctx)
    let answer = case response.get_header(answer, "content-language") {
      Ok(_) -> answer
      Error(Nil) ->
        response.set_header(answer, "content-language", to_string(locale))
    }
    list.fold(varies(negotiator), answer, add_vary)
  }
}

fn varies(negotiator: Negotiator) -> List(String) {
  list.filter_map(negotiator.sources, fn(source) {
    case source {
      Cookie(_) -> Ok("cookie")
      Custom(_) -> Ok("*")
      AcceptLanguage -> Ok("accept-language")
      Param(_) | PathSegment | Query(_) -> Error(Nil)
    }
  })
  |> list.unique
}

fn add_vary(answer: Response(body), header: String) -> Response(body) {
  case header, response.get_header(answer, "vary") {
    "*", _ -> response.set_header(answer, "vary", "*")
    _, Error(Nil) -> response.set_header(answer, "vary", header)
    _, Ok(existing) -> {
      let present =
        string.split(existing, ",")
        |> list.any(fn(name) {
          let name = string.lowercase(string.trim(name))
          name == header || name == "*"
        })
      case present {
        True -> answer
        False -> response.set_header(answer, "vary", existing <> ", " <> header)
      }
    }
  }
}

/// Store a visitor's choice in the cookie named by `from_cookie`, for a
/// year. Panics if the negotiator reads no cookie, since the choice would
/// never be read back.
pub fn remember(
  answer: Response(body),
  negotiator: Negotiator,
  locale: Locale,
) -> Response(body) {
  let assert Ok(name) =
    list.find_map(negotiator.sources, fn(source) {
      case source {
        Cookie(name) -> Ok(name)
        _ -> Error(Nil)
      }
    })
    as "locale.remember needs a negotiator with from_cookie"
  // The same attributes as `cookie.defaults()`, which this module cannot
  // import without a cycle through `howdy/problem`.
  let attributes =
    cookie.Attributes(..cookie.defaults(http.Https), max_age: Some(31_536_000))
  response.set_cookie(
    answer,
    name,
    uri.percent_encode(to_string(locale)),
    attributes,
  )
}
