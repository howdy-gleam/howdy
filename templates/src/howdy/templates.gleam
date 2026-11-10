//// HTML templates for Lustre, written like React components and compiled to
//// typed Gleam.
////
//// ```html
//// ---
//// import gleam/list
//// import shop/orders.{type Order, status_badge}
//// import shop/templates/layout.{layout}
////
//// props(orders: List(Order))
//// ---
//// <Layout title="Orders">
////   {...list.map(orders, fn(order) {
////     <section class="order">
////       <h2>{order.title}</h2>
////       <StatusBadge status={order.status} />
////     </section>
////   })}
//// </Layout>
//// ```
////
//// Templates live in `templates/`, next to `src/`. In a package `shop`,
//// `templates/orders_page.gsx` becomes the module
//// `shop/templates/orders_page`, generated into `src/shop/templates/`, with
//// one function named after the file: `orders_page(orders: ...)`. It
//// returns a Lustre element, so it works wherever one does: in a
//// `howdy/ui/page`, a live view, or another template.
////
//// ## Writing templates
////
//// - The header between `---` lines is Gleam: imports, helper functions and
////   constants. `props(name: Type, ...)` declares the function's labelled
////   arguments. A template without props needs no header.
//// - Lowercase tags are HTML. A tag starting with a capital, or with a dot,
////   calls a function: `<StatusBadge status={s} />` is
////   `status_badge(status: s)`, `<ui.CardTitle>` is `ui.card_title`.
////   Attributes are its labelled arguments.
//// - Children of a component are passed as `children:`. Using `children` in
////   a template makes it a prop, as in React; `{children}` puts them in.
//// - `{expression}` is text and must be a `String`. Markup in it makes it an
////   element: `{case paid { True -> <b>Paid</b> False -> <></> }}`. A list
////   of elements is spread: `{...list.map(items, row)}`.
//// - Markup can go anywhere Gleam expects an expression, including header
////   functions. `<></>` is a fragment; an empty one is `element.none()`.
//// - `onClick={Clicked}` and the other React event names become
////   `lustre/event` handlers; an event without one takes a decoder.
////   `disabled={busy}` and the other boolean attributes take a `Bool`.
////   `className` and `htmlFor` are accepted for `class` and `for`.
////   `{...attributes}` spreads a list of attributes into an element.
//// - A top-level `<style>` is rendered first, as written.
//// - Whitespace works as in JSX: lines are trimmed, line breaks between
////   text become one space, and blank lines go. `{// a comment}` is a
////   comment.
////
//// ## Generating
////
//// `gleam run -m howdy/templates` writes the module for every template,
//// formatted, and deletes modules whose template is gone. Their directory,
//// `src/<package>/templates/`, holds generated modules only and ignores
//// itself in git; a module there that it didn't write is never replaced.
//// It runs even when the app doesn't compile, so it works on a fresh
//// checkout.
//// `gleam run -m howdy/templates -- check` fails if a template has
//// problems or a module is out of date, for CI and before shipping.
////
//// `gleam build 2>&1 | gleam run -m howdy/templates -- rewrite` points
//// compiler errors back at the template line.

import argv
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import howdy/templates/internal/project
import howdy/templates/internal/rewrite

pub fn main() -> Nil {
  case argv.load().arguments {
    [] | ["gen"] -> report(generate(project.root()))
    ["gen", "--no-gitignore"] ->
      report(generate_with(project.root(), gitignore: False))
    ["check"] ->
      case check(project.root()) {
        Ok(count) ->
          io.println("howdy_templates: " <> plural(count) <> " up to date")
        Error(report) -> {
          io.println_error(report)
          halt(1)
        }
      }
    ["rewrite"] -> io.print(rewrite_output(read_stdin()))
    _ -> {
      io.println_error(
        "usage: gleam run -m howdy/templates -- [gen [--no-gitignore] | check | rewrite]",
      )
      halt(1)
    }
  }
}

fn report(result: Result(String, String)) -> Nil {
  case result {
    Ok(summary) -> io.println(summary)
    Error(report) -> {
      io.println_error(report)
      halt(1)
    }
  }
}

/// Generates the module for every template in the project at `project`,
/// into a directory that ignores itself in git. Returns a summary of what
/// changed, or every problem found, laid out like compiler errors.
pub fn generate(project: String) -> Result(String, String) {
  generate_with(project, gitignore: True)
}

pub fn generate_with(
  project: String,
  gitignore gitignore: Bool,
) -> Result(String, String) {
  use project <- result.try(project.load(project))
  case project.generate_all(project, gitignore:) {
    Ok(generated) -> Ok(summary(generated))
    Error(report) -> Error(report)
  }
}

fn summary(generated: project.Generated) -> String {
  let changes =
    list.flatten([
      list.map(generated.written, fn(path) { "  wrote " <> path }),
      list.map(generated.deleted, fn(path) { "  deleted " <> path }),
    ])
  case changes {
    [] -> "howdy_templates: " <> plural(generated.templates) <> " up to date"
    _ ->
      "howdy_templates: "
      <> plural(generated.templates)
      <> "\n"
      <> string.join(changes, "\n")
  }
}

/// Fails with a report if a template has problems or its module is out of
/// date. Returns how many templates there are.
pub fn check(project: String) -> Result(Int, String) {
  use project <- result.try(project.load(project))
  project.check(project)
}

/// Points compiler output about generated modules at their templates.
pub fn rewrite_output(output: String) -> String {
  rewrite.rewrite(output)
}

fn plural(count: Int) -> String {
  case count {
    1 -> "1 template"
    _ -> int.to_string(count) <> " templates"
  }
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "howdy_templates_ffi", "read_stdin")
fn read_stdin() -> String
