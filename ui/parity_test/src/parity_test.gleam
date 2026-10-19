//// Renders every gallery example, then every class's CSS, to standard
//// output. `run.sh` runs this on Erlang and on JavaScript and compares.
////
//// Islands render a view on the server and then again in the browser, so
//// any difference here is a page whose styles break when an island starts.

import gleam/io
import gleam/list
import howdy/ui/gallery/examples
import howdy/ui/registry
import lustre/element

pub fn main() -> Nil {
  use entry <- list.each(registry.entries())
  use example <- list.each(examples.for(entry.name))
  io.println("=== " <> entry.name <> " / " <> example.title)
  io.println(element.to_string(example.view()))
}
