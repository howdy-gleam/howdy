//// The browser code for `howdy/ui/rich_text`: ProseMirror and the editor
//// built on it, bundled into this package's `priv/rich_text.js`, and the
//// controller that serves it. A copy of the editor made with
//// `gleam run -m howdy/ui add rich_text` still loads this code, so it
//// stays in howdy_ui.

import gleam/http/response
import howdy/controller.{type Controller}
import howdy/ui/internal/rich_text_script

const prefix = "/_howdy/rich-text"

/// Where the browser loads the editor from. The name changes whenever the
/// code does, so it is cached for good.
pub fn url() -> String {
  prefix <> "/" <> rich_text_script.hash <> ".js"
}

/// The controller serving the code under `/_howdy/rich-text`, as
/// `ui.rich_text()`.
pub fn controller() -> Controller {
  controller.new(prefix)
  |> controller.get("/:file", fn(ctx) {
    // A page from before a deploy may ask for an older name. It gets the
    // code there is now, but not cached for good.
    let cache = case controller.param(ctx, "file") {
      Ok(file) if file == rich_text_script.hash <> ".js" ->
        "public, max-age=31536000, immutable"
      _ -> "no-cache"
    }
    controller.text(ctx, source())
    |> response.set_header("content-type", "text/javascript; charset=utf-8")
    |> response.set_header("cache-control", cache)
  })
}

/// The bundle, read from `priv/rich_text.js` the first time it is needed.
@external(erlang, "howdy_ui_ffi", "rich_text_source")
fn source() -> String
