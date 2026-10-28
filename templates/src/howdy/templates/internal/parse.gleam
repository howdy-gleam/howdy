//// Parses templates. The parser always returns a template, even from
//// broken input, so the language server can keep answering while a file is
//// half typed; what it couldn't make sense of comes back as problems.
////
//// A template is an optional header between `---` lines, holding Gleam
//// code and a `props(...)` declaration, then markup. Markup can also appear
//// inside Gleam code, wherever an expression can start: after `(`, `[`,
//// `{`, `,`, `->`, `=`, an operator or a keyword such as `let`. Elsewhere
//// `<` is the comparison it always was.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import howdy/templates/internal/signatures
import howdy/templates/internal/syntax.{
  type Attribute, type Code, type Function, type Node, type Part, type Piece,
  type Problem, type Prop, type Span, type Template, Attribute, Bare, Code,
  Component, Dynamic, Element, Expression, Fragment, Function, Gleam, Markup,
  Piece, Problem, Prop, Span, Spread, Static, Template, Text,
}

const void_elements = [
  "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
  "source", "track", "wbr",
]

const keywords = ["let", "use", "case", "assert", "echo", "panic", "todo", "as"]

pub fn parse(text: String) -> #(Template, List(Problem)) {
  let source = <<text:utf8>>
  let total = bit_array.byte_size(source)
  let #(header, body_start, problems) = split_header(text)
  let #(imports, header_code, props, problems, header_names) = case header {
    None -> #([], [], [], problems, set.new())
    Some(span) -> {
      let #(imports, code, props, header_problems, names) =
        parse_header(source, span)
      #(imports, code, props, list.append(problems, header_problems), names)
    }
  }
  let state = new_state(source, body_start, total)
  let #(body, state, _) = children(state, Top, False, [])
  // A <style> at the top of the body is the template's own stylesheet.
  let #(styles, body) =
    list.partition(body, fn(node) {
      case node {
        Element(name: Piece("style", _), ..) -> True
        _ -> False
      }
    })
  let styles =
    list.flat_map(styles, fn(node) {
      case node {
        Element(children: Some([Text(css, span)]), ..) -> [Piece(css, span)]
        _ -> []
      }
    })
  #(
    Template(
      imports:,
      header: header_code,
      props:,
      body:,
      styles:,
      uses_children: set.contains(state.names, "children"),
      names: set.union(header_names, state.names),
      functions: functions(header_code),
    ),
    list.append(problems, list.reverse(state.problems)),
  )
}

// STATE -----------------------------------------------------------------------

type State {
  State(
    source: BitArray,
    rest: String,
    offset: Int,
    problems: List(Problem),
    /// Names used in code, other than after a dot.
    names: Set(String),
  )
}

fn new_state(source: BitArray, start: Int, end: Int) -> State {
  State(
    source:,
    rest: slice(source, start, end),
    offset: start,
    problems: [],
    names: set.new(),
  )
}

fn slice(source: BitArray, start: Int, end: Int) -> String {
  bit_array.slice(source, start, end - start)
  |> result.try(bit_array.to_string)
  |> result.unwrap("")
}

fn problem(state: State, message: String, span: Span) -> State {
  State(..state, problems: [Problem(message, span), ..state.problems])
}

/// Consumes an ASCII prefix the caller has already matched.
fn advance(state: State, prefix: String) -> State {
  let size = string.byte_size(prefix)
  State(
    ..state,
    rest: string.drop_start(state.rest, string.length(prefix)),
    offset: state.offset + size,
  )
}

fn pop(state: State) -> Result(#(String, State), Nil) {
  case string.pop_grapheme(state.rest) {
    Ok(#(c, rest)) ->
      Ok(#(c, State(..state, rest:, offset: state.offset + string.byte_size(c))))
    Error(_) -> Error(Nil)
  }
}

fn take_while(state: State, keep: fn(String) -> Bool) -> #(String, State) {
  take_loop(state, keep, [])
}

fn take_loop(
  state: State,
  keep: fn(String) -> Bool,
  acc: List(String),
) -> #(String, State) {
  case string.pop_grapheme(state.rest) {
    Ok(#(c, rest)) ->
      case keep(c) {
        True ->
          take_loop(
            State(..state, rest:, offset: state.offset + string.byte_size(c)),
            keep,
            [c, ..acc],
          )
        False -> #(string.concat(list.reverse(acc)), state)
      }
    Error(_) -> #(string.concat(list.reverse(acc)), state)
  }
}

fn skip_past(state: State, marker: String) -> State {
  case string.split_once(state.rest, marker) {
    Ok(#(before, after)) ->
      State(
        ..state,
        rest: after,
        offset: state.offset
          + string.byte_size(before)
          + string.byte_size(marker),
      )
    Error(_) ->
      State(
        ..state,
        rest: "",
        offset: state.offset + string.byte_size(state.rest),
      )
  }
}

// HEADER ----------------------------------------------------------------------

/// Finds the header between a first line of `---` and the next one. Returns
/// the header's span and where the body starts.
fn split_header(text: String) -> #(Option(Span), Int, List(Problem)) {
  let lines = lines_with_offsets(text)
  case lines {
    [#(first, 0), ..rest] ->
      case string.trim_end(first) == "---" {
        False -> #(None, 0, [])
        True -> {
          let header_start = string.byte_size(first) + 1
          case list.find(rest, fn(line) { string.trim_end(line.0) == "---" }) {
            Ok(#(closing, offset)) -> #(
              Some(Span(header_start, offset)),
              int.min(
                offset + string.byte_size(closing) + 1,
                string.byte_size(text),
              ),
              [],
            )
            Error(_) -> #(None, 0, [
              Problem(
                "The header opened by --- is never closed by another ---",
                Span(0, 3),
              ),
            ])
          }
        }
      }
    _ -> #(None, 0, [])
  }
}

/// Each line without its newline, and the byte offset it starts at.
fn lines_with_offsets(text: String) -> List(#(String, Int)) {
  string.split(text, "\n")
  |> list.map_fold(0, fn(offset, line) {
    #(offset + string.byte_size(line) + 1, #(line, offset))
  })
  |> fn(pair) { pair.1 }
}

fn parse_header(
  source: BitArray,
  span: Span,
) -> #(List(Piece), List(Code), List(Prop), List(Problem), Set(String)) {
  let text = slice(source, span.start, span.end)
  let lines = lines_with_offsets(text)
  let imports = import_statements(lines, span.start, [])
  let #(props, props_span, prop_problems) = case
    list.filter(lines, fn(line) { string.starts_with(line.0, "props(") })
  {
    [] -> #([], None, [])
    [#(_, line_offset), ..others] -> {
      let props_start = span.start + line_offset
      let #(props_end, props, problems) =
        parse_props(source, props_start + 5, span.end)
      let duplicates =
        list.map(others, fn(line) {
          let start = span.start + line.1
          Problem("A template has one props(...)", Span(start, start + 6))
        })
      #(
        props,
        Some(Span(props_start, props_end)),
        list.append(problems, duplicates),
      )
    }
  }
  // The code is what's left once the imports and props are taken out.
  let taken =
    list.map(imports, fn(piece) { piece.span })
    |> list.append(option.values([props_span]))
    |> list.sort(fn(a, b) { int.compare(a.start, b.start) })
  let #(gaps, last) =
    list.fold(taken, #([], span.start), fn(acc, taken) {
      let #(gaps, from) = acc
      #([Span(from, taken.start), ..gaps], int.max(from, taken.end))
    })
  let gaps = list.reverse([Span(last, span.end), ..gaps])
  let #(code, problems, names) =
    list.fold(gaps, #([], [], set.new()), fn(acc, gap) {
      let #(codes, problems, names) = acc
      let #(code, gap_problems, gap_names) =
        header_code(source, gap.start, gap.end)
      #(
        list.append(codes, code),
        list.append(problems, gap_problems),
        set.union(names, gap_names),
      )
    })
  #(imports, code, props, list.append(prop_problems, problems), names)
}

/// Each `import` statement, which may run over several lines while a
/// `{` is open.
fn import_statements(
  lines: List(#(String, Int)),
  base: Int,
  acc: List(Piece),
) -> List(Piece) {
  case lines {
    [] -> list.reverse(acc)
    [#(line, offset), ..rest] ->
      case string.starts_with(line, "import ") {
        False -> import_statements(rest, base, acc)
        True -> {
          let #(statement, rest) = continue_import(line, rest)
          let statement = string.trim_end(statement)
          let start = base + offset
          let piece =
            Piece(statement, Span(start, start + string.byte_size(statement)))
          import_statements(rest, base, [piece, ..acc])
        }
      }
  }
}

fn continue_import(
  statement: String,
  rest: List(#(String, Int)),
) -> #(String, List(#(String, Int))) {
  let open =
    string.length(string.replace(statement, "{", ""))
    != string.length(string.replace(statement, "}", ""))
  case open, rest {
    True, [#(line, _), ..rest] ->
      continue_import(statement <> "\n" <> line, rest)
    _, _ -> #(statement, rest)
  }
}

fn header_code(
  source: BitArray,
  start: Int,
  end: Int,
) -> #(List(Code), List(Problem), Set(String)) {
  let text = slice(source, start, end)
  case string.trim(text) {
    "" -> #([], [], set.new())
    trimmed -> {
      let leading =
        string.byte_size(text) - string.byte_size(string.trim_start(text))
      let start = start + leading
      let end = start + string.byte_size(trimmed)
      let #(code, state, _) = code(new_state(source, start, end), False)
      #([code], list.reverse(state.problems), state.names)
    }
  }
}

/// `open` is the offset of the `(`. Returns the offset after the `)`.
fn parse_props(
  source: BitArray,
  open: Int,
  limit: Int,
) -> #(Int, List(Prop), List(Problem)) {
  let text = slice(source, open + 1, limit)
  let #(declarations, close) = split_top_level(text, open + 1)
  let props =
    list.filter_map(declarations, fn(declaration) {
      let #(raw, start) = declaration
      let trimmed = string.trim_start(raw)
      let start = start + string.byte_size(raw) - string.byte_size(trimmed)
      let trimmed = string.trim_end(trimmed)
      case trimmed {
        "" -> Error(Nil)
        _ -> Ok(#(trimmed, Span(start, start + string.byte_size(trimmed))))
      }
    })
  let #(props, problems) =
    list.fold(props, #([], []), fn(acc, declaration) {
      let #(props, problems) = acc
      let #(text, span) = declaration
      case string.split_once(text, ":") {
        Ok(#(name, _)) -> {
          let name = string.trim(name)
          case is_identifier(name) {
            True -> #([Prop(name, Piece(text, span)), ..props], problems)
            False -> #(props, [
              Problem(name <> " is not a valid prop name", span),
              ..problems
            ])
          }
        }
        Error(_) -> #(props, [
          Problem("A prop needs a type: " <> text <> ": String", span),
          ..problems
        ])
      }
    })
  let #(end, problems) = case close {
    Some(close) -> #(close + 1, problems)
    None -> #(limit, [
      Problem("props( is never closed", Span(open - 5, open + 1)),
      ..problems
    ])
  }
  #(end, list.reverse(props), list.reverse(problems))
}

/// Splits `text` at commas outside brackets and strings, up to the `)`
/// that closes it. Returns each part with its offset, and the offset of
/// that `)`.
fn split_top_level(
  text: String,
  base: Int,
) -> #(List(#(String, Int)), Option(Int)) {
  split_loop(string.to_graphemes(text), base, base, 0, False, [], [])
}

fn split_loop(
  graphemes: List(String),
  offset: Int,
  part_start: Int,
  depth: Int,
  in_string: Bool,
  part: List(String),
  parts: List(#(String, Int)),
) -> #(List(#(String, Int)), Option(Int)) {
  let finish = fn() {
    list.reverse([#(string.concat(list.reverse(part)), part_start), ..parts])
  }
  case graphemes {
    [] -> #(finish(), None)
    [c, ..rest] -> {
      let next = offset + string.byte_size(c)
      case c, in_string {
        "\\", True ->
          case rest {
            [escaped, ..rest] ->
              split_loop(
                rest,
                next + string.byte_size(escaped),
                part_start,
                depth,
                True,
                [escaped, c, ..part],
                parts,
              )
            [] -> #(finish(), None)
          }
        "\"", _ ->
          split_loop(
            rest,
            next,
            part_start,
            depth,
            !in_string,
            [c, ..part],
            parts,
          )
        _, True ->
          split_loop(rest, next, part_start, depth, True, [c, ..part], parts)
        ")", False if depth == 0 -> #(finish(), Some(offset))
        "(", False | "[", False | "{", False ->
          split_loop(
            rest,
            next,
            part_start,
            depth + 1,
            False,
            [c, ..part],
            parts,
          )
        ")", False | "]", False | "}", False ->
          split_loop(
            rest,
            next,
            part_start,
            depth - 1,
            False,
            [c, ..part],
            parts,
          )
        ",", False if depth == 0 ->
          split_loop(rest, next, next, 0, False, [], [
            #(string.concat(list.reverse(part)), part_start),
            ..parts
          ])
        _, False ->
          split_loop(rest, next, part_start, depth, False, [c, ..part], parts)
      }
    }
  }
}

// GLEAM CODE ------------------------------------------------------------------

/// What came before, for telling markup from a comparison.
type Previous {
  /// An expression can start here.
  ExpressionStart
  /// An expression just ended: `<` compares.
  Operand
  /// After `.`: a field or a module member follows.
  Dot
}

/// Gleam code up to the end of input, or with `in_braces` up to the `}`
/// that closes it, which is consumed. Also returns whether there was
/// nothing but whitespace and comments.
fn code(state: State, in_braces: Bool) -> #(Code, State, Bool) {
  let start = state.offset
  code_loop(state, in_braces, start, 0, ExpressionStart, start, [], True)
}

fn code_loop(
  state: State,
  in_braces: Bool,
  start: Int,
  depth: Int,
  previous: Previous,
  piece_start: Int,
  parts: List(Part),
  empty: Bool,
) -> #(Code, State, Bool) {
  let continue = fn(state, depth, previous, empty) {
    code_loop(
      state,
      in_braces,
      start,
      depth,
      previous,
      piece_start,
      parts,
      empty,
    )
  }
  let finish = fn(state: State, end: Int) {
    let parts = flush(state, piece_start, end, parts)
    Code(list.reverse(parts), Span(start, end))
  }
  case state.rest {
    "" -> {
      let state = case in_braces {
        True -> problem(state, "Missing }", Span(start - 1, start))
        False -> state
      }
      #(finish(state, state.offset), state, empty)
    }
    // Inside braces a comment also ends at the closing brace, so
    // {// a note} is a comment the way JSX's {/* a note */} is.
    "//" <> _ -> {
      let stops_at_brace = in_braces && depth == 0
      let #(_, state) =
        take_while(state, fn(c) {
          c != "\n" && c != "\r\n" && { !stops_at_brace || c != "}" }
        })
      continue(state, depth, previous, empty)
    }
    "\"" <> _ ->
      continue(string_literal(advance(state, "\"")), depth, Operand, False)
    "}" <> _ if depth == 0 && in_braces -> {
      let code = finish(state, state.offset)
      #(code, advance(state, "}"), empty)
    }
    "{" <> _ | "(" <> _ | "[" <> _ -> {
      let assert Ok(#(_, state)) = pop(state)
      continue(state, depth + 1, ExpressionStart, False)
    }
    "}" <> _ | ")" <> _ | "]" <> _ -> {
      let assert Ok(#(_, state)) = pop(state)
      continue(state, int.max(depth - 1, 0), Operand, False)
    }
    "<" <> after ->
      case previous == ExpressionStart && markup_starts(after) {
        True -> {
          let parts = flush(state, piece_start, state.offset, parts)
          let #(node, state) = markup(state, True, [])
          code_loop(
            state,
            in_braces,
            start,
            depth,
            Operand,
            state.offset,
            [Markup(node), ..parts],
            False,
          )
        }
        False -> continue(advance(state, "<"), depth, ExpressionStart, False)
      }
    ".." <> _ -> continue(advance(state, ".."), depth, ExpressionStart, False)
    "." <> _ -> continue(advance(state, "."), depth, Dot, False)
    _ ->
      case pop(state) {
        Error(_) -> #(finish(state, state.offset), state, empty)
        Ok(#(c, next)) ->
          case is_word_character(c), is_space(c) {
            True, _ -> {
              let #(word, state) = take_while(state, is_word_character)
              let state = case previous {
                Dot -> state
                _ -> State(..state, names: set.insert(state.names, word))
              }
              let previous = case list.contains(keywords, word) {
                True -> ExpressionStart
                False -> Operand
              }
              continue(state, depth, previous, False)
            }
            False, True -> continue(next, depth, previous, empty)
            False, False -> continue(next, depth, ExpressionStart, False)
          }
      }
  }
}

fn flush(state: State, from: Int, to: Int, parts: List(Part)) -> List(Part) {
  case to > from {
    True -> [
      Gleam(Piece(slice(state.source, from, to), Span(from, to))),
      ..parts
    ]
    False -> parts
  }
}

/// The rest of a string literal, after its opening quote.
fn string_literal(state: State) -> State {
  case pop(state) {
    Error(_) -> state
    Ok(#("\"", state)) -> state
    Ok(#("\\", state)) ->
      case pop(state) {
        Ok(#(_, state)) -> string_literal(state)
        Error(_) -> state
      }
    Ok(#(_, state)) -> string_literal(state)
  }
}

fn markup_starts(after: String) -> Bool {
  case string.first(after) {
    Ok(">") -> True
    Ok(c) -> is_letter(c)
    Error(_) -> False
  }
}

// MARKUP ----------------------------------------------------------------------

/// What ends a run of children.
type Closing {
  Top
  ClosesTag(String)
  ClosesFragment
}

type End {
  EndOfInput
  Closed
  /// A closing tag for an element further out: this one wasn't closed.
  ClosedOutside
  /// The `}` around the code the markup is in: this one wasn't closed.
  BraceOutside
}

/// The markup at a `<`. Inside code, markup stops at a `}` that would close
/// the code, and closing tags never reach outside it.
fn markup(state: State, in_code: Bool, stack: List(String)) -> #(Node, State) {
  case state.rest {
    "<>" <> _ -> fragment(state, in_code, stack)
    _ -> tag(state, in_code, stack)
  }
}

fn fragment(
  state: State,
  in_code: Bool,
  stack: List(String),
) -> #(Node, State) {
  let start = state.offset
  let state = advance(state, "<>")
  let #(nodes, state, end) =
    children(state, ClosesFragment, in_code, ["", ..stack])
  let state = case end {
    Closed -> state
    _ -> problem(state, "<> is never closed by </>", Span(start, start + 2))
  }
  #(Fragment(nodes, Span(start, state.offset)), state)
}

type Ending {
  Open
  SelfClosing
  Unclosed
}

fn tag(state: State, in_code: Bool, stack: List(String)) -> #(Node, State) {
  let state = advance(state, "<")
  let name_start = state.offset
  let #(name, state) = take_while(state, is_tag_character)
  let name = Piece(name, Span(name_start, state.offset))
  let component = is_component(name.text)
  let #(attributes, state, ending) = attributes(state, [])
  let area = Span(name.span.end, state.offset)
  let state = case ending {
    SelfClosing -> advance(state, "/>")
    Open -> advance(state, ">")
    Unclosed ->
      problem(state, "<" <> name.text <> " is missing its closing >", name.span)
  }
  let has_children =
    ending == Open && { component || !list.contains(void_elements, name.text) }
  let raw = name.text == "style" || name.text == "script"
  let #(nodes, state) = case has_children, raw {
    False, _ -> #(None, state)
    // CSS and JavaScript are text: their braces aren't Gleam.
    True, True -> {
      let start = state.offset
      let closing = "</" <> name.text
      case string.split_once(state.rest, closing) {
        Ok(#(content, _)) -> {
          let state =
            State(
              ..state,
              rest: string.drop_start(state.rest, string.length(content)),
              offset: state.offset + string.byte_size(content),
            )
          let state = skip_past(state, ">")
          #(
            Some([Text(content, Span(start, start + string.byte_size(content)))]),
            state,
          )
        }
        Error(_) -> {
          let state =
            problem(state, "<" <> name.text <> "> is never closed", name.span)
          #(
            Some([]),
            State(
              ..state,
              rest: "",
              offset: state.offset + string.byte_size(state.rest),
            ),
          )
        }
      }
    }
    True, False -> {
      let #(nodes, state, end) =
        children(state, ClosesTag(name.text), in_code, [name.text, ..stack])
      let state = case end {
        Closed -> state
        EndOfInput ->
          problem(state, "<" <> name.text <> "> is never closed", name.span)
        ClosedOutside | BraceOutside ->
          problem(state, "<" <> name.text <> "> is not closed", name.span)
      }
      #(Some(nodes), state)
    }
  }
  case component {
    True -> #(Component(name:, attributes:, children: nodes, area:), state)
    False -> #(Element(name:, attributes:, children: nodes), state)
  }
}

fn attributes(
  state: State,
  acc: List(Attribute),
) -> #(List(Attribute), State, Ending) {
  let #(_, state) = take_while(state, is_space)
  case state.rest {
    "/>" <> _ -> #(list.reverse(acc), state, SelfClosing)
    ">" <> _ -> #(list.reverse(acc), state, Open)
    "{..." <> _ -> {
      let start = state.offset
      let #(code, state, _) = code(advance(state, "{..."), True)
      attributes(state, [Spread(code, Span(start, state.offset)), ..acc])
    }
    "{" <> _ -> {
      let start = state.offset
      let #(code, state, _) = code(advance(state, "{"), True)
      let state =
        problem(
          state,
          "Attributes are name={value}; to pass a list of them, spread it: {...attributes}",
          Span(start, state.offset),
        )
      attributes(state, [Spread(code, Span(start, state.offset)), ..acc])
    }
    _ ->
      case string.first(state.rest) {
        Ok(c) ->
          case is_letter(c) || c == "_" || c == ":" || c == "@" {
            True -> {
              let #(attribute, state) = attribute(state)
              attributes(state, [attribute, ..acc])
            }
            False -> #(list.reverse(acc), state, Unclosed)
          }
        Error(_) -> #(list.reverse(acc), state, Unclosed)
      }
  }
}

fn attribute(state: State) -> #(Attribute, State) {
  let start = state.offset
  let #(name, state) = take_while(state, is_attribute_character)
  let name = Piece(name, Span(start, state.offset))
  let #(_, after_space) = take_while(state, is_space)
  case after_space.rest {
    "=" <> _ -> {
      let #(_, state) = take_while(advance(after_space, "="), is_space)
      case state.rest {
        "\"" <> _ -> quoted(state, name, "\"")
        "'" <> _ -> quoted(state, name, "'")
        "{" <> _ -> {
          let #(code, state, _) = code(advance(state, "{"), True)
          #(Attribute(name, Dynamic(code)), state)
        }
        _ -> {
          let state =
            problem(
              state,
              "Expected a value after " <> name.text <> "=: \"text\" or {code}",
              name.span,
            )
          #(Attribute(name, Bare), state)
        }
      }
    }
    _ -> #(Attribute(name, Bare), state)
  }
}

fn quoted(
  state: State,
  name: syntax.Piece,
  quote: String,
) -> #(Attribute, State) {
  let start = state.offset
  let #(text, state) = take_while(advance(state, quote), fn(c) { c != quote })
  let state = case string.starts_with(state.rest, quote) {
    True -> advance(state, quote)
    False ->
      problem(state, "Unclosed attribute value", Span(start, state.offset))
  }
  #(
    Attribute(name, Static(decode_entities(text), Span(start, state.offset))),
    state,
  )
}

fn children(
  state: State,
  closing: Closing,
  in_code: Bool,
  stack: List(String),
) -> #(List(Node), State, End) {
  children_loop(state, closing, in_code, stack, [])
}

fn children_loop(
  state: State,
  closing: Closing,
  in_code: Bool,
  stack: List(String),
  acc: List(Node),
) -> #(List(Node), State, End) {
  let done = fn(state, end) { #(list.reverse(acc), state, end) }
  let continue = fn(state, acc) {
    children_loop(state, closing, in_code, stack, acc)
  }
  case state.rest {
    "" -> done(state, EndOfInput)
    "</>" <> _ ->
      case closing {
        ClosesFragment -> done(advance(state, "</>"), Closed)
        _ ->
          case list.contains(stack, "") {
            True -> done(state, ClosedOutside)
            False -> {
              let start = state.offset
              let state = advance(state, "</>")
              continue(
                problem(state, "Unexpected </>", Span(start, state.offset)),
                acc,
              )
            }
          }
      }
    "</" <> _ -> {
      let before = state
      let start = state.offset
      let #(name, state) = take_while(advance(state, "</"), is_tag_character)
      let #(_, state) = take_while(state, is_space)
      let state = case state.rest {
        ">" <> _ -> advance(state, ">")
        _ -> state
      }
      case closing == ClosesTag(name), list.contains(stack, name) {
        True, _ -> done(state, Closed)
        False, True -> done(before, ClosedOutside)
        False, False ->
          continue(
            problem(
              state,
              "Unexpected </" <> name <> ">",
              Span(start, state.offset),
            ),
            acc,
          )
      }
    }
    "<!--" <> _ -> continue(skip_past(advance(state, "<!--"), "-->"), acc)
    "<!" <> _ -> continue(skip_past(state, ">"), acc)
    "}" <> _ if in_code -> done(state, BraceOutside)
    "{" <> _ -> {
      let start = state.offset
      let spread = string.starts_with(state.rest, "{...")
      let state = case spread {
        True -> advance(state, "{...")
        False -> advance(state, "{")
      }
      let #(code, state, empty) = code(state, True)
      case empty && !spread {
        // {// a comment}, as JSX writes comments.
        True -> continue(state, acc)
        False ->
          continue(state, [
            Expression(code, spread, Span(start, state.offset)),
            ..acc
          ])
      }
    }
    "<" <> after ->
      case markup_starts(after) {
        True -> {
          let #(node, state) = markup(state, in_code, stack)
          continue(state, [node, ..acc])
        }
        False -> text(state, in_code, continue, acc)
      }
    _ -> text(state, in_code, continue, acc)
  }
}

fn text(
  state: State,
  in_code: Bool,
  continue: fn(State, List(Node)) -> #(List(Node), State, End),
  acc: List(Node),
) -> #(List(Node), State, End) {
  let start = state.offset
  // Always take the first character, so a stray `<` makes progress.
  let #(first, state) = case pop(state) {
    Ok(#(c, state)) -> #(c, state)
    Error(_) -> #("", state)
  }
  let #(more, state) =
    take_while(state, fn(c) { c != "<" && c != "{" && { !in_code || c != "}" } })
  continue(state, [
    Text(decode_entities(first <> more), Span(start, state.offset)),
    ..acc
  ])
}

// CHARACTERS ------------------------------------------------------------------

pub fn is_component(name: String) -> Bool {
  case string.first(name) {
    Ok(c) -> is_upper(c) || string.contains(name, ".")
    Error(_) -> False
  }
}

fn is_identifier(name: String) -> Bool {
  case string.pop_grapheme(name) {
    Ok(#(first, rest)) ->
      is_lower(first) && list.all(string.to_graphemes(rest), is_word_character)
    Error(_) -> False
  }
}

fn is_space(c: String) -> Bool {
  c == " " || c == "\n" || c == "\t" || c == "\r" || c == "\r\n"
}

fn is_tag_character(c: String) -> Bool {
  is_word_character(c) || c == "-" || c == "." || c == ":"
}

fn is_attribute_character(c: String) -> Bool {
  is_word_character(c) || c == "-" || c == ":" || c == "." || c == "@"
}

fn is_word_character(c: String) -> Bool {
  is_letter(c) || is_digit(c) || c == "_"
}

fn is_letter(c: String) -> Bool {
  is_lower(c) || is_upper(c)
}

fn code_of(c: String) -> Int {
  case string.to_utf_codepoints(c) {
    [cp] -> string.utf_codepoint_to_int(cp)
    _ -> -1
  }
}

fn is_lower(c: String) -> Bool {
  let n = code_of(c)
  n >= 97 && n <= 122
}

fn is_upper(c: String) -> Bool {
  let n = code_of(c)
  n >= 65 && n <= 90
}

fn is_digit(c: String) -> Bool {
  let n = code_of(c)
  n >= 48 && n <= 57
}

// ENTITIES --------------------------------------------------------------------

/// Lustre escapes text itself, so entities written in a template are
/// decoded first, or `&amp;` would show as `&amp;amp;`.
pub fn decode_entities(text: String) -> String {
  case string.contains(text, "&") {
    False -> text
    True -> decode_loop(text, "")
  }
}

fn decode_loop(text: String, acc: String) -> String {
  case string.split_once(text, "&") {
    Error(_) -> acc <> text
    Ok(#(before, after)) ->
      case string.split_once(after, ";") {
        Ok(#(name, rest)) ->
          case string.length(name) <= 10, entity(name) {
            True, Ok(char) -> decode_loop(rest, acc <> before <> char)
            _, _ -> decode_loop(after, acc <> before <> "&")
          }
        Error(_) -> acc <> before <> "&" <> after
      }
  }
}

fn entity(name: String) -> Result(String, Nil) {
  case name {
    "amp" -> Ok("&")
    "lt" -> Ok("<")
    "gt" -> Ok(">")
    "quot" -> Ok("\"")
    "apos" -> Ok("'")
    "nbsp" -> Ok("\u{00A0}")
    "copy" -> Ok("©")
    "reg" -> Ok("®")
    "trade" -> Ok("™")
    "hellip" -> Ok("…")
    "mdash" -> Ok("—")
    "ndash" -> Ok("–")
    "middot" -> Ok("·")
    "times" -> Ok("×")
    "larr" -> Ok("←")
    "rarr" -> Ok("→")
    "#" <> number -> {
      let parsed = case number {
        "x" <> hex | "X" <> hex -> int.base_parse(hex, 16)
        _ -> int.parse(number)
      }
      parsed
      |> result.try(string.utf_codepoint)
      |> result.map(fn(cp) { string.from_utf_codepoints([cp]) })
    }
    _ -> Error(Nil)
  }
}

// HEADER FUNCTIONS ------------------------------------------------------------

/// Stands for markup when reading a function's source as text.
const markup_mark = "\u{0001}"

/// The functions defined at the top level of the header.
fn functions(header: List(Code)) -> List(Function) {
  header
  |> list.flat_map(fn(code) { code.parts })
  |> list.map(fn(part) {
    case part {
      Gleam(piece) -> piece.text
      Markup(_) -> markup_mark
    }
  })
  |> string.concat
  |> string.to_graphemes
  |> functions_loop(0, [], [])
}

fn functions_loop(
  source: List(String),
  depth: Int,
  word: List(String),
  found: List(Function),
) -> List(Function) {
  case source {
    [] -> list.reverse(found)
    ["\"", ..rest] -> functions_loop(skip_string(rest), depth, [], found)
    ["/", "/", ..rest] ->
      functions_loop(
        list.drop_while(rest, fn(c) { c != "\n" }),
        depth,
        [],
        found,
      )
    ["{", ..rest] | ["(", ..rest] | ["[", ..rest] ->
      functions_loop(rest, depth + 1, [], found)
    ["}", ..rest] | [")", ..rest] | ["]", ..rest] ->
      functions_loop(rest, int.max(depth - 1, 0), [], found)
    [c, ..rest] ->
      case is_word_character(c) {
        True -> functions_loop(rest, depth, [c, ..word], found)
        False ->
          case depth == 0 && word == ["n", "f"] {
            True ->
              case function(source) {
                Ok(#(function, rest)) ->
                  functions_loop(rest, 0, [], [function, ..found])
                Error(_) -> functions_loop(rest, depth, [], found)
              }
            False -> functions_loop(rest, depth, [], found)
          }
      }
  }
}

/// After `fn`: the name, parameters and body of a function.
fn function(source: List(String)) -> Result(#(Function, List(String)), Nil) {
  let source = list.drop_while(source, is_space)
  let #(name, source) = list.split_while(source, is_word_character)
  let name = string.concat(name)
  case list.drop_while(source, is_space), name {
    _, "" -> Error(Nil)
    ["(", ..rest], _ -> {
      let #(parameters, rest) = until_closed(rest, 0, [])
      // The body starts at the first `{` after the parameters.
      let rest = list.drop_while(rest, fn(c) { c != "{" })
      case rest {
        ["{", ..rest] -> {
          let #(body, rest) = until_closed(rest, 0, [])
          let parameters =
            split_top_level(parameters, 0).0
            |> list.filter_map(fn(part) { signatures.param(part.0) })
          Ok(#(
            Function(
              name:,
              parameters:,
              returns_markup: string.contains(body, markup_mark),
            ),
            rest,
          ))
        }
        _ -> Error(Nil)
      }
    }
    _, _ -> Error(Nil)
  }
}

/// Text up to the bracket closing one already open, which is consumed.
fn until_closed(
  source: List(String),
  depth: Int,
  acc: List(String),
) -> #(String, List(String)) {
  case source {
    [] -> #(string.concat(list.reverse(acc)), [])
    [")", ..rest] | ["}", ..rest] | ["]", ..rest] if depth == 0 -> #(
      string.concat(list.reverse(acc)),
      rest,
    )
    ["\"", ..rest] -> {
      let after = skip_string(rest)
      let taken = list.take(rest, list.length(rest) - list.length(after))
      until_closed(
        after,
        depth,
        list.append(list.reverse(taken), ["\"", ..acc]),
      )
    }
    [c, ..rest] if c == "(" || c == "{" || c == "[" ->
      until_closed(rest, depth + 1, [c, ..acc])
    [c, ..rest] if c == ")" || c == "}" || c == "]" ->
      until_closed(rest, depth - 1, [c, ..acc])
    [c, ..rest] -> until_closed(rest, depth, [c, ..acc])
  }
}

fn skip_string(source: List(String)) -> List(String) {
  case source {
    [] -> []
    ["\"", ..rest] -> rest
    ["\\", _, ..rest] -> skip_string(rest)
    [_, ..rest] -> skip_string(rest)
  }
}
