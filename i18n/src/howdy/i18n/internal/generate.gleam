//// Turning catalogues into a Gleam module with a function per message.
////
//// Each function takes a translator and the message's arguments, typed by
//// how the messages use them, and picks the catalogue for the translator:
////
//// ```gleam
//// pub fn cart_items(translator: Translator, count count: Int) -> String {
////   case i18n.pick(translator, ["de", "fr"]) {
////     "de" -> ...
////     "fr" -> ...
////     _ -> ...   // the source catalogue
////   }
//// }
//// ```
////
//// With `standalone`, functions take the catalogue's locale as a string
//// instead and inline the plural rules they need, so the module depends
//// on nothing but the standard library. Only plain arguments, whole
//// numbers and cardinal plurals are allowed then.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import howdy/i18n
import howdy/i18n/internal/catalogue.{type Catalogue}
import howdy/i18n/internal/message.{type Part}
import howdy/i18n/internal/plural_source
import howdy/i18n/plural

pub type Options {
  Options(
    /// The locale every message is written in first.
    source: String,
    standalone: Bool,
    /// Where the catalogues came from, for the generated module's comment.
    origin: String,
  )
}

pub type Report {
  Report(errors: List(String), warnings: List(String), notes: List(String))
}

type Type {
  TString
  TInt
  TFloat
  TDate
  TTime
}

type Message {
  Message(
    key: String,
    function: String,
    arguments: List(#(String, Type)),
    /// The parsed message for each catalogue that has it, the source first.
    versions: List(#(String, List(Part))),
    source_text: String,
  )
}

type Analysis {
  Analysis(messages: List(Message), report: Report, locales: List(String))
}

/// Check catalogues without generating anything.
pub fn check(catalogues: List(Catalogue), options: Options) -> Report {
  analyse(catalogues, options).report
}

/// The module's source, with the report, or the report when there are
/// errors.
pub fn generate(
  catalogues: List(Catalogue),
  options: Options,
) -> Result(#(String, Report), Report) {
  let analysis = analyse(catalogues, options)
  case analysis.report.errors {
    [] -> Ok(#(render(analysis, options), analysis.report))
    _ -> Error(analysis.report)
  }
}

// -- Analysis ----------------------------------------------------------------

fn analyse(catalogues: List(Catalogue), options: Options) -> Analysis {
  let empty = Analysis([], Report([], [], []), [])
  case list.find(catalogues, fn(c) { c.locale == options.source }) {
    Error(Nil) ->
      Analysis(
        ..empty,
        report: Report(..empty.report, errors: [
          "there is no catalogue for the source locale "
          <> options.source
          <> ": add "
          <> options.source
          <> ".json",
        ]),
      )
    Ok(source) -> {
      let translations =
        list.filter(catalogues, fn(c) { c.locale != options.source })
      // Parse everything first, keeping the errors.
      let parsed =
        list.map(catalogues, fn(c) {
          #(
            c.locale,
            list.map(c.messages, fn(entry) {
              #(entry.0, message.parse(entry.1))
            }),
          )
        })
      let parse_errors =
        list.flat_map(catalogues, fn(c) {
          let assert Ok(entries) = list.key_find(parsed, c.locale)
          list.filter_map(entries, fn(entry) {
            case entry.1 {
              Error(problem) -> Ok(c.file <> ": " <> entry.0 <> ": " <> problem)
              Ok(_) -> Error(Nil)
            }
          })
        })
      let file_errors =
        list.filter_map(catalogues, fn(c) {
          case catalogue.valid_locale(c.locale) {
            True -> Error(Nil)
            False ->
              Ok(c.file <> " is not named by a locale tag such as de or pt-BR")
          }
        })
      let locale_errors =
        catalogues
        |> list.group(fn(c) { i18n.canonical(c.locale) })
        |> dict.to_list
        |> list.filter_map(fn(group) {
          case group.1 {
            [_, _, ..] ->
              Ok(
                "the catalogues "
                <> string.join(list.map(group.1, fn(c) { c.file }), " and ")
                <> " share the locale "
                <> group.0,
              )
            _ -> Error(Nil)
          }
        })
        |> list.sort(string.compare)
      let parts_of = fn(locale, key) {
        list.key_find(parsed, locale)
        |> result.try(list.key_find(_, key))
        |> result.try(result.replace_error(_, Nil))
      }
      let source_keys = list.map(source.messages, fn(entry) { entry.0 })
      let #(messages, message_errors, message_warnings) =
        list.fold(source.messages, #([], [], []), fn(acc, entry) {
          let #(messages, errors, warnings) = acc
          let #(key, text) = entry
          case parts_of(source.locale, key) {
            Error(Nil) -> acc
            Ok(source_parts) -> {
              let versions =
                list.filter_map(translations, fn(c) {
                  parts_of(c.locale, key)
                  |> result.map(fn(p) { #(c.locale, p) })
                })
              let versions = [#(source.locale, source_parts), ..versions]
              let file = fn(locale) {
                list.find(catalogues, fn(c) { c.locale == locale })
                |> result.map(fn(c) { c.file })
                |> result.unwrap(locale)
              }
              let #(arguments, type_errors) =
                argument_types(key, versions, file, options)
              let plural_warnings =
                list.flat_map(versions, fn(version) {
                  plural_warnings(file(version.0), key, version.0, version.1)
                })
              let message =
                Message(
                  key:,
                  function: function_name(key),
                  arguments:,
                  versions:,
                  source_text: text,
                )
              #(
                [message, ..messages],
                list.append(errors, type_errors),
                list.append(warnings, plural_warnings),
              )
            }
          }
        })
      let messages = list.reverse(messages)
      let name_errors = duplicate_names(messages, options)
      let coverage =
        list.flat_map(translations, fn(c) {
          let keys = list.map(c.messages, fn(entry) { entry.0 })
          let missing =
            list.filter(source_keys, fn(k) { !list.contains(keys, k) })
          let extra =
            list.filter(keys, fn(k) { !list.contains(source_keys, k) })
          list.flatten([
            case missing {
              [] -> []
              _ -> [
                c.file
                <> " is missing "
                <> count(missing, "message")
                <> ", which fall back: "
                <> string.join(missing, ", "),
              ]
            },
            case extra {
              [] -> []
              _ -> [
                c.file
                <> " has "
                <> count(extra, "message")
                <> " the source does not, which are ignored: "
                <> string.join(extra, ", "),
              ]
            },
          ])
        })
      let notes =
        list.filter_map(catalogues, fn(c) {
          case c.review {
            Some(review) -> Ok(c.file <> " needs review: " <> review)
            None -> Error(Nil)
          }
        })
      Analysis(
        messages:,
        locales: list.map(catalogues, fn(c) { c.locale }),
        report: Report(
          errors: list.flatten([
            file_errors,
            locale_errors,
            parse_errors,
            message_errors,
            name_errors,
          ]),
          warnings: list.append(coverage, message_warnings),
          notes:,
        ),
      )
    }
  }
}

fn count(items: List(a), noun: String) -> String {
  case list.length(items) {
    1 -> "1 " <> noun
    n -> int.to_string(n) <> " " <> noun <> "s"
  }
}

/// Each argument's type, from how every version of the message uses it.
fn argument_types(
  key: String,
  versions: List(#(String, List(Part))),
  file: fn(String) -> String,
  options: Options,
) -> #(List(#(String, Type)), List(String)) {
  let assert [#(source_locale, source_parts), ..] = versions
  let source_names =
    message.arguments(source_parts) |> list.map(fn(a) { a.0 }) |> list.unique
  let unknown =
    list.flat_map(versions, fn(version) {
      message.arguments(version.1)
      |> list.map(fn(a) { a.0 })
      |> list.unique
      |> list.filter(fn(name) { !list.contains(source_names, name) })
      |> list.map(fn(name) {
        file(version.0)
        <> ": "
        <> key
        <> ": uses {"
        <> name
        <> "}, which the "
        <> source_locale
        <> " message does not"
      })
    })
  let uses =
    list.flat_map(versions, fn(version) { message.arguments(version.1) })
  let resolved =
    list.map(source_names, fn(name) {
      let kinds =
        list.filter_map(uses, fn(u) {
          case u.0 == name {
            True -> Ok(u.1)
            False -> Error(Nil)
          }
        })
        |> list.unique
      #(name, resolve(kinds))
    })
  let type_errors =
    list.filter_map(resolved, fn(r) {
      case r.1 {
        Ok(_) -> Error(Nil)
        Error(conflict) -> Ok(key <> ": {" <> r.0 <> "} " <> conflict)
      }
    })
  let types =
    list.filter_map(resolved, fn(r) { result.map(r.1, fn(t) { #(r.0, t) }) })
  let standalone_errors = case options.standalone {
    False -> []
    True ->
      list.flat_map(versions, fn(version) {
        standalone_problems(version.1)
        |> list.map(fn(problem) {
          file(version.0) <> ": " <> key <> ": " <> problem
        })
      })
      |> list.append(
        list.filter_map(types, fn(t) {
          case t.1 {
            TString | TInt -> Error(Nil)
            _ ->
              Ok(
                key
                <> ": {"
                <> t.0
                <> "} is not a string or whole number, which --standalone needs",
              )
          }
        }),
      )
  }
  let labels = list.group(types, fn(argument) { label(argument.0) })
  let label_errors =
    dict.to_list(labels)
    |> list.filter_map(fn(group) {
      case group.0, group.1 {
        "", _ -> Ok(key <> ": an argument has no letters or digits in its name")
        name, [_, _, ..] ->
          Ok(key <> ": arguments would share the label " <> name)
        name, _ ->
          case is_digit_start(name) {
            True ->
              Ok(
                key
                <> ": the argument label "
                <> name
                <> " must start with a letter",
              )
            False -> Error(Nil)
          }
      }
    })
    |> list.sort(string.compare)
  #(
    types,
    list.flatten([unknown, type_errors, standalone_errors, label_errors]),
  )
}

fn standalone_problems(parts: List(Part)) -> List(String) {
  list.flat_map(parts, fn(part) {
    case part {
      message.Plural(ordinal: True, ..) -> [
        "selectordinal is not supported with --standalone",
      ]
      message.Number(_, message.Percent) -> [
        "percent is not supported with --standalone",
      ]
      message.Date(..) | message.Time(..) -> [
        "dates and times are not supported with --standalone",
      ]
      _ -> []
    }
    |> list.append(case part {
      message.Plural(cases:, ..) ->
        list.flat_map(cases, fn(c) { standalone_problems(c.1) })
      message.Select(cases:, ..) ->
        list.flat_map(cases, fn(c) { standalone_problems(c.1) })
      _ -> []
    })
  })
}

fn resolve(uses: List(message.Use)) -> Result(Type, String) {
  let typed =
    list.filter_map(uses, fn(u) {
      case u {
        message.AsText -> Error(Nil)
        message.AsSelect -> Ok(TString)
        message.AsInt -> Ok(TInt)
        message.AsFloat -> Ok(TFloat)
        message.AsDate -> Ok(TDate)
        message.AsTime -> Ok(TTime)
      }
    })
    |> list.unique
  case typed {
    [] -> Ok(TString)
    [only] -> Ok(only)
    _ ->
      Error(
        "is used as "
        <> string.join(list.map(typed, describe_type), " and as ")
        <> "; it must have one type",
      )
  }
}

fn describe_type(t: Type) -> String {
  case t {
    TString -> "text"
    TInt -> "a whole number"
    TFloat -> "a percentage"
    TDate -> "a date"
    TTime -> "a time"
  }
}

fn plural_warnings(
  file: String,
  key: String,
  locale: String,
  parts: List(Part),
) -> List(String) {
  message.plurals(parts)
  |> list.flat_map(fn(part) {
    let assert message.Plural(name:, ordinal:, cases:, ..) = part
    let needed = case ordinal {
      True -> plural.ordinal_categories(locale)
      False -> plural.cardinal_categories(locale)
    }
    let given =
      list.filter_map(cases, fn(c) {
        case c.0 {
          message.Category(name) -> plural.from_string(name)
          message.Exact(_) -> Error(Nil)
        }
      })
    needed
    |> list.filter(fn(category) { !list.contains(given, category) })
    |> list.map(fn(category) {
      file
      <> ": "
      <> key
      <> ": {"
      <> name
      <> "} has no "
      <> plural.to_string(category)
      <> " case, which "
      <> locale
      <> " uses, so other is used instead"
    })
  })
}

fn duplicate_names(messages: List(Message), options: Options) -> List(String) {
  let helpers = case options.standalone {
    False -> []
    True ->
      list.flat_map(messages, fn(message) {
        list.filter_map(message.versions, fn(version) {
          case message.plurals(version.1) {
            [] -> Error(Nil)
            _ -> Ok(plural_function(version.0))
          }
        })
      })
      |> list.unique
  }
  let reserved = ["locales", "source", ..helpers]
  let reserved_errors =
    list.filter_map(messages, fn(message) {
      case list.contains(reserved, message.function) {
        True ->
          Ok(
            "the key "
            <> message.key
            <> " would become the reserved generated name "
            <> message.function,
          )
        False -> Error(Nil)
      }
    })
  messages
  |> list.group(fn(m) { m.function })
  |> dict.to_list
  |> list.filter_map(fn(group) {
    case group.1 {
      [_, _, ..] ->
        Ok(
          "the keys "
          <> string.join(
            list.reverse(list.map(group.1, fn(m) { m.key })),
            " and ",
          )
          <> " would both become the function "
          <> group.0,
        )
      _ -> Error(Nil)
    }
  })
  |> list.append(reserved_errors)
  |> list.sort(string.compare)
}

/// A key as a Gleam function name: `cart.items` and `cartItems` both
/// become `cart_items`.
pub fn function_name(key: String) -> String {
  let name = snake_case(key)
  case name {
    "" -> "message"
    _ ->
      case is_digit_start(name) || list.contains(reserved, name) {
        True -> "message_" <> name
        False -> name
      }
  }
}

/// An argument as a Gleam label.
fn label(name: String) -> String {
  let label = snake_case(name)
  case
    is_digit_start(label)
    || list.contains(reserved, label)
    || label == "translator"
    || label == "locale"
  {
    True -> label <> "_"
    False -> label
  }
}

fn snake_case(text: String) -> String {
  string.to_graphemes(text)
  |> list.fold(#([], False), fn(acc, g) {
    let #(out, previous_lower) = acc
    let lower = string.lowercase(g)
    case is_alphanumeric(g) {
      False -> #(["_", ..out], False)
      True ->
        case lower != g && previous_lower {
          True -> #([lower, "_", ..out], False)
          False -> #([lower, ..out], lower == g && !is_digit(g) || is_digit(g))
        }
    }
  })
  |> fn(acc) { acc.0 }
  |> list.reverse
  |> string.concat
  |> collapse_underscores
}

fn collapse_underscores(text: String) -> String {
  let collapsed = string.replace(text, "__", "_")
  case collapsed == text {
    True ->
      text
      |> trim_underscore_start
      |> trim_underscore_end
    False -> collapse_underscores(collapsed)
  }
}

fn trim_underscore_start(text: String) -> String {
  case text {
    "_" <> rest -> trim_underscore_start(rest)
    _ -> text
  }
}

fn trim_underscore_end(text: String) -> String {
  case string.ends_with(text, "_") {
    True -> trim_underscore_end(string.drop_end(text, 1))
    False -> text
  }
}

fn is_alphanumeric(g: String) -> Bool {
  case string.to_utf_codepoints(g) {
    [c] -> {
      let c = string.utf_codepoint_to_int(c)
      { c >= 65 && c <= 90 }
      || { c >= 97 && c <= 122 }
      || { c >= 48 && c <= 57 }
    }
    _ -> False
  }
}

fn is_digit(g: String) -> Bool {
  case string.to_utf_codepoints(g) {
    [c] -> {
      let c = string.utf_codepoint_to_int(c)
      c >= 48 && c <= 57
    }
    _ -> False
  }
}

fn is_digit_start(text: String) -> Bool {
  string.first(text) |> result.map(is_digit) |> result.unwrap(False)
}

const reserved = [
  "as", "assert", "auto", "case", "const", "delegate", "derive", "echo", "else",
  "fn", "if", "implement", "import", "let", "macro", "opaque", "panic", "pub",
  "test", "todo", "type", "use",
]

// -- Rendering ---------------------------------------------------------------

type Needs {
  Needs(format: Bool, plural: Bool, int: Bool, calendar: Bool)
}

fn render(analysis: Analysis, options: Options) -> String {
  let messages =
    list.sort(analysis.messages, fn(a, b) {
      string.compare(a.function, b.function)
    })
  let rendered = list.map(messages, render_function(_, options))
  let needs =
    list.fold(rendered, Needs(False, False, False, False), fn(acc, r) {
      Needs(
        format: acc.format || r.1.format,
        plural: acc.plural || r.1.plural,
        int: acc.int || r.1.int,
        calendar: acc.calendar || r.1.calendar,
      )
    })
  let plural_locales = case options.standalone {
    False -> []
    True ->
      messages
      |> list.flat_map(fn(m) {
        list.filter_map(m.versions, fn(v) {
          case message.plurals(v.1) {
            [] -> Error(Nil)
            _ -> Ok(v.0)
          }
        })
      })
      |> list.unique
      |> list.sort(string.compare)
  }
  let locales = list.sort(analysis.locales, string.compare)
  let imports =
    list.flatten([
      case needs.int || plural_locales != [] {
        True -> ["import gleam/int"]
        False -> []
      },
      case needs.calendar {
        True -> ["import gleam/time/calendar"]
        False -> []
      },
      case options.standalone {
        True -> []
        False -> ["import howdy/i18n.{type Translator}"]
      },
      case needs.format {
        True -> ["import howdy/i18n/format"]
        False -> []
      },
      case needs.plural {
        True -> ["import howdy/i18n/plural"]
        False -> []
      },
    ])
  let header =
    "//// Messages from "
    <> comment_line(options.origin)
    <> ", generated by howdy_i18n. Do not edit:\n"
    <> "//// change the catalogues and run `gleam run -m howdy/i18n/cli gen`.\n"
  let consts =
    "/// The locales with catalogues.\npub const locales = ["
    <> string.join(list.map(locales, literal), ", ")
    <> "]\n\n/// The locale every message is written in first.\npub const source = "
    <> literal(options.source)
    <> "\n"
  let helpers =
    list.map(plural_locales, fn(locale) {
      let body = plural_source.cardinal(locale) |> result.unwrap("\"other\"")
      let uses_n = body != "\"other\""
      "fn "
      <> plural_function(locale)
      <> "(n: Int) -> String {\n  "
      <> case uses_n {
        True -> "let n = int.absolute_value(n)\n  "
        False -> "let _ = n\n  "
      }
      <> string.replace(body, "\n", "\n  ")
      <> "\n}\n"
    })
  string.join(
    list.flatten([
      [header],
      case imports {
        [] -> []
        _ -> [string.join(imports, "\n") <> "\n"]
      },
      [consts],
      list.map(rendered, fn(r) { r.0 }),
      helpers,
    ]),
    "\n",
  )
}

fn plural_function(locale: String) -> String {
  "cardinal_" <> string.replace(string.lowercase(locale), "-", "_")
}

fn render_function(message: Message, options: Options) -> #(String, Needs) {
  let types = dict.from_list(message.arguments)
  let parameters =
    list.map(message.arguments, fn(a) {
      label(a.0) <> " " <> label(a.0) <> ": " <> gleam_type(a.1)
    })
  let needs =
    Needs(
      format: False,
      plural: False,
      int: False,
      calendar: list.any(message.arguments, fn(a) {
        a.1 == TDate || a.1 == TTime
      }),
    )
  let assert [source, ..translations] = message.versions
  let #(source_code, needs) =
    expression(source.1, source.0, types, options, needs)
  let #(arms, needs) =
    list.fold(translations, #([], needs), fn(acc, version) {
      let #(code, needs) =
        expression(version.1, version.0, types, options, acc.1)
      #([#(version.0, code), ..acc.0], needs)
    })
  let arms = list.reverse(arms)
  let used = arms != [] || { needs.format && !options.standalone }
  let first = case options.standalone, used {
    True, True -> "locale: String"
    True, False -> "_locale: String"
    False, True -> "translator: Translator"
    False, False -> "_translator: Translator"
  }
  let signature =
    "pub fn "
    <> message.function
    <> "(\n  "
    <> string.join([first, ..parameters], ",\n  ")
    <> ",\n) -> String {\n"
  let body = case arms {
    [] -> "  " <> indent(source_code, 1) <> "\n"
    _ -> {
      let chooser = case options.standalone {
        True -> "locale"
        False ->
          // The source is offered too, so a locale closer to it than to
          // any translation, such as en-US beside en and en-GB, gets it.
          "i18n.pick(translator, ["
          <> string.join(
            list.map(arms, fn(arm) { literal(arm.0) })
              |> list.append([literal(source.0)]),
            ", ",
          )
          <> "])"
      }
      "  case "
      <> chooser
      <> " {\n"
      <> string.concat(
        list.map(arms, fn(arm) {
          "    " <> literal(arm.0) <> " -> " <> indent(arm.1, 2) <> "\n"
        }),
      )
      <> "    _ -> "
      <> indent(source_code, 2)
      <> "\n  }\n"
    }
  }
  let doc =
    "/// "
    <> comment_line(message.key)
    <> ": "
    <> comment_line(message.source_text)
    <> "\n"
  #(doc <> signature <> body <> "}\n", needs)
}

fn comment_line(text: String) -> String {
  text |> string.replace("\n", " ") |> string.replace("\r", " ")
}

fn indent(code: String, levels: Int) -> String {
  string.replace(code, "\n", "\n" <> string.repeat("  ", levels))
}

fn gleam_type(t: Type) -> String {
  case t {
    TString -> "String"
    TInt -> "Int"
    TFloat -> "Float"
    TDate -> "calendar.Date"
    TTime -> "calendar.TimeOfDay"
  }
}

fn expression(
  parts: List(Part),
  locale: String,
  types: Dict(String, Type),
  options: Options,
  needs: Needs,
) -> #(String, Needs) {
  let #(pieces, needs) =
    list.fold(parts, #([], needs), fn(acc, part) {
      let #(code, needs) = piece(part, locale, types, options, acc.1)
      #([code, ..acc.0], needs)
    })
  case list.reverse(pieces) {
    [] -> #("\"\"", needs)
    [only] -> #(only, needs)
    // A case among other pieces goes in a block.
    pieces ->
      pieces
      |> list.map(fn(piece) {
        case string.starts_with(piece, "case ") {
          True -> "{\n  " <> indent(piece, 1) <> "\n}"
          False -> piece
        }
      })
      |> string.join(" <> ")
      |> fn(code) { #(code, needs) }
  }
}

fn piece(
  part: Part,
  locale: String,
  types: Dict(String, Type),
  options: Options,
  needs: Needs,
) -> #(String, Needs) {
  let type_of = fn(name) { dict.get(types, name) |> result.unwrap(TString) }
  let formatted = fn(call, needs: Needs) {
    #(call, Needs(..needs, format: True))
  }
  let whole = fn(code, needs: Needs) {
    case options.standalone {
      True -> #("int.to_string(" <> code <> ")", Needs(..needs, int: True))
      False -> formatted("format.integer(translator, " <> code <> ")", needs)
    }
  }
  case part {
    message.Text(text) -> #(literal(text), needs)
    message.Argument(name) ->
      case type_of(name) {
        TString -> #(label(name), needs)
        TInt -> whole(label(name), needs)
        TFloat ->
          formatted("format.percent(translator, " <> label(name) <> ")", needs)
        TDate ->
          formatted(
            "format.date(translator, " <> label(name) <> ", format.Medium)",
            needs,
          )
        TTime ->
          formatted(
            "format.time(translator, " <> label(name) <> ", format.Short)",
            needs,
          )
      }
    message.Number(name, message.Integer) -> whole(label(name), needs)
    message.Number(name, message.Percent) ->
      formatted("format.percent(translator, " <> label(name) <> ")", needs)
    message.Date(name, style) ->
      formatted(
        "format.date(translator, "
          <> label(name)
          <> ", format."
          <> style_name(style)
          <> ")",
        needs,
      )
    message.Time(name, style) ->
      formatted(
        "format.time(translator, "
          <> label(name)
          <> ", format."
          <> style_name(style)
          <> ")",
        needs,
      )
    message.Pound(name:, offset:) -> whole(minus(label(name), offset), needs)
    message.Select(name:, cases:) -> {
      let #(arms, needs) =
        list.fold(cases, #([], needs), fn(acc, c) {
          let #(code, needs) = expression(c.1, locale, types, options, acc.1)
          let pattern = case c.0 {
            "other" -> "_"
            value -> literal(value)
          }
          #([#(pattern, code), ..acc.0], needs)
        })
      #(case_block(label(name), order_arms(list.reverse(arms))), needs)
    }
    message.Plural(name:, ordinal:, offset:, cases:) -> {
      let variable = label(name)
      let #(exact, needs) =
        list.fold(cases, #([], needs), fn(acc, c) {
          case c.0 {
            message.Exact(value) -> {
              let #(code, needs) =
                expression(c.1, locale, types, options, acc.1)
              #([#(int.to_string(value), code), ..acc.0], needs)
            }
            message.Category(_) -> acc
          }
        })
      let #(categories, needs) =
        list.fold(cases, #([], needs), fn(acc, c) {
          case c.0 {
            message.Category(category) -> {
              let #(code, needs) =
                expression(c.1, locale, types, options, acc.1)
              let pattern = case category, options.standalone {
                "other", _ -> "_"
                _, True -> literal(category)
                _, False -> "plural." <> capitalise(category)
              }
              #([#(pattern, code), ..acc.0], needs)
            }
            message.Exact(_) -> acc
          }
        })
      let subject = case options.standalone {
        True -> plural_function(locale) <> "(" <> minus(variable, offset) <> ")"
        False ->
          "plural."
          <> case ordinal {
            True -> "ordinal"
            False -> "cardinal"
          }
          <> "("
          <> literal(locale)
          <> ", "
          <> minus(variable, offset)
          <> ")"
      }
      let needs = case options.standalone {
        True -> needs
        False -> Needs(..needs, plural: True)
      }
      let by_category = case order_arms(list.reverse(categories)) {
        [#("_", only)] -> only
        arms -> case_block(subject, arms)
      }
      case list.reverse(exact) {
        [] -> #(by_category, needs)
        exact -> #(
          case_block(variable, list.append(exact, [#("_", by_category)])),
          needs,
        )
      }
    }
  }
}

/// Put the catch-all arm last, where Gleam needs it.
fn order_arms(arms: List(#(String, String))) -> List(#(String, String)) {
  let #(other, rest) = list.partition(arms, fn(arm) { arm.0 == "_" })
  list.append(rest, other)
}

fn case_block(subject: String, arms: List(#(String, String))) -> String {
  "case "
  <> subject
  <> " {\n"
  <> string.concat(
    list.map(arms, fn(arm) {
      "  " <> arm.0 <> " -> " <> indent(arm.1, 1) <> "\n"
    }),
  )
  <> "}"
}

fn minus(variable: String, offset: Int) -> String {
  case offset {
    0 -> variable
    _ -> variable <> " - " <> int.to_string(offset)
  }
}

fn style_name(style: String) -> String {
  capitalise(style)
}

fn capitalise(text: String) -> String {
  string.uppercase(string.slice(text, 0, 1)) <> string.drop_start(text, 1)
}

/// A Gleam string literal.
pub fn literal(text: String) -> String {
  "\""
  <> {
    text
    |> string.replace("\\", "\\\\")
    |> string.replace("\"", "\\\"")
    |> string.replace("\n", "\\n")
    |> string.replace("\r", "\\r")
    |> string.replace("\t", "\\t")
  }
  <> "\""
}
