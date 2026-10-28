//// What a template parses into. Every piece of Gleam keeps its byte span
//// in the template, so the generator can record where it ends up.

import gleam/option.{type Option}
import gleam/set.{type Set}
import howdy/templates/internal/signatures

/// Byte offsets into the template, end exclusive.
pub type Span {
  Span(start: Int, end: Int)
}

/// Gleam source copied verbatim into the generated module.
pub type Piece {
  Piece(text: String, span: Span)
}

pub type Template {
  Template(
    /// The header's imports, each a whole statement.
    imports: List(Piece),
    /// The rest of the header's Gleam code, without `props(...)`: helper
    /// functions and constants, in order.
    header: List(Code),
    props: List(Prop),
    body: List(Node),
    /// The CSS of the template's top-level `<style>` elements, scoped to
    /// the elements it renders.
    styles: List(Piece),
    /// Whether the body mentions `children`, which then becomes a prop
    /// without being declared, as in React.
    uses_children: Bool,
    /// Every name the template's code uses, header and body, so generated
    /// code can stay clear of them.
    names: Set(String),
    /// Functions defined in the header.
    functions: List(Function),
  )
}

/// A function in the header. Its parameters are known from its source, so
/// it can be used as a tag without labelled arguments.
pub type Function {
  Function(
    name: String,
    parameters: List(signatures.Param),
    returns_markup: Bool,
  )
}

/// `name: Type` in `props(...)`; `source` is the whole declaration.
pub type Prop {
  Prop(name: String, source: Piece)
}

/// Gleam code, with markup wherever an expression can start.
pub type Code {
  Code(parts: List(Part), span: Span)
}

pub type Part {
  Gleam(Piece)
  Markup(Node)
}

pub type Node {
  /// Text as written, entities decoded; whitespace is handled the way JSX
  /// does when the module is generated.
  Text(text: String, span: Span)
  /// `{code}`, or `{...code}` when `spread`. `span` covers the braces.
  Expression(code: Code, spread: Bool, span: Span)
  /// An HTML element: its name starts with a lowercase letter and has no
  /// dot. `children` is `None` for `<br />` and void elements.
  Element(
    name: Piece,
    attributes: List(Attribute),
    children: Option(List(Node)),
  )
  /// `<StatusBadge />` or `<orders.StatusBadge />`: a call to a Gleam
  /// function. `area` is the attribute area of the start tag, where the
  /// language server offers the function's labels.
  Component(
    name: Piece,
    attributes: List(Attribute),
    children: Option(List(Node)),
    area: Span,
  )
  Fragment(children: List(Node), span: Span)
}

pub type Attribute {
  Attribute(name: Piece, value: Value)
  /// `{...code}`
  Spread(code: Code, span: Span)
}

pub type Value {
  /// The decoded text between the quotes, and the span including them.
  Static(text: String, span: Span)
  Dynamic(code: Code)
  Bare
}

pub type Problem {
  Problem(message: String, span: Span)
}
