//// Write the site's CSS to `priv/static/ui.css` for publishing. Run with
//// `gleam run -m tasks/css` whenever the styles change.

import gleam/io
import howdy/ui/export
import howdy/ui/theme
import howdy_live_example/ui/all

pub fn main() -> Nil {
  let assert Ok(Nil) =
    export.new(theme.default_themes())
    |> export.classes(all.classes())
    |> export.write(to: "priv/static/ui.css")
  io.println("wrote priv/static/ui.css")
}
