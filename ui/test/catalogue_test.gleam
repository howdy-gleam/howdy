import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import howdy
import howdy/testing
import howdy/ui
import howdy/ui/attachment
import howdy/ui/chat
import howdy/ui/gallery
import howdy/ui/gallery/examples
import howdy/ui/internal/stylesheet
import howdy/ui/registry
import howdy/ui/theme
import howdy/ui/themes/green
import howdy/ui/themes/rose
import howdy/ui/themes/stone
import howdy/ui/themes/violet
import howdy/ui/themes/zinc
import howdy/ui/words
import lustre/attribute
import lustre/element.{type Element, text}
import simplifile

fn render(element: Element(msg)) -> String {
  element.to_string(element)
}

// -- Registry ----------------------------------------------------------------

pub fn descriptions_are_whole_first_paragraphs_test() {
  let source =
    "//// First line of the\n//// description.\n////\n//// Not this.\n\nimport x\n"
  assert registry.description(source) == "First line of the description."
  assert registry.summary("One. Two.") == "One."
  assert registry.summary("Only one") == "Only one"
}

pub fn dependencies_and_packages_come_from_imports_test() {
  let source =
    "import howdy/ui/button.{Primary}\nimport howdy/ui/style.{class}\nimport howdy/ui/card\nimport lustre/element/html\nimport gleam/json\nimport lustre/runtime/app as lustre_app\n"
  assert registry.dependencies(source) == ["button", "card"]
  assert registry.packages(source) == ["lustre", "gleam_json"]
}

pub fn names_are_unique_test() {
  let names = list.map(registry.entries(), fn(entry) { entry.name })
  assert list.length(list.unique(names)) == list.length(names)
}

// -- Gallery -----------------------------------------------------------------

pub fn every_entry_has_examples_drawn_from_real_functions_test() {
  let assert Ok(source) = simplifile.read("src/howdy/ui/gallery/examples.gleam")
  use entry <- list.each(registry.entries())
  let found = examples.for(entry.name)
  assert found != []
  use example <- list.each(found)
  assert string.contains(source, "pub fn " <> example.function <> "(")
  // Every example draws without failing.
  assert render(example.view()) != ""
}

fn app() -> howdy.App {
  howdy.new() |> howdy.controller(gallery.controller(at: "/ui"))
}

pub fn the_gallery_serves_every_entry_test() {
  let index = testing.get("/ui") |> testing.send(app())
  assert index.status == 200
  assert string.contains(
    testing.text(index),
    "href=\"/ui/button?theme=default\"",
  )

  let page = testing.get("/ui/button") |> testing.send(app())
  assert page.status == 200
  let html = testing.text(page)
  assert string.contains(html, "gleam run -m howdy/ui add button")
  // The code shown is the example's own source.
  assert string.contains(
    html,
    "ui.button(Primary, [], [text(&quot;Primary&quot;)])",
  )

  let block = testing.get("/ui/sign_up?theme=rose") |> testing.send(app())
  assert string.contains(
    testing.text(block),
    "/ui/sign_up/preview/0?theme=rose",
  )
  assert string.contains(testing.text(block), "Copying it also copies")

  let preview = testing.get("/ui/sign_up/preview/0") |> testing.send(app())
  assert preview.status == 200
  assert string.contains(testing.text(preview), "Create an account")

  assert { testing.get("/ui/nothing") |> testing.send(app()) }.status == 404
  assert { testing.get("/ui/button/preview/9") |> testing.send(app()) }.status
    == 404
}

// -- Themes ------------------------------------------------------------------

fn channel(hex: String, at: Int) -> Float {
  let assert Ok(value) = int.base_parse(string.slice(hex, at, 2), 16)
  let c = int.to_float(value) /. 255.0
  case c <=. 0.03928 {
    True -> c /. 12.92
    False -> {
      let assert Ok(linear) = float.power({ c +. 0.055 } /. 1.055, 2.4)
      linear
    }
  }
}

fn luminance(colour: String) -> Float {
  let hex = string.drop_start(colour, 1)
  0.2126
  *. channel(hex, 0)
  +. 0.7152
  *. channel(hex, 2)
  +. 0.0722
  *. channel(hex, 4)
}

fn contrast(a: String, b: String) -> Float {
  let la = luminance(a)
  let lb = luminance(b)
  { float.max(la, lb) +. 0.05 } /. { float.min(la, lb) +. 0.05 }
}

pub fn every_theme_meets_contrast_minimums_test() {
  let all =
    [
      theme.default_themes(),
      zinc.themes(),
      stone.themes(),
      rose.themes(),
      green.themes(),
      violet.themes(),
    ]
    |> list.flat_map(fn(themes) { [themes.default, ..themes.alternatives] })
  use current <- list.each(all)
  let c = current.colors
  let pairs = [
    #("text on background", c.text, c.background, 4.5),
    #("text on surface", c.text, c.surface, 4.5),
    #("text on muted", c.text, c.muted, 4.5),
    #("muted text on surface", c.text_muted, c.surface, 4.5),
    #("text on primary", c.on_primary, c.primary, 4.5),
    #("text on danger", c.on_danger, c.danger, 4.5),
    #("danger on surface", c.danger, c.surface, 4.5),
    #("focus ring on background", c.focus, c.background, 3.0),
  ]
  use #(what, fore, back, minimum) <- list.each(pairs)
  let ratio = contrast(fore, back)
  case ratio >=. minimum {
    True -> Nil
    False ->
      panic as {
        current.name
        <> " "
        <> what
        <> " is "
        <> float.to_string(float.to_precision(ratio, 2))
      }
  }
}

pub fn presets_are_named_like_the_built_in_themes_test() {
  use themes <- list.each([
    zinc.themes(),
    stone.themes(),
    rose.themes(),
    green.themes(),
    violet.themes(),
  ])
  assert themes.default.name == "light"
  assert list.map(themes.alternatives, fn(t) { t.name }) == ["dark"]
}

// -- Chat and friends --------------------------------------------------------

pub fn conversations_are_logs_laid_out_from_the_bottom_test() {
  let html =
    ui.chat_conversation(words.english(), [attribute.aria_label("Messages")], [
      ui.chat_note([text("Today")]),
      ui.chat_message(
        chat.Outgoing,
        attributes: [],
        avatar: element.none(),
        header: [],
        content: [ui.chat_bubble(chat.Outgoing, [text("Hi")])],
        footer: [],
      ),
    ])
    |> render
  assert string.contains(html, "role=\"log\"")
  assert string.contains(html, "tabindex=\"0\"")
  assert string.contains(html, "<article")
  assert string.contains(html, ">Hi</div>")
}

pub fn avatars_fall_back_to_initials_test() {
  let html = render(ui.avatar(src: "/a.png", alt: "Ada", initials: "AL"))
  assert string.contains(html, ">AL</span>")
  assert string.contains(html, "data-howdy-on-error=\"remove\"")
  assert string.contains(html, "alt=\"Ada\"")
}

pub fn progress_is_announced_with_its_value_test() {
  let html = render(ui.progress(label: "Upload", value: 150, max: 100))
  assert string.contains(html, "role=\"progressbar\"")
  // Values are clamped to the range.
  assert string.contains(html, "aria-valuenow=\"100\"")
  assert string.contains(html, "width:100%")
}

pub fn attachments_show_their_type_and_upload_test() {
  let uploading =
    render(
      ui.attachment(
        words: attachment.english(),
        name: "report.pdf",
        detail: "2 MB",
        status: attachment.Uploading(40),
        media: None,
        actions: [],
      ),
    )
  assert string.contains(uploading, ">PDF</span>")
  assert string.contains(uploading, "aria-valuenow=\"40\"")
  let done =
    render(
      ui.attachment(
        words: attachment.english(),
        name: "notes",
        detail: "",
        status: attachment.Done,
        media: None,
        actions: [],
      ),
    )
  assert string.contains(done, ">FILE</span>")
  assert !string.contains(done, "progressbar")
}

pub fn shimmer_registers_its_animation_test() {
  let #(html, css) =
    stylesheet.scoped(fn() { render(ui.shimmer([text("Thinking")])) })
  assert !string.contains(html, "<style")
  assert string.contains(css, "@keyframes howdy-shimmer")
  assert string.contains(css, "prefers-reduced-motion")
}
