import gleam/list
import gleam/option.{None, Some}
import gleam/string
import howdy/templates/internal/parse
import howdy/templates/internal/signatures
import howdy/templates/internal/syntax.{
  Attribute, Bare, Code, Component, Dynamic, Element, Expression, Fragment,
  Gleam, Markup, Piece, Span, Spread, Static, Text,
}

fn body(source: String) -> List(syntax.Node) {
  let #(template, problems) = parse.parse(source)
  assert problems == []
  template.body
}

fn problems(source: String) -> List(String) {
  parse.parse(source).1 |> list.map(fn(problem) { problem.message })
}

/// Whether the only expression in `source` has markup in it.
fn has_markup(source: String) -> Bool {
  case body(source) {
    [Expression(Code(parts, _), _, _)] ->
      list.any(parts, fn(part) {
        case part {
          Markup(_) -> True
          Gleam(_) -> False
        }
      })
    other -> panic as { "not one expression: " <> string.inspect(other) }
  }
}

pub fn comparisons_and_operators_are_not_markup_test() {
  assert !has_markup("{a < b}")
  assert !has_markup("{a<b}")
  assert !has_markup("{x <> \"<p>\"}")
  assert !has_markup("{<<1, 2>>}")
  assert !has_markup("{f(a) < g(b)}")
  assert !has_markup("{list.length(xs) <= 3}")
  assert !has_markup("{\"<p>not markup</p>\"}")
}

pub fn markup_where_an_expression_starts_test() {
  assert has_markup("{f(<p />)}")
  assert has_markup("{[<li />, <li />]}")
  assert has_markup("{case x { A -> <p /> B -> <></> }}")
  assert has_markup("{fn() { <b>hi</b> }}")
  assert has_markup("{let x = <p /> x}")
  assert has_markup("{f(a, <p />)}")
  assert has_markup("{f(label: <p />)}")
}

pub fn nested_markup_and_code_test() {
  let assert [Expression(Code([Gleam(_), Markup(li), Gleam(_)], _), True, _)] =
    body("{...list.map(xs, fn(x) { <li>{x}</li> })}")
  let assert Element(Piece("li", _), [], Some([Expression(code, False, _)])) =
    li
  assert code.parts == [Gleam(Piece("x", Span(30, 31)))]
}

pub fn elements_components_and_fragments_test() {
  let assert [
    Element(Piece("p", _), [], Some([Text("Hi", _)])),
    Component(
      Piece("StatusBadge", _),
      [Attribute(Piece("status", _), Static("ok", _))],
      None,
      _,
    ),
    Component(Piece("orders.card", _), [], Some([Text("x", _)]), _),
    Fragment([Element(Piece("br", _), [], None)], _),
  ] =
    body(
      "<p>Hi</p><StatusBadge status=\"ok\" /><orders.card>x</orders.card><><br></>",
    )
}

pub fn attributes_test() {
  let assert [Element(_, attributes, None)] =
    body("<input type='text' value={v} disabled {...rest} data-x=\"&amp;\" />")
  let assert [
    Attribute(Piece("type", _), Static("text", _)),
    Attribute(Piece("value", _), Dynamic(_)),
    Attribute(Piece("disabled", _), Bare),
    Spread(_, _),
    Attribute(Piece("data-x", _), Static("&", _)),
  ] = attributes
}

pub fn void_elements_need_no_closing_tag_test() {
  let assert [
    Element(
      Piece("div", _),
      [],
      Some([Element(Piece("img", _), _, None), Text("x", _)]),
    ),
  ] = body("<div><img src=\"a\">x</div>")
}

pub fn header_and_props_test() {
  let #(template, problems) =
    parse.parse(
      "---\nimport gleam/int\n\nprops(count: Int, label: String,)\n\nfn double(n) { n * 2 }\n---\n<p>{label}</p>\n",
    )
  assert problems == []
  assert list.map(template.props, fn(prop) { prop.name }) == ["count", "label"]
  assert list.map(template.props, fn(prop) { prop.source.text })
    == ["count: Int", "label: String"]
  let assert [Piece("import gleam/int", _)] = template.imports
  let assert [code] = template.header
  let assert [Gleam(Piece("fn double(n) { n * 2 }", _))] = code.parts
}

pub fn children_is_noticed_test() {
  assert parse.parse("<div>{children}</div>").0.uses_children
  assert parse.parse("<div>{...list.reverse(children)}</div>").0.uses_children
  assert !parse.parse("<div>{props.children}</div>").0.uses_children
  assert !parse.parse("<div>children</div>").0.uses_children
}

pub fn comments_test() {
  assert body("<p>{// a note}hi<!-- html --></p>")
    == [Element(Piece("p", Span(1, 2)), [], Some([Text("hi", Span(14, 16))]))]
}

pub fn entities_test() {
  assert parse.decode_entities("a &amp; b &lt;c&gt; &#169; &#x2014; &bogus; &")
    == "a & b <c> © — &bogus; &"
}

pub fn problems_test() {
  assert problems("<div><h2>title</div>") == ["<h2> is not closed"]
  assert problems("<div>") == ["<div> is never closed"]
  assert problems("<p>x</p></div>") == ["Unexpected </div>"]
  assert problems("{f(x)") == ["Missing }"]
  assert problems("<p class=x>")
    == [
      "Expected a value after class=: \"text\" or {code}",
      "<p> is never closed",
    ]
  assert problems("---\nprops(x)\n<p />")
    == ["The header opened by --- is never closed by another ---"]
  assert problems("---\nprops(count)\n---\n")
    == ["A prop needs a type: count: String"]
  assert problems("---\nprops(Count: Int)\n---\n")
    == ["Count is not a valid prop name"]
  assert problems("---\nprops(a: Int)\nprops(b: Int)\n---\n")
    == ["A template has one props(...)"]
  assert problems("<><p></>")
    == ["<p> is not closed", "<> is never closed by </>"]
    || problems("<><p></>") == ["<p> is not closed"]
  assert problems("{list.map(xs, fn(x) { <li>{x} })}") == ["<li> is not closed"]
}

pub fn header_functions_test() {
  let #(template, _) =
    parse.parse(
      "---\nimport gleam/int\n\nfn row(order: Order, wide wide: Bool) {\n  <tr>{order.title}</tr>\n}\n\npub fn total(lines) -> Int { 0 }\n\nconst x = \"fn nope() { <p/> }\"\n---\n",
    )
  assert template.functions
    == [
      syntax.Function(
        name: "row",
        parameters: [
          signatures.Param(label: None, name: "order", type_: "Order"),
          signatures.Param(label: Some("wide"), name: "wide", type_: "Bool"),
        ],
        returns_markup: True,
      ),
      syntax.Function(
        name: "total",
        parameters: [signatures.Param(label: None, name: "lines", type_: "")],
        returns_markup: False,
      ),
    ]
}

pub fn imports_over_several_lines_test() {
  let #(template, problems) =
    parse.parse(
      "---\nimport a/b.{\n  type C,\n  d,\n}\nimport e\nconst x = 1\n---\n",
    )
  assert problems == []
  assert list.map(template.imports, fn(piece) { piece.text })
    == ["import a/b.{\n  type C,\n  d,\n}", "import e"]
  let assert [code] = template.header
  assert code.parts == [Gleam(Piece("const x = 1", Span(43, 54)))]
}
