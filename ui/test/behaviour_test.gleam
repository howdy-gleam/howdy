import gleam/io
import gleam/string
import howdy/ui/behaviour

/// Which is `priv/behaviour.js`, resolved through the package's priv dir.
@external(erlang, "howdy_ui_ffi", "behaviour_path")
fn path() -> String

type Check {
  Ok(Nil)
  Error(String)
  Skipped
}

@external(erlang, "behaviour_test_ffi", "node_check")
fn node_check(path: String) -> Check

pub fn source_comes_from_priv_test() {
  let source = behaviour.source()
  assert string.starts_with(source, "if (!window.howdyBehaviour) {")
  assert string.ends_with(path(), "/behaviour.js")
  // Reading again hands back the cached copy.
  assert behaviour.source() == source
}

pub fn source_is_valid_javascript_test() {
  case node_check(path()) {
    Ok(Nil) -> Nil
    Skipped ->
      io.println("note: node not on PATH, skipping syntax check of " <> path())
    Error(output) -> panic as { "node --check failed:\n" <> output }
  }
}
