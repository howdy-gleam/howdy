import gleam/list
import gleam/string
import howdy/templates/internal/format.{Run}
import howdy/templates/internal/generate
import howdy/templates/internal/project

pub fn alignment_skips_whitespace_and_commas_test() {
  let raw = "f(a, b, )"
  let formatted = "f(a, b)"
  let assert Ok(runs) = format.align(raw, formatted)
  assert runs == [Run(0, 0, 4), Run(5, 5, 1), Run(8, 6, 1)]
  // `b` stays `b`; the dropped comma goes to what follows it.
  assert format.to_formatted(runs, 5) == 5
  assert format.to_raw(runs, 5) == 5
  assert format.to_formatted(runs, 6) == 6
  assert format.to_raw(runs, 6) == 8
  assert format.align("f(a)", "f(b)") == Error(Nil)
}

pub fn generated_modules_are_formatted_test() {
  let source =
    "---\nimport gleam/list\n---\n<ul>{...list.map([\"a\", \"b\"], fn(x) { <li class=\"item\" data-long-attribute-name=\"some long value\">{x}</li> })}</ul>"
  let compiled = project.compile("templates/view.gsx", source)
  let assert Ok(formatted) = format.format(compiled.output.code)
  assert formatted.code != compiled.output.code
  // Already formatted, it stays as it is.
  assert format.format(formatted.code)
    |> fn(r) {
      case r {
        Ok(again) -> again.code == formatted.code
        Error(_) -> False
      }
    }
  // A field in the template is found in the formatted module.
  let assert Ok(x) = string.split_once(source, "{x}")
  let offset = string.byte_size(x.0) + 1
  let assert Ok(#(raw, generate.GleamCode)) =
    generate.to_generated(compiled.output, offset)
  let at = format.to_formatted(formatted.runs, raw)
  assert string.slice(formatted.code, at, 1) == "x"
  assert generate.to_template(
      compiled.output,
      format.to_raw(formatted.runs, at),
      False,
    )
    == Ok(offset)
}

pub fn modules_that_wont_format_are_written_as_generated_test() {
  let results = format.format_all(["pub fn ok() { 1 }\n", "pub fn broken( {\n"])
  assert list.map(results, fn(r) {
      case r {
        Ok(_) -> True
        Error(_) -> False
      }
    })
    == [True, False]
}
