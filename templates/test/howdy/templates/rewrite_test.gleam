import gleam/string
import howdy/templates/internal/position
import howdy/templates/internal/project
import howdy/templates/internal/rewrite
import simplifile

const root = "build/rewrite_test"

const module = "build/rewrite_test/src/shop/templates/home.gleam"

const template = "build/rewrite_test/templates/home.gsx"

const source = "---\nprops(order: Order)\n---\n<h2>{order.titel}</h2>\n"

/// A project whose one template has been generated.
fn generated() -> Nil {
  let _ = simplifile.delete(root)
  let assert Ok(_) = simplifile.create_directory_all(root <> "/templates")
  let assert Ok(_) =
    simplifile.write(root <> "/gleam.toml", "name = \"shop\"\n")
  let assert Ok(_) = simplifile.write(template, source)
  let assert Ok(project) = project.load(root)
  let assert Ok(_) = project.generate_all(project, gitignore: False)
  Nil
}

/// What the compiler says about `titel` in the generated module.
fn compiler_error() -> String {
  let assert Ok(code) = simplifile.read(module)
  let assert Ok(#(before, _)) = string.split_once(code, "titel")
  let #(line, column) = position.from_offset(code, string.byte_size(before))
  let row = string.inspect(line + 1)
  let column = string.inspect(column + 1)
  "error: Unknown record field\n  ┌─ "
  <> module
  <> ":"
  <> row
  <> ":"
  <> column
  <> "\n  │\n"
  <> row
  <> " │     element.text(order.titel)\n  │                        ^^^^^ Did you mean `title`?\n\nThe value has no such field."
}

pub fn errors_point_at_the_template_line_test() {
  generated()
  assert rewrite.rewrite(compiler_error())
    == "error: Unknown record field\n  ┌─ "
    <> template
    <> ":4:12\n  │\n4 │ <h2>{order.titel}</h2>\n  │            ^^^^^ Did you mean `title`?\n\nThe value has no such field."
}

pub fn a_stale_module_is_left_as_the_compiler_said_test() {
  generated()
  let error = compiler_error()
  let assert Ok(_) = simplifile.write(template, source <> "<p>new</p>\n")
  assert rewrite.rewrite(error) == error
}

pub fn other_output_is_left_alone_test() {
  let output =
    "  Compiling shop\nerror: Unknown variable\n  ┌─ /app/src/shop.gleam:3:7\n  │\n3 │   oops\n  │   ^^^^\n"
  assert rewrite.rewrite(output) == output
}

const element_in_text = "error: Type mismatch\n\nExpected type:\n\n    String\n\nFound type:\n\n    Element(a)\n"

pub fn an_element_in_text_gets_a_hint_test() {
  let assert Ok(hint) = rewrite.hint(element_in_text)
  assert string.starts_with(hint, "Hint: {…} is text, so it needs a String.")
  assert rewrite.hint(
      "Expected type:\n\n  Int\n\nFound type:\n\n  Element(a)\n",
    )
    == Error(Nil)
  assert rewrite.hint("error: Unknown variable") == Error(Nil)
}

pub fn hints_are_only_added_to_messages_about_templates_test() {
  let about_a_module =
    "error: Type mismatch\n  ┌─ /app/src/shop.gleam:3:7\n\nExpected type:\n\n    String\n\nFound type:\n\n    Element(a)\n"
  assert rewrite.rewrite(about_a_module) == about_a_module
  let about_a_template =
    string.replace(about_a_module, "src/shop.gleam", "templates/home.gsx")
  assert string.contains(
    rewrite.rewrite(about_a_template),
    "\nHint: {…} is text",
  )
}
