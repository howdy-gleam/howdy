import howdy/ui/internal/islands

pub fn local_path_dependencies_become_absolute_test() {
  let toml =
    "[dependencies]\nlibrary = { path = \"../library\" }\nhowdy = \">= 1.0.0\""
  assert islands.absolute_paths(toml, "/apps/shop")
    == "[dependencies]\nlibrary = { path = \"/apps/library\" }\nhowdy = \">= 1.0.0\""
}

pub fn absolute_paths_are_left_alone_test() {
  let toml = "[dependencies]\nlibrary = { path = \"/srv/library\" }"
  assert islands.absolute_paths(toml, "/apps/shop") == toml
}

pub fn git_dependency_paths_stay_relative_test() {
  let toml =
    "[dependencies]\nhowdy_ui = { git = \"https://github.com/howdy-gleam/howdy.git\", ref = \"v1.0.0\", path = \"ui\" }\nlibrary = { path = \"../library\" }"
  assert islands.absolute_paths(toml, "/apps/shop")
    == "[dependencies]\nhowdy_ui = { git = \"https://github.com/howdy-gleam/howdy.git\", ref = \"v1.0.0\", path = \"ui\" }\nlibrary = { path = \"/apps/library\" }"
}

pub fn git_dependency_tables_keep_their_path_test() {
  let toml =
    "[dependencies.howdy_ui]\npath = \"ui\"\ngit = \"https://github.com/howdy-gleam/howdy.git\"\nref = \"v1.0.0\"\n\n[dependencies.library]\npath = \"../library\""
  assert islands.absolute_paths(toml, "/apps/shop")
    == "[dependencies.howdy_ui]\npath = \"ui\"\ngit = \"https://github.com/howdy-gleam/howdy.git\"\nref = \"v1.0.0\"\n\n[dependencies.library]\npath = \"/apps/library\""
}

pub fn manifest_git_packages_keep_their_path_test() {
  let manifest =
    "packages = [\n  { name = \"howdy_ui\", version = \"1.0.0\", source = \"git\", repo = \"https://github.com/howdy-gleam/howdy.git\", commit = \"e2cc7e1\", path = \"ui\" },\n  { name = \"library\", version = \"1.0.0\", source = \"local\", path = \"../library\" },\n]"
  assert islands.absolute_paths(manifest, "/apps/shop")
    == "packages = [\n  { name = \"howdy_ui\", version = \"1.0.0\", source = \"git\", repo = \"https://github.com/howdy-gleam/howdy.git\", commit = \"e2cc7e1\", path = \"ui\" },\n  { name = \"library\", version = \"1.0.0\", source = \"local\", path = \"/apps/library\" },\n]"
}
