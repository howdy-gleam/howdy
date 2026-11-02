//// Turns a parsed template into a Gleam module, recording where every piece
//// of template code ended up, so positions can be mapped both ways: editor
//// positions into the module for `gleam lsp`, and compiler errors back to
//// the template.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import gleam/string
import howdy/templates/internal/syntax.{
  type Attribute, type Code, type Function, type Node, type Piece, type Problem,
  type Prop, type Span, type Template, Attribute, Bare, Component, Dynamic,
  Element, Expression, Fragment, Gleam, Markup, Problem, Span, Spread, Static,
  Text,
}

pub type Kind {
  /// Gleam written in the template: the header, `{}`, attribute values.
  GleamCode
  /// A component's tag name, `StatusBadge` for `status_badge`.
  ComponentName
  /// An attribute name on a component, which is a label.
  Label
  /// The attribute area of a component's start tag, mapped to the point in
  /// the call where another labelled argument could go.
  Arguments
}

/// `template` in the template became `generated` in the module. When both
/// have the same length (`exact`) every offset inside maps one to one.
pub type Segment {
  Segment(template: Span, generated: Span, kind: Kind, exact: Bool)
}

/// The attribute area of a component's start tag, and the point in its
/// call where another labelled argument could go.
pub type Hole {
  Hole(area: Span, generated: Int)
}

/// The code generated for a node, and the part of the template to blame
/// for problems in it: its tag name.
pub type Region {
  Region(generated: Span, template: Span)
}

pub type Output {
  Output(
    code: String,
    segments: List(Segment),
    holes: List(Hole),
    regions: List(Region),
    problems: List(Problem),
  )
}

/// What the module calls the Lustre and list modules: the template's own
/// import when it has one, so the names don't clash.
type Aliases {
  Aliases(element: String, attribute: String, event: String, list: String)
}

type Context {
  Context(
    aliases: Aliases,
    props: List(Prop),
    functions: List(Function),
    svg: Bool,
  )
}

type Out {
  Out(
    chunks: List(String),
    offset: Int,
    indent: Int,
    segments: List(Segment),
    holes: List(Hole),
    regions: List(Region),
    problems: List(Problem),
    uses_element: Bool,
    uses_attribute: Bool,
    uses_event: Bool,
    uses_list: Bool,
  )
}

const header_line = "// Generated from "

/// Changing it regenerates every module, as the code it writes may change.
const generator_version = "1"

/// The first line of every generated module, so tools can tell generated
/// modules from ones people wrote. `hash` is of the rest of the module, the
/// template's name and the generator, so an unchanged template needs no
/// formatting again, and a renamed one is written again.
fn marker(source: String, hash: String) -> String {
  header_line
  <> source
  <> " by howdy_templates ("
  <> hash
  <> "). Do not edit.\n"
}

pub fn is_generated(code: String) -> Bool {
  marker_hash(code) |> result.is_ok
}

/// The hash in a generated module's first line.
pub fn marker_hash(code: String) -> Result(String, Nil) {
  use #(first, _) <- result.try(string.split_once(code, "\n"))
  case
    string.starts_with(first, header_line),
    string.ends_with(first, ". Do not edit.")
  {
    True, True -> {
      use #(_, rest) <- result.try(string.split_once(
        first,
        " by howdy_templates (",
      ))
      use #(hash, _) <- result.map(string.split_once(rest, ")"))
      hash
    }
    _, _ -> Error(Nil)
  }
}

@external(erlang, "howdy_templates_ffi", "hash")
fn hash(text: String) -> String

/// `name` is the function the module exports, named after the file;
/// `source` is the template's file name, for the marker line.
pub fn generate(template: Template, name: String, source: String) -> Output {
  let header_text =
    template.imports |> list.map(fn(piece) { piece.text }) |> string.join("\n")
  // The template's own import if it has one; otherwise the module's usual
  // name, which is how hover and errors show its types, unless the
  // template's code uses that name for something else.
  let alias = fn(module, name) {
    case imported_alias(header_text, module) {
      Some(alias) -> alias
      None ->
        case set.contains(template.names, name) {
          True -> "template_" <> name
          False -> name
        }
    }
  }
  let aliases =
    Aliases(
      element: alias("lustre/element", "element"),
      attribute: alias("lustre/attribute", "attribute"),
      event: alias("lustre/event", "event"),
      list: alias("gleam/list", "list"),
    )
  let context =
    Context(
      aliases:,
      props: template.props,
      functions: template.functions,
      svg: False,
    )
  let declares_children =
    list.any(template.props, fn(prop) { prop.name == "children" })
  // The template's CSS goes first, as written.
  let styles =
    list.map(template.styles, fn(piece) {
      Element(
        name: syntax.Piece("style", piece.span),
        attributes: [],
        children: Some([Text(piece.text, piece.span)]),
      )
    })

  let main =
    new()
    |> list.fold(template.header, _, fn(out, code) {
      out |> gleam_code(code, context) |> emit("\n\n")
    })
    |> emit("pub fn " <> name <> "(")
    |> list.fold(template.props, _, fn(out, prop) {
      out
      |> emit("\n  " <> prop.name <> " ")
      |> emit_piece(prop.source, GleamCode)
      |> emit(",")
    })
    |> emit_when(
      template.uses_children && !declares_children,
      "\n  children children,",
    )
    |> emit_when(template.props != [] || template.uses_children, "\n")
    |> emit(") {")
    |> indented(fn(out) {
      out
      |> newline
      |> root(list.append(styles, template.body), context)
    })
    |> emit("\n}\n")

  // Every import, the template's and the generator's, in one block sorted
  // the way `gleam format` sorts them, so formatting leaves them in place.
  let needed =
    [
      #(main.uses_element, "lustre/element", aliases.element),
      #(main.uses_attribute, "lustre/attribute", aliases.attribute),
      #(main.uses_event, "lustre/event", aliases.event),
      #(main.uses_list, "gleam/list", aliases.list),
    ]
    |> list.filter_map(fn(needed) {
      let #(used, module, alias) = needed
      let last = string.split(module, "/") |> list.last |> result.unwrap("")
      case used && option.is_none(imported_alias(header_text, module)) {
        False -> Error(Nil)
        True ->
          case alias == last {
            True -> Ok(#(module, Error("import " <> module)))
            False ->
              Ok(#(module, Error("import " <> module <> " as " <> alias)))
          }
      }
    })
  let imports =
    template.imports
    |> list.map(fn(piece) { #(import_module(piece.text), Ok(piece)) })
    |> list.append(needed)
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.fold(new(), fn(out, import_) {
      case import_.1 {
        Ok(piece) -> emit_piece(out, piece, GleamCode)
        Error(text) -> emit(out, text)
      }
      |> emit("\n")
    })
    |> fn(out: Out) {
      case out.offset {
        0 -> out
        _ -> emit(out, "\n")
      }
    }
  let rest =
    string.concat(list.reverse(imports.chunks))
    <> string.concat(list.reverse(main.chunks))
  let prefix = marker(source, hash(generator_version <> source <> rest))
  let shift_imports = string.byte_size(prefix)
  let shift = shift_imports + imports.offset
  let move = fn(span: Span, by: Int) { Span(span.start + by, span.end + by) }

  Output(
    code: prefix <> rest,
    segments: list.append(
      list.map(imports.segments, fn(s) {
        Segment(..s, generated: move(s.generated, shift_imports))
      }),
      list.map(main.segments, fn(s) {
        Segment(..s, generated: move(s.generated, shift))
      }),
    ),
    holes: list.map(main.holes, fn(h) {
      Hole(..h, generated: h.generated + shift)
    }),
    regions: list.map(main.regions, fn(r) {
      Region(..r, generated: move(r.generated, shift))
    }),
    problems: list.reverse(main.problems),
  )
}

/// `gleam/list` for `import gleam/list.{map} as l`.
fn import_module(statement: String) -> String {
  statement
  |> string.drop_start(string.length("import "))
  |> string.to_graphemes
  |> list.take_while(fn(c) { c != "." && c != " " && c != "\n" })
  |> string.concat
}

/// The alias a header's `import module` line gives the module.
fn imported_alias(header: String, module: String) -> option.Option(String) {
  header
  |> string.split("\n")
  |> list.find_map(fn(line) {
    case string.trim(line) {
      "import " <> rest ->
        case string.starts_with(rest, module) {
          False -> Error(Nil)
          True -> {
            let after = string.drop_start(rest, string.length(module))
            case after {
              "" | "." <> _ | " " <> _ ->
                case string.split_once(after, " as ") {
                  Ok(#(_, alias)) -> Ok(string.trim(alias))
                  Error(_) ->
                    case list.last(string.split(module, "/")) {
                      Ok(last) -> Ok(last)
                      Error(_) -> Error(Nil)
                    }
                }
              _ -> Error(Nil)
            }
          }
        }
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

// MAPPING ---------------------------------------------------------------------

/// Where a template offset lands in the generated module, and what kind of
/// code it is.
pub fn to_generated(output: Output, offset: Int) -> Result(#(Int, Kind), Nil) {
  let containing =
    list.filter(output.segments, fn(s) {
      s.template.start <= offset && offset <= s.template.end
    })
  case containing {
    [s, ..] ->
      Ok(#(map_offset(offset, s.template, s.generated, s.exact), s.kind))
    [] ->
      case
        list.find(output.holes, fn(h) {
          h.area.start <= offset && offset <= h.area.end
        })
      {
        Ok(h) -> Ok(#(h.generated, Arguments))
        Error(_) -> Error(Nil)
      }
  }
}

/// Where a generated offset came from. Offsets in code the generator wrote
/// itself go to the tag of the node it belongs to: its start, or its end
/// when `end` is set.
pub fn to_template(output: Output, offset: Int, end: Bool) -> Result(Int, Nil) {
  let containing =
    list.filter(output.segments, fn(s) {
      s.generated.start <= offset && offset <= s.generated.end
    })
  case containing {
    [s, ..] -> Ok(map_offset(offset, s.generated, s.template, s.exact))
    [] ->
      output.regions
      |> list.filter(fn(r) {
        r.generated.start <= offset && offset <= r.generated.end
      })
      |> list.sort(fn(a, b) {
        int.compare(
          a.generated.end - a.generated.start,
          b.generated.end - b.generated.start,
        )
      })
      |> list.first
      |> fn(found) {
        case found, end {
          Ok(r), True -> Ok(r.template.end)
          Ok(r), False -> Ok(r.template.start)
          Error(_), _ -> Error(Nil)
        }
      }
  }
}

fn map_offset(offset: Int, from: Span, to: Span, exact: Bool) -> Int {
  case exact, offset == from.end {
    True, _ -> to.start + offset - from.start
    False, True -> to.end
    False, False -> int.min(to.start + offset - from.start, to.end)
  }
}

// EMITTING --------------------------------------------------------------------

fn new() -> Out {
  Out(
    chunks: [],
    offset: 0,
    indent: 0,
    segments: [],
    holes: [],
    regions: [],
    problems: [],
    uses_element: False,
    uses_attribute: False,
    uses_event: False,
    uses_list: False,
  )
}

fn emit(out: Out, text: String) -> Out {
  Out(
    ..out,
    chunks: [text, ..out.chunks],
    offset: out.offset + string.byte_size(text),
  )
}

/// Code that uses `lustre/element`, which then needs importing.
fn emit_element(out: Out, text: String) -> Out {
  Out(..out, uses_element: True) |> emit(text)
}

fn emit_when(out: Out, condition: Bool, text: String) -> Out {
  case condition {
    True -> emit(out, text)
    False -> out
  }
}

fn newline(out: Out) -> Out {
  emit(out, "\n" <> string.repeat("  ", out.indent))
}

fn indented(out: Out, inside: fn(Out) -> Out) -> Out {
  let out = inside(Out(..out, indent: out.indent + 1))
  Out(..out, indent: out.indent - 1)
}

fn emit_piece(out: Out, piece: Piece, kind: Kind) -> Out {
  let segment =
    Segment(
      template: piece.span,
      generated: Span(out.offset, out.offset + string.byte_size(piece.text)),
      kind:,
      exact: True,
    )
  Out(..out, segments: [segment, ..out.segments]) |> emit(piece.text)
}

/// Generated text standing for template text of another length.
fn emit_renamed(out: Out, text: String, template: Span, kind: Kind) -> Out {
  let segment =
    Segment(
      template:,
      generated: Span(out.offset, out.offset + string.byte_size(text)),
      kind:,
      exact: template.end - template.start == string.byte_size(text),
    )
  Out(..out, segments: [segment, ..out.segments]) |> emit(text)
}

fn region(out: Out, from: Int, template: Span) -> Out {
  Out(..out, regions: [Region(Span(from, out.offset), template), ..out.regions])
}

fn problem(out: Out, message: String, span: Span) -> Out {
  Out(..out, problems: [Problem(message, span), ..out.problems])
}

// GLEAM CODE ------------------------------------------------------------------

fn gleam_code(out: Out, code: Code, context: Context) -> Out {
  list.fold(code.parts, out, fn(out, part) {
    case part {
      Gleam(piece) -> emit_piece(out, piece, GleamCode)
      // Markup lines up with the line of Gleam it's written in.
      Markup(node) -> {
        let indent = out.indent
        Out(
          ..node_expression(Out(..out, indent: line_indent(out)), node, context),
          indent:,
        )
      }
    }
  })
}

/// The indentation of the line being written, in levels of two spaces.
fn line_indent(out: Out) -> Int {
  let line = line_loop(out.chunks, "")
  let spaces =
    string.byte_size(line) - string.byte_size(string.trim_start(line))
  spaces / 2
}

fn line_loop(chunks: List(String), acc: String) -> String {
  case chunks {
    [] -> acc
    [chunk, ..rest] ->
      case string.split(chunk, "\n") |> list.last {
        Ok(last) if last != chunk -> last <> acc
        _ -> line_loop(rest, chunk <> acc)
      }
  }
}

// NODES -----------------------------------------------------------------------

type Child {
  /// One element.
  One(Node)
  /// A list of elements, spread into the children.
  Many(Node)
}

fn children_of(nodes: List(Node), context: Context) -> List(Child) {
  list.flat_map(nodes, fn(node) {
    case node {
      Text(text, span) ->
        case jsx_text(text) {
          "" -> []
          text -> [One(Text(text, span))]
        }
      Expression(_, True, _) -> [Many(node)]
      Expression(code, False, _) ->
        case is_list(code, context) {
          True -> [Many(node)]
          False -> [One(node)]
        }
      Fragment(children, _) -> children_of(children, context)
      _ -> [One(node)]
    }
  })
}

/// A bare `{children}`, or a bare prop declared as a list.
fn is_list(code: Code, context: Context) -> Bool {
  case bare_name(code) {
    Ok(name) ->
      case list.find(context.props, fn(prop) { prop.name == name }) {
        Ok(prop) -> string.starts_with(prop_type(prop), "List(")
        Error(_) -> name == "children"
      }
    Error(_) -> False
  }
}

/// A bare prop declared as an element.
fn is_element_prop(code: Code, context: Context) -> Bool {
  case bare_name(code) {
    Ok(name) ->
      case list.find(context.props, fn(prop) { prop.name == name }) {
        Ok(prop) -> {
          let type_ = prop_type(prop)
          string.starts_with(type_, "Element(")
          || string.contains(type_, ".Element(")
        }
        Error(_) -> False
      }
    Error(_) -> False
  }
}

fn prop_type(prop: Prop) -> String {
  case string.split_once(prop.source.text, ":") {
    Ok(#(_, type_)) -> string.trim(type_)
    Error(_) -> ""
  }
}

fn bare_name(code: Code) -> Result(String, Nil) {
  case code.parts {
    [Gleam(piece)] -> {
      let name = string.trim(piece.text)
      case
        name != ""
        && list.all(string.to_graphemes(name), fn(c) {
          c == "_" || string.lowercase(c) != string.uppercase(c) || is_digit(c)
        })
      {
        True -> Ok(name)
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn is_digit(c: String) -> Bool {
  case c {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

/// `{row(order)}`, where `row` is a header function returning markup.
fn calls_markup_function(code: Code, context: Context) -> Bool {
  case code.parts {
    [Gleam(piece)] -> {
      let text = string.trim(piece.text)
      case string.split_once(text, "(") {
        Ok(#(name, _)) ->
          list.any(context.functions, fn(function) {
            function.name == name && function.returns_markup
          })
        Error(_) -> False
      }
    }
    _ -> False
  }
}

fn contains_markup(code: Code) -> Bool {
  list.any(code.parts, fn(part) {
    case part {
      Markup(_) -> True
      Gleam(_) -> False
    }
  })
}

fn root(out: Out, nodes: List(Node), context: Context) -> Out {
  let element = context.aliases.element
  case children_of(nodes, context) {
    [] -> emit_element(out, element <> ".none()")
    [One(node)] -> node_expression(out, node, context)
    children ->
      out
      |> emit_element(element <> ".fragment(")
      |> child_list(children, context)
      |> emit(")")
  }
}

fn child_list(out: Out, children: List(Child), context: Context) -> Out {
  let spreads =
    list.any(children, fn(child) {
      case child {
        Many(_) -> True
        One(_) -> False
      }
    })
  case children, spreads {
    [], _ -> emit(out, "[]")
    [One(Text(..) as node)], _ ->
      out |> emit("[") |> node_expression(node, context) |> emit("]")
    _, False ->
      out
      |> emit("[")
      |> indented(fn(out) {
        list.fold(children, out, fn(out, child) {
          out |> newline |> child_expression(child, context) |> emit(",")
        })
      })
      |> newline
      |> emit("]")
    _, True ->
      Out(..out, uses_list: True)
      |> emit(context.aliases.list <> ".flatten([")
      |> indented(fn(out) {
        list.fold(groups(children), out, fn(out, group) {
          let out = newline(out)
          case group {
            [Many(_) as child] -> child_expression(out, child, context)
            singles ->
              out
              |> emit("[")
              |> list.index_fold(singles, _, fn(out, child, i) {
                out
                |> emit_when(i > 0, ", ")
                |> child_expression(child, context)
              })
              |> emit("]")
          }
          |> emit(",")
        })
      })
      |> newline
      |> emit("])")
  }
}

/// Runs of single elements together, each spread on its own.
fn groups(children: List(Child)) -> List(List(Child)) {
  list.fold(children, [], fn(groups, child) {
    case child, groups {
      Many(_), _ -> [[child], ..groups]
      One(_), [[One(_), ..] as run, ..rest] -> [[child, ..run], ..rest]
      One(_), _ -> [[child], ..groups]
    }
  })
  |> list.map(list.reverse)
  |> list.reverse
}

fn child_expression(out: Out, child: Child, context: Context) -> Out {
  case child {
    One(node) -> node_expression(out, node, context)
    Many(Expression(code:, ..)) -> gleam_code(out, code, context)
    Many(node) -> node_expression(out, node, context)
  }
}

fn node_expression(out: Out, node: Node, context: Context) -> Out {
  let start = out.offset
  let element = context.aliases.element
  case node {
    Text(text, _) ->
      emit_element(out, element <> ".text(" <> string_literal(text) <> ")")

    Expression(code:, ..) ->
      case
        contains_markup(code)
        || is_element_prop(code, context)
        || calls_markup_function(code, context)
      {
        True -> gleam_code(out, code, context)
        False ->
          out
          |> emit_element(element <> ".text(")
          |> gleam_code(code, context)
          |> emit(")")
          |> region(start, code.span)
      }

    Fragment(children, span) ->
      case children_of(children, context) {
        [] -> emit_element(out, element <> ".none()")
        children ->
          out
          |> emit_element(element <> ".fragment(")
          |> child_list(children, context)
          |> emit(")")
          |> region(start, Span(span.start, span.start + 2))
      }

    Element(name:, attributes:, children:) -> {
      let svg = context.svg || name.text == "svg"
      let inner = Context(..context, svg: svg && name.text != "foreignObject")
      let out = case svg {
        True ->
          emit_element(
            out,
            element
              <> ".namespaced(\"http://www.w3.org/2000/svg\", "
              <> string_literal(name.text)
              <> ", ",
          )
        False ->
          emit_element(
            out,
            element <> ".element(" <> string_literal(name.text) <> ", ",
          )
      }
      let out = attribute_list(out, attributes, context)
      case name.text, children {
        // CSS and JavaScript go in as written.
        "style", Some([Text(raw, _)]) | "script", Some([Text(raw, _)]) ->
          emit(
            out,
            ", [" <> element <> ".text(" <> string_literal(raw) <> ")])",
          )
        _, _ ->
          out
          |> emit(", ")
          |> child_list(children_of(option.unwrap(children, []), inner), inner)
          |> emit(")")
      }
      |> region(start, name.span)
    }

    Component(name:, attributes:, children:, area:) ->
      component(out, name, attributes, children, area, context)
      |> region(start, name.span)
  }
}

/// A call to a function from another module: attributes are labels.
fn component(
  out: Out,
  name: Piece,
  attributes: List(Attribute),
  children: option.Option(List(Node)),
  area: Span,
  context: Context,
) -> Out {
  let out =
    out
    |> emit_renamed(function_name(name.text), name.span, ComponentName)
    |> emit("(")
    |> list.fold(attributes, _, fn(out, attribute) {
      argument(out, attribute, context)
    })
  let out = case children {
    None -> out
    Some(children) ->
      out
      |> emit("children: ")
      |> child_list(children_of(children, context), context)
      |> emit(", ")
  }
  Out(..out, holes: [Hole(area, out.offset), ..out.holes])
  |> emit(")")
}

fn argument(out: Out, attribute: Attribute, context: Context) -> Out {
  case attribute {
    Spread(_, span) ->
      problem(
        out,
        "Components take named props, so a list can't be spread into one",
        span,
      )
    Attribute(name:, value:) -> {
      let out = out |> emit_piece(name, Label) |> emit(": ")
      case value {
        Static(text, _) -> emit(out, string_literal(text))
        Dynamic(code) -> gleam_code(out, code, context)
        Bare -> emit(out, "True")
      }
      |> emit(", ")
    }
  }
}

fn attribute_list(
  out: Out,
  attributes: List(Attribute),
  context: Context,
) -> Out {
  let spreads =
    list.any(attributes, fn(attribute) {
      case attribute {
        Spread(..) -> True
        Attribute(..) -> False
      }
    })
  case spreads {
    False ->
      out
      |> emit("[")
      |> list.index_fold(attributes, _, fn(out, attribute, i) {
        out |> emit_when(i > 0, ", ") |> html_attribute(attribute, context)
      })
      |> emit("]")
    True ->
      Out(..out, uses_list: True)
      |> emit(context.aliases.list <> ".flatten([")
      |> list.index_fold(attributes, _, fn(out, attribute, i) {
        let out = emit_when(out, i > 0, ", ")
        case attribute {
          Spread(code, _) -> gleam_code(out, code, context)
          Attribute(..) ->
            out |> emit("[") |> html_attribute(attribute, context) |> emit("]")
        }
      })
      |> emit("])")
  }
}

fn html_attribute(out: Out, attribute: Attribute, context: Context) -> Out {
  let assert Attribute(name:, value:) = attribute
    as "spreads are handled by attribute_list"
  let start = out.offset
  let module = context.aliases.attribute
  let html_name = case name.text {
    "className" -> "class"
    "htmlFor" -> "for"
    other -> other
  }
  let out = Out(..out, uses_attribute: True)
  case event_name(html_name), value {
    Ok(event), Dynamic(code) ->
      Out(..out, uses_event: True)
      |> emit(context.aliases.event <> "." <> event)
      |> gleam_code(code, context)
      |> emit(")")
    Ok(_), _ ->
      problem(
        out,
        name.text <> " takes a message: " <> name.text <> "={Clicked}",
        name.span,
      )
      |> emit(module <> ".none()")
    Error(_), Dynamic(code) ->
      case html_name, boolean_attribute(html_name) {
        "class", _ -> emit(out, module <> ".class(")
        _, Ok(function) -> emit(out, module <> "." <> function <> "(")
        _, Error(_) ->
          emit(
            out,
            module <> ".attribute(" <> string_literal(html_name) <> ", ",
          )
      }
      |> gleam_code(code, context)
      |> emit(")")
    Error(_), Static(text, _) ->
      case html_name {
        "class" -> emit(out, module <> ".class(" <> string_literal(text) <> ")")
        _ ->
          emit(
            out,
            module
              <> ".attribute("
              <> string_literal(html_name)
              <> ", "
              <> string_literal(text)
              <> ")",
          )
      }
    Error(_), Bare ->
      emit(
        out,
        module <> ".attribute(" <> string_literal(html_name) <> ", \"\")",
      )
  }
  |> region(start, name.span)
}

/// `onClick` is `event.on_click(`; an event Lustre has no function for is
/// `event.on("name", ` and takes a decoder.
fn event_name(name: String) -> Result(String, Nil) {
  case name {
    "on" <> rest ->
      case string.first(rest) {
        Ok(first) if first != "" ->
          case
            string.uppercase(first) == first && string.lowercase(first) != first
          {
            False -> Error(Nil)
            True ->
              case rest {
                "Click" -> Ok("on_click(")
                "MouseDown" -> Ok("on_mouse_down(")
                "MouseUp" -> Ok("on_mouse_up(")
                "MouseEnter" -> Ok("on_mouse_enter(")
                "MouseLeave" -> Ok("on_mouse_leave(")
                "MouseOver" -> Ok("on_mouse_over(")
                "MouseOut" -> Ok("on_mouse_out(")
                "KeyPress" -> Ok("on_keypress(")
                "KeyDown" -> Ok("on_keydown(")
                "KeyUp" -> Ok("on_keyup(")
                "Input" -> Ok("on_input(")
                "Change" -> Ok("on_change(")
                "Check" -> Ok("on_check(")
                "Submit" -> Ok("on_submit(")
                "Focus" -> Ok("on_focus(")
                "Blur" -> Ok("on_blur(")
                other ->
                  Ok("on(" <> string_literal(string.lowercase(other)) <> ", ")
              }
          }
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// Attributes Lustre takes a `Bool` for, by their HTML name.
fn boolean_attribute(name: String) -> Result(String, Nil) {
  let name = string.lowercase(name)
  case name {
    "autofocus"
    | "autoplay"
    | "checked"
    | "controls"
    | "disabled"
    | "formnovalidate"
    | "hidden"
    | "inert"
    | "ismap"
    | "itemscope"
    | "loop"
    | "multiple"
    | "muted"
    | "novalidate"
    | "open"
    | "playsinline"
    | "readonly"
    | "required"
    | "selected" -> Ok(name)
    _ -> Error(Nil)
  }
}

/// `StatusBadge` is `status_badge`, `orders.StatusBadge` is
/// `orders.status_badge`; a lowercase name is used as written.
pub fn function_name(tag: String) -> String {
  let segments = string.split(tag, ".")
  let assert Ok(last) = list.last(segments) as "split returns a list"
  let modules = list.take(segments, list.length(segments) - 1)
  list.append(modules, [snake_case(last)]) |> string.join(".")
}

pub fn snake_case(name: String) -> String {
  let graphemes = string.to_graphemes(name)
  let is_upper = fn(c) { string.uppercase(c) == c && string.lowercase(c) != c }
  let at = fn(i) {
    case i < 0 {
      True -> None
      False -> list.drop(graphemes, i) |> list.first |> option.from_result
    }
  }
  graphemes
  |> list.index_map(fn(c, i) {
    // A capital starts a word after a lowercase letter or digit, or ends a
    // run of capitals when a lowercase letter follows: HTMLParser.
    let boundary =
      is_upper(c)
      && case at(i - 1), at(i + 1) {
        None, _ | Some("_"), _ -> False
        Some(p), next ->
          !is_upper(p)
          || case next {
            Some(n) -> !is_upper(n) && n != "_"
            None -> False
          }
      }
    case boundary {
      True -> "_" <> string.lowercase(c)
      False -> string.lowercase(c)
    }
  })
  |> string.concat
}

/// The reverse, for showing Gleam's completions as tags.
pub fn pascal_case(name: String) -> String {
  string.split(name, "_")
  |> list.map(string.capitalise)
  |> string.concat
}

fn string_literal(text: String) -> String {
  let escaped =
    text
    |> string.replace("\\", "\\\\")
    |> string.replace("\"", "\\\"")
    |> string.replace("\n", "\\n")
    |> string.replace("\r", "\\r")
    |> string.replace("\t", "\\t")
  "\"" <> escaped <> "\""
}

/// Text the way JSX reads it: each line is trimmed, blank lines go, and the
/// lines left are joined with a space. Text on a single line is kept as is.
pub fn jsx_text(text: String) -> String {
  let lines = string.split(text, "\n")
  let last = list.length(lines) - 1
  case last {
    0 -> text
    _ ->
      lines
      |> list.index_map(fn(line, i) {
        let line = string.replace(line, "\r", "")
        let line = case i {
          0 -> line
          _ -> trim_start_spaces(line)
        }
        case i == last {
          True -> line
          False -> trim_end_spaces(line)
        }
      })
      |> list.filter(fn(line) { line != "" })
      |> string.join(" ")
  }
}

fn trim_start_spaces(text: String) -> String {
  case text {
    " " <> rest | "\t" <> rest -> trim_start_spaces(rest)
    _ -> text
  }
}

fn trim_end_spaces(text: String) -> String {
  string.reverse(text) |> trim_start_spaces |> string.reverse
}
