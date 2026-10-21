//// A parser for ICU MessageFormat, the syntax catalogue messages use.
////
//// ```text
//// Hello, {name}!
//// {count, plural, =0 {No items} one {# item} other {# items}}
//// {gender, select, female {She} male {He} other {They}} replied.
//// You came {place, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}.
//// Saved {when, date, long} at {when_time, time, short}.
//// {ratio, number, percent} done.
//// ```
////
//// An apostrophe quotes syntax characters: `'{'` is a literal brace, and
//// `''` is an apostrophe. An apostrophe before anything else is itself.

import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub type Part {
  Text(String)
  /// `{name}`.
  Argument(name: String)
  /// `{name, number}`, `{name, number, integer}` or
  /// `{name, number, percent}`.
  Number(name: String, style: NumberStyle)
  /// `{name, date}` or `{name, date, short|medium|long|full}`.
  Date(name: String, style: String)
  /// `{name, time}` or `{name, time, short|medium|long|full}`.
  Time(name: String, style: String)
  /// `{name, plural, ...}`, or with `ordinal` `{name, selectordinal, ...}`.
  Plural(
    name: String,
    ordinal: Bool,
    offset: Int,
    cases: List(#(Selector, List(Part))),
  )
  /// `{name, select, ...}`.
  Select(name: String, cases: List(#(String, List(Part))))
  /// `#` inside a plural: the number, less any offset.
  Pound(name: String, offset: Int)
}

pub type NumberStyle {
  Integer
  Percent
}

pub type Selector {
  /// `=0`.
  Exact(Int)
  /// `one`, `few`, `other` and so on.
  Category(String)
}

type Plain {
  Plain(name: String, offset: Int)
}

pub fn parse(source: String) -> Result(List(Part), String) {
  case parse_parts(string.to_graphemes(source), 0, Error(Nil), []) {
    Ok(#(parts, [])) -> Ok(parts)
    Ok(#(_, ["}", ..])) -> Error("unexpected }")
    Ok(#(_, _)) -> Error("unexpected text after the message")
    Error(message) -> Error(message)
  }
}

/// Parse until the end, or a `}` closing this level, which is left in place.
fn parse_parts(
  input: List(String),
  depth: Int,
  plural: Result(Plain, Nil),
  acc: List(Part),
) -> Result(#(List(Part), List(String)), String) {
  case input {
    [] ->
      case depth {
        0 -> Ok(#(finish(acc), []))
        _ -> Error("a { is never closed")
      }
    ["}", ..] ->
      case depth {
        0 -> Error("unexpected }")
        _ -> Ok(#(finish(acc), input))
      }
    ["{", ..rest] -> {
      use #(part, rest) <- result.try(parse_argument(rest, depth, plural))
      parse_parts(rest, depth, plural, [part, ..acc])
    }
    ["#", ..rest] ->
      case plural {
        Ok(Plain(name:, offset:)) ->
          parse_parts(rest, depth, plural, [Pound(name:, offset:), ..acc])
        Error(Nil) -> parse_parts(rest, depth, plural, add_text(acc, "#"))
      }
    ["'", "'", ..rest] -> parse_parts(rest, depth, plural, add_text(acc, "'"))
    ["'", next, ..rest] ->
      case
        next == "{"
        || next == "}"
        || next == "|"
        || { next == "#" && result.is_ok(plural) }
      {
        True -> {
          let #(quoted, rest) = take_quoted([next, ..rest], "")
          parse_parts(rest, depth, plural, add_text(acc, quoted))
        }
        False -> parse_parts([next, ..rest], depth, plural, add_text(acc, "'"))
      }
    [g, ..rest] -> parse_parts(rest, depth, plural, add_text(acc, g))
  }
}

fn take_quoted(input: List(String), acc: String) -> #(String, List(String)) {
  case input {
    [] -> #(acc, [])
    ["'", "'", ..rest] -> take_quoted(rest, acc <> "'")
    ["'", ..rest] -> #(acc, rest)
    [g, ..rest] -> take_quoted(rest, acc <> g)
  }
}

fn add_text(acc: List(Part), text: String) -> List(Part) {
  case acc {
    [Text(previous), ..rest] -> [Text(previous <> text), ..rest]
    _ -> [Text(text), ..acc]
  }
}

fn finish(acc: List(Part)) -> List(Part) {
  list.reverse(acc)
}

/// After a `{`: the argument up to and including its `}`.
fn parse_argument(
  input: List(String),
  depth: Int,
  plural: Result(Plain, Nil),
) -> Result(#(Part, List(String)), String) {
  let input = skip_space(input)
  let #(name, input) = take_word(input)
  use <- guard(name == "", "an argument needs a name")
  let input = skip_space(input)
  case input {
    ["}", ..rest] -> Ok(#(Argument(name), rest))
    [",", ..rest] -> {
      let #(kind, rest) = take_word(skip_space(rest))
      let rest = skip_space(rest)
      case kind {
        "number" | "date" | "time" -> {
          use #(style, rest) <- result.try(simple_style(rest))
          case kind, style {
            "number", "" | "number", "integer" ->
              Ok(#(Number(name, Integer), rest))
            "number", "percent" -> Ok(#(Number(name, Percent), rest))
            "number", _ ->
              Error(
                "number style "
                <> style
                <> " is not supported: use integer or percent",
              )
            _, "" -> Ok(#(date_or_time(kind, name, "medium"), rest))
            _, "short" | _, "medium" | _, "long" | _, "full" ->
              Ok(#(date_or_time(kind, name, style), rest))
            _, _ ->
              Error(
                kind
                <> " style "
                <> style
                <> " is not supported: use short, medium, long or full",
              )
          }
        }
        "plural" | "selectordinal" -> {
          use rest <- result.try(expect(rest, ","))
          use #(offset, rest) <- result.try(take_offset(skip_space(rest)))
          let inner = Ok(Plain(name:, offset:))
          use #(cases, rest) <- result.try(
            parse_cases(rest, depth, inner, parse_selector, []),
          )
          use <- guard(
            !list.any(cases, fn(c) { c.0 == Category("other") }),
            "the plural " <> name <> " needs an other case",
          )
          Ok(#(
            Plural(name:, ordinal: kind == "selectordinal", offset:, cases:),
            rest,
          ))
        }
        "select" -> {
          use rest <- result.try(expect(rest, ","))
          use #(cases, rest) <- result.try(
            parse_cases(rest, depth, plural, fn(word) { Ok(word) }, []),
          )
          use <- guard(
            !list.any(cases, fn(c) { c.0 == "other" }),
            "the select " <> name <> " needs an other case",
          )
          Ok(#(Select(name:, cases:), rest))
        }
        "" -> Error("expected an argument type after the comma in {" <> name)
        _ -> Error("unknown argument type " <> kind)
      }
    }
    _ -> Error("expected } or , after the argument name " <> name)
  }
}

fn date_or_time(kind: String, name: String, style: String) -> Part {
  case kind {
    "date" -> Date(name, style)
    _ -> Time(name, style)
  }
}

fn simple_style(
  input: List(String),
) -> Result(#(String, List(String)), String) {
  case input {
    ["}", ..rest] -> Ok(#("", rest))
    [",", ..rest] -> {
      let #(style, rest) = take_word(skip_space(rest))
      case skip_space(rest) {
        ["}", ..rest] -> Ok(#(style, rest))
        _ -> Error("expected } after the style " <> style)
      }
    }
    _ -> Error("expected } or , in an argument")
  }
}

fn parse_selector(word: String) -> Result(Selector, String) {
  case word {
    "=" <> number ->
      int.parse(number)
      |> result.map(Exact)
      |> result.replace_error("invalid selector " <> word)
    "zero" | "one" | "two" | "few" | "many" | "other" -> Ok(Category(word))
    _ -> Error("unknown plural category " <> word)
  }
}

fn parse_cases(
  input: List(String),
  depth: Int,
  plural: Result(Plain, Nil),
  selector: fn(String) -> Result(s, String),
  acc: List(#(s, List(Part))),
) -> Result(#(List(#(s, List(Part))), List(String)), String) {
  let input = skip_space(input)
  case input {
    ["}", ..rest] ->
      case acc {
        [] -> Error("expected at least one case")
        _ -> Ok(#(list.reverse(acc), rest))
      }
    _ -> {
      let #(word, rest) = take_selector(input, "")
      use <- guard(word == "", "expected a case such as other {...}")
      use key <- result.try(selector(word))
      use <- guard(
        list.any(acc, fn(c) { c.0 == key }),
        "duplicate case " <> word,
      )
      use rest <- result.try(expect(skip_space(rest), "{"))
      use #(parts, rest) <- result.try(parse_parts(rest, depth + 1, plural, []))
      use rest <- result.try(expect(rest, "}"))
      parse_cases(rest, depth, plural, selector, [#(key, parts), ..acc])
    }
  }
}

fn take_selector(input: List(String), acc: String) -> #(String, List(String)) {
  case input {
    [g, ..rest] if g != "{" && g != "}" && g != " " && g != "\n" && g != "\t" ->
      take_selector(rest, acc <> g)
    _ -> #(acc, input)
  }
}

fn take_offset(input: List(String)) -> Result(#(Int, List(String)), String) {
  case input {
    ["o", "f", "f", "s", "e", "t", ":", ..rest] -> {
      let rest = skip_space(rest)
      let digits = list.take_while(rest, is_digit)
      let rest = list.drop(rest, list.length(digits))
      use offset <- result.try(
        int.parse(string.concat(digits))
        |> result.replace_error("offset: needs a non-negative whole number"),
      )
      Ok(#(offset, skip_space(rest)))
    }
    _ -> Ok(#(0, input))
  }
}

fn expect(input: List(String), wanted: String) -> Result(List(String), String) {
  case input {
    [g, ..rest] if g == wanted -> Ok(rest)
    [g, ..] -> Error("expected " <> wanted <> " but found " <> g)
    [] -> Error("expected " <> wanted <> " but the message ended")
  }
}

fn take_word(input: List(String)) -> #(String, List(String)) {
  let word = list.take_while(input, is_word)
  #(string.concat(word), list.drop(input, list.length(word)))
}

fn skip_space(input: List(String)) -> List(String) {
  list.drop_while(input, fn(g) {
    g == " " || g == "\n" || g == "\t" || g == "\r"
  })
}

fn is_word(g: String) -> Bool {
  case string.to_utf_codepoints(g) {
    [c] -> {
      let c = string.utf_codepoint_to_int(c)
      { c >= 65 && c <= 90 }
      || { c >= 97 && c <= 122 }
      || { c >= 48 && c <= 57 }
      || c == 95
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

fn guard(
  failed: Bool,
  message: String,
  next: fn() -> Result(a, String),
) -> Result(a, String) {
  case failed {
    True -> Error(message)
    False -> next()
  }
}

/// Every argument a message uses, with how it is used, in the order they
/// first appear.
pub fn arguments(parts: List(Part)) -> List(#(String, Use)) {
  list.flat_map(parts, fn(part) {
    case part {
      Text(_) | Pound(..) -> []
      Argument(name) -> [#(name, AsText)]
      Number(name, Integer) -> [#(name, AsInt)]
      Number(name, Percent) -> [#(name, AsFloat)]
      Date(name, _) -> [#(name, AsDate)]
      Time(name, _) -> [#(name, AsTime)]
      Plural(name:, cases:, ..) -> [
        #(name, AsInt),
        ..list.flat_map(cases, fn(c) { arguments(c.1) })
      ]
      Select(name:, cases:) -> [
        #(name, AsSelect),
        ..list.flat_map(cases, fn(c) { arguments(c.1) })
      ]
    }
  })
}

pub type Use {
  /// `{name}`: any type, written as text.
  AsText
  /// A select: a String.
  AsSelect
  AsInt
  AsFloat
  AsDate
  AsTime
}

/// Every plural in a message, nested ones included.
pub fn plurals(parts: List(Part)) -> List(Part) {
  list.flat_map(parts, fn(part) {
    case part {
      Plural(cases:, ..) -> [
        part,
        ..list.flat_map(cases, fn(c) { plurals(c.1) })
      ]
      Select(cases:, ..) -> list.flat_map(cases, fn(c) { plurals(c.1) })
      _ -> []
    }
  })
}
