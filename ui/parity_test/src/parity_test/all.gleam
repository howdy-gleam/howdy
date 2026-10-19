//// The gallery examples, then the CSS of every class they registered.

import gleam/io
import howdy/ui/style
import lustre/element
import parity_test

pub fn main() -> Nil {
  parity_test.main()
  io.println("=== CSS")
  io.println(element.to_string(style.styles()))
}
