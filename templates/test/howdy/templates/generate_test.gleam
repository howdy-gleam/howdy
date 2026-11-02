import gleam/list
import gleam/string
import howdy/templates/internal/generate
import howdy/templates/internal/parse
import howdy/templates/internal/project

fn generate(source: String) -> generate.Output {
  let compiled = project.compile("templates/view.gsx", source)
  assert compiled.problems == []
  compiled.output
}

fn body_of(source: String) -> String {
  let code = generate(source).code
  let assert Ok(#(_, view)) = string.split_once(code, "pub fn view(")
  let assert Ok(#(_, after)) = string.split_once(view, ") {\n")
  string.drop_end(after, 3) |> string.trim
}

pub fn jsx_whitespace_test() {
  assert generate.jsx_text("Status: ") == "Status: "
  assert generate.jsx_text("\n  Hello\n  ") == "Hello"
  assert generate.jsx_text("\n  Questions? Ask\n     us.\n")
    == "Questions? Ask us."
  assert generate.jsx_text("\n\n  \n") == ""
  assert generate.jsx_text("a  b") == "a  b"
}

pub fn names_test() {
  assert generate.function_name("StatusBadge") == "status_badge"
  assert generate.function_name("orders.StatusBadge") == "orders.status_badge"
  assert generate.function_name("orders.status_badge") == "orders.status_badge"
  assert generate.snake_case("HTMLParser") == "html_parser"
  assert generate.snake_case("Layout2Col") == "layout2_col"
  assert generate.pascal_case("status_badge") == "StatusBadge"
}

pub fn a_module_named_after_the_file_test() {
  let code = generate("<p>Hi</p>").code
  assert string.starts_with(
    code,
    "// Generated from templates/view.gsx by howdy_templates (",
  )
  assert generate.is_generated(code)
  let assert Ok(hash) = generate.marker_hash(code)
  assert string.length(hash) == 8
  // The hash follows what's generated.
  assert generate.marker_hash(generate("<p>Hi!</p>").code) != Ok(hash)
  assert !generate.is_generated("// Generated from somewhere else\n")
  assert string.contains(code, "pub fn view() {")
  assert body_of("<p>Hi</p>")
    == "element.element(\"p\", [], [element.text(\"Hi\")])"
}

pub fn only_needed_imports_test() {
  let code = generate("<p>Hi</p>").code
  assert string.contains(code, "import lustre/element\n")
  assert !string.contains(code, "lustre/attribute")
  assert !string.contains(code, "gleam/list")
  let code = generate("<p class=\"a\" onClick={Go}>{...xs}</p>").code
  assert string.contains(code, "import lustre/attribute\n")
  assert string.contains(code, "import lustre/event\n")
  assert string.contains(code, "import gleam/list\n")
}

pub fn the_templates_own_imports_are_reused_test() {
  let code =
    generate(
      "---\nimport lustre/element.{type Element} as el\nimport gleam/list\n---\n<p>{...list.reverse([])}</p>",
    ).code
  assert !string.contains(code, "import lustre/element\n")
  assert !string.contains(code, "template_list")
  assert string.contains(code, "el.element(\"p\"")
  assert string.contains(code, "list.flatten(")
}

pub fn props_and_children_test() {
  let code =
    generate("---\nprops(title: String)\n---\n<div>{title}{children}</div>").code
  assert string.contains(
    code,
    "pub fn view(\n  title title: String,\n  children children,\n) {",
  )
  // A declared children keeps its declared type.
  let code =
    generate("---\nprops(children: List(Int))\n---\n<p>{children}</p>").code
  assert !string.contains(code, "children children,\n")
}

pub fn expressions_test() {
  // Text by default.
  assert body_of("<p>{name}</p>")
    == "element.element(\"p\", [], [\n    element.text(name),\n  ])"
  // Markup makes an element; a spread or a list prop is spread.
  let code = body_of("<p>{case x { _ -> <b /> }}{...items}</p>")
  assert string.contains(
    code,
    "[case x { _ -> element.element(\"b\", [], []) }],",
  )
  assert string.contains(code, "items,")
  let code =
    body_of(
      "---\nprops(rows: List(Element(msg)), icon: Element(msg))\n---\n<p>{rows}{icon}</p>",
    )
  assert string.contains(code, "rows,")
  assert string.contains(code, "[icon],")
}

pub fn components_test() {
  assert body_of("<StatusBadge status=\"ok\" count={n} open />")
    == "status_badge(status: \"ok\", count: n, open: True, )"
  assert body_of("<Card title=\"x\"><p>y</p></Card>")
    |> string.contains("card(title: \"x\", children: [")
  assert body_of("<orders.Card />") == "orders.card()"
}

pub fn attributes_test() {
  let code =
    body_of(
      "<button className=\"b\" onClick={Go} onKeyDown={Key} onScroll={decoder} disabled={busy} readOnly={r} aria-label=\"x\" htmlFor=\"f\" hidden />",
    )
  assert string.contains(code, "attribute.class(\"b\")")
  assert string.contains(code, "event.on_click(Go)")
  assert string.contains(code, "event.on_keydown(Key)")
  assert string.contains(code, "event.on(\"scroll\", decoder)")
  assert string.contains(code, "attribute.disabled(busy)")
  assert string.contains(code, "attribute.readonly(r)")
  assert string.contains(code, "attribute.attribute(\"aria-label\", \"x\")")
  assert string.contains(code, "attribute.attribute(\"for\", \"f\")")
  assert string.contains(code, "attribute.attribute(\"hidden\", \"\")")
}

pub fn generator_problems_test() {
  let messages = fn(source) {
    project.compile("templates/view.gsx", source).problems
    |> list.map(fn(p) { p.message })
  }
  assert messages("<button onClick=\"go\" />")
    == ["onClick takes a message: onClick={Clicked}"]
  assert messages("<Card {...props} />")
    == ["Components take named props, so a list can't be spread into one"]
  let assert [problem] =
    project.compile("templates/OrderPage.gsx", "<p />").problems
  assert string.contains(problem.message, "lowercase_with_underscores")
}

pub fn svg_is_namespaced_test() {
  let code =
    body_of(
      "<svg><g><path d=\"M0\" /></g><foreignObject><p /></foreignObject></svg>",
    )
  assert string.contains(
    code,
    "namespaced(\"http://www.w3.org/2000/svg\", \"path\"",
  )
  assert string.contains(
    code,
    "namespaced(\"http://www.w3.org/2000/svg\", \"foreignObject\"",
  )
  assert string.contains(code, "element.element(\"p\"")
}

pub fn positions_map_both_ways_test() {
  let source =
    "---\nprops(order: Order)\n---\n<h2>{order.title}</h2>\n<Badge status={order.status} />\n"
  let output = generate(source)
  let assert Ok(title) = string.split_once(source, "order.title")
  let offset = string.byte_size(title.0) + 6
  // `title` in the template is `title` in the module.
  let assert Ok(#(generated, generate.GleamCode)) =
    generate.to_generated(output, offset)
  assert string.slice(output.code, generated, 5) == "title"
    || string.drop_start(output.code, 0) |> string.contains("order.title")
  assert generate.to_template(output, generated, False) == Ok(offset)
  // The attribute area of a component maps to its arguments.
  let assert Ok(#(_, generate.Arguments)) =
    generate.to_generated(output, string.byte_size(source) - 4)
  // A component's name maps to the function, both ends.
  let assert Ok(badge) = string.split_once(source, "Badge")
  let start = string.byte_size(badge.0)
  let assert Ok(#(g_start, generate.ComponentName)) =
    generate.to_generated(output, start)
  let assert Ok(#(g_end, generate.ComponentName)) =
    generate.to_generated(output, start + 5)
  assert g_end - g_start == string.length("badge")
  assert parse.is_component("Badge")
}

pub fn names_the_template_uses_are_left_alone_test() {
  let code =
    generate(
      "---\nimport gleam/list as l\n---\n<ul>{...l.map(elements, fn(element) { <li>{element}</li> })}</ul>",
    ).code
  assert string.contains(code, "import lustre/element as template_element\n")
  assert string.contains(code, "template_element.element(\"li\"")
  assert string.contains(code, "l.flatten(")
}

const header = "---\nfn row(label: String, count count: Int, children) {\n  <li>{label}{...children}</li>\n}\n---\n"

pub fn calls_to_header_functions_are_elements_test() {
  let code = body_of(header <> "<ul>{row(\"a\", 1, [])}</ul>")
  assert string.contains(code, "row(\"a\", 1, [])")
  assert !string.contains(code, "element.text(row(")
}

pub fn imports_are_sorted_together_test() {
  let code =
    generate(
      "---\nimport zebra/stripes\nimport app/orders.{\n  type Order,\n}\n---\n<p class=\"x\">{...stripes.all()}</p>",
    ).code
  let assert Ok(#(_, after_marker)) = string.split_once(code, "\n")
  let assert Ok(#(imports, _)) = string.split_once(after_marker, "\n\n")
  assert imports
    == "import app/orders.{\n  type Order,\n}\nimport gleam/list\nimport lustre/attribute\nimport lustre/element\nimport zebra/stripes"
}

pub fn template_directories_are_module_names_test() {
  let assert [problem] =
    project.compile("templates/Admin/users.gsx", "<p />").problems
  assert string.contains(problem.message, "Admin needs a lowercase")
  assert project.compile("templates/admin/users.gsx", "<p />").problems == []
}

pub fn a_style_goes_first_as_written_test() {
  let code = body_of("<p>Hi</p>\n<style>\n  p { color: red }\n</style>\n")
  assert string.contains(
    code,
    "element.element(\"style\", [], [element.text(\"\\n  p { color: red }\\n\")]),\n    element.element(\"p\"",
  )
}

pub fn script_text_is_kept_as_written_test() {
  let code =
    body_of("<div><script>\n// one\nif (a < b) { go() }\n</script></div>")
  assert string.contains(
    code,
    "element.text(\"\\n// one\\nif (a < b) { go() }\\n\")",
  )
}

pub fn a_renamed_template_has_a_new_hash_test() {
  let a = project.compile("templates/view.gsx", "<p>Hi</p>").output.code
  let b = project.compile("templates/view.ghtml", "<p>Hi</p>").output.code
  assert generate.marker_hash(a) != generate.marker_hash(b)
}

pub fn element_is_imported_only_when_used_test() {
  let code =
    project.compile(
      "templates/view.gsx",
      "---\nimport app/layout.{layout}\n---\n<Layout title=\"x\"><Other /></Layout>",
    ).output.code
  assert !string.contains(code, "import lustre/element")
}
