//// The catalogue of everything `gleam run -m howdy/ui add` can copy into a
//// project: components, blocks built from them, and theme presets.
////
//// An entry names its module; everything else is read from the module's
//// source. Its description is the first line of its documentation, and it
//// depends on the entries whose modules it imports, so the catalogue never
//// drifts from the code. `gleam run -m howdy/ui registry` publishes it as
//// JSON, with an `llms.txt` index, for other tools and custom registries.

import gleam/list
import gleam/result
import gleam/string

pub type Kind {
  /// A component module. It depends on `howdy/ui/style`, tokens,
  /// `howdy/ui/words` and, for a few, other components, which copying it
  /// copies too.
  Component
  /// A screen or card composed of components. Copying one copies the
  /// components it uses and points its imports at the copies.
  Block
  /// Light and dark themes, ready to pass to `page.themes`.
  ThemePreset
}

pub type Entry {
  Entry(name: String, kind: Kind, category: String, module: String)
}

fn component(name: String, category: String) -> Entry {
  Entry(name:, kind: Component, category:, module: "howdy/ui/" <> name)
}

fn block(name: String) -> Entry {
  Entry(
    name:,
    kind: Block,
    category: "Blocks",
    module: "howdy/ui/blocks/" <> name,
  )
}

fn preset(name: String) -> Entry {
  Entry(
    name:,
    kind: ThemePreset,
    category: "Themes",
    module: "howdy/ui/themes/" <> name,
  )
}

/// Every entry, in the order `list` shows them.
pub fn entries() -> List(Entry) {
  [
    component("heading", "Typography"),
    component("typography", "Typography"),
    component("kbd", "Typography"),
    component("button", "Actions"),
    component("button_group", "Actions"),
    component("toggle", "Actions"),
    component("input", "Forms"),
    component("field", "Forms"),
    component("checkbox", "Forms"),
    component("switch", "Forms"),
    component("slider", "Forms"),
    component("input_group", "Forms"),
    component("input_otp", "Forms"),
    component("select", "Forms"),
    component("command", "Forms"),
    component("calendar", "Forms"),
    component("questionnaire", "Forms"),
    component("uploader", "Forms"),
    component("rich_text", "Forms"),
    component("layout", "Layout"),
    component("card", "Layout"),
    component("sidebar", "Layout"),
    component("effects", "Layout"),
    component("aspect_ratio", "Layout"),
    component("scroll_area", "Layout"),
    component("resizable", "Layout"),
    component("direction", "Layout"),
    component("dialog", "Overlays"),
    component("drawer", "Overlays"),
    component("popover", "Overlays"),
    component("tooltip", "Overlays"),
    component("menu", "Overlays"),
    component("context_menu", "Overlays"),
    component("menubar", "Overlays"),
    component("hover_card", "Overlays"),
    component("tabs", "Navigation"),
    component("accordion", "Navigation"),
    component("pagination", "Navigation"),
    component("breadcrumb", "Navigation"),
    component("navigation_menu", "Navigation"),
    component("table", "Data display"),
    component("data_table", "Data display"),
    component("chart", "Data display"),
    component("badge", "Data display"),
    component("avatar", "Data display"),
    component("carousel", "Data display"),
    component("item", "Data display"),
    component("progress", "Feedback"),
    component("empty", "Feedback"),
    component("alert", "Feedback"),
    component("toast", "Feedback"),
    component("bell", "Feedback"),
    component("loading", "Feedback"),
    component("chat", "Chat"),
    component("attachment", "Chat"),
    block("app_shell"),
    block("stat_card"),
    block("sign_in"),
    block("sign_up"),
    preset("zinc"),
    preset("stone"),
    preset("rose"),
    preset("green"),
    preset("violet"),
  ]
}

pub fn find(name: String) -> Result(Entry, Nil) {
  list.find(entries(), fn(entry) { entry.name == name })
}

pub fn kind_name(kind: Kind) -> String {
  case kind {
    Component -> "component"
    Block -> "block"
    ThemePreset -> "theme"
  }
}

/// The first paragraph of a module's documentation.
pub fn description(source: String) -> String {
  source
  |> string.split("\n")
  |> list.drop_while(fn(line) { !string.starts_with(line, "//// ") })
  |> list.take_while(fn(line) { string.starts_with(line, "//// ") })
  |> list.map(string.drop_start(_, 5))
  |> string.join(" ")
}

/// The first sentence of a description, for a one-line listing.
pub fn summary(description: String) -> String {
  case string.split_once(description, ". ") {
    Ok(#(sentence, _)) -> sentence <> "."
    Error(Nil) -> description
  }
}

/// The entries a module's source imports, in the order it imports them.
pub fn dependencies(source: String) -> List(String) {
  source
  |> imports
  |> list.filter_map(fn(module) {
    list.find(entries(), fn(entry) { entry.module == module })
    |> result.map(fn(entry) { entry.name })
  })
}

/// The Gleam packages a module's source imports directly, beyond the
/// standard library and howdy_ui itself.
pub fn packages(source: String) -> List(String) {
  let modules = imports(source)
  [
    #("lustre", "lustre"),
    #("sketch", "sketch"),
    #("gleam/json", "gleam_json"),
  ]
  |> list.filter(fn(package) {
    list.any(modules, fn(module) {
      module == package.0 || string.starts_with(module, package.0 <> "/")
    })
  })
  |> list.map(fn(package) { package.1 })
}

/// The modules a source imports, without aliases or unqualified names.
fn imports(source: String) -> List(String) {
  source
  |> string.split("\n")
  |> list.filter_map(fn(line) {
    case line {
      "import " <> rest -> Ok(before(before(rest, ".{"), " "))
      _ -> Error(Nil)
    }
  })
}

fn before(text: String, separator: String) -> String {
  case string.split_once(text, separator) {
    Ok(#(head, _)) -> head
    Error(Nil) -> text
  }
}
