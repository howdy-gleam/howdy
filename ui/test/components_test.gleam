import gleam/list
import gleam/string
import howdy/ui
import howdy/ui/alert
import howdy/ui/badge
import howdy/ui/button
import howdy/ui/internal/stylesheet
import howdy/ui/layout
import howdy/ui/registry
import howdy/ui/style
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html
import simplifile
import sketch/css

fn render(element: Element(msg)) -> String {
  element.to_string(element)
}

fn class_of(class: css.Class) -> String {
  let assert Ok(name) =
    style.class(class)
    |> list.wrap
    |> html.div([])
    |> render
    |> string.split_once("class=\"")
  let assert Ok(#(name, _)) = string.split_once(name.1, "\"")
  name
}

pub fn every_variant_and_size_has_its_own_class_test() {
  let classes = button.classes()
  // Six variants in eight sizes: four text sizes and four icon sizes.
  assert list.length(classes) == 48
  assert list.length(list.unique(list.map(classes, class_of))) == 48
  assert button.button_class(button.Ghost)
    == button.sized_class(button.Ghost, button.Medium)
}

pub fn buttons_are_type_button_test() {
  let html =
    render(
      ui.sized_button(
        button.Ghost,
        button.Icon,
        [attribute.aria_label("Close")],
        [text("×")],
      ),
    )
  assert string.contains(html, "type=\"button\"")
  assert string.contains(html, "aria-label=\"Close\"")
}

pub fn text_controls_style_invalid_and_disabled_states_test() {
  let css = stylesheet.css_of(ui.classes())
  assert string.contains(css, "[aria-invalid=\"true\"] {")
  assert string.contains(css, "[aria-invalid=\"true\"]:focus-visible {")
  assert string.contains(css, ":disabled {")
}

pub fn select_wraps_the_native_element_test() {
  let html =
    render(
      ui.native_select([attribute.name("plan")], [
        html.option([attribute.value("free")], "Free"),
      ]),
    )
  assert string.starts_with(html, "<div class=")
  assert string.contains(html, "<select class=")
  assert string.contains(html, "name=\"plan\"")
  assert string.contains(html, "<option value=\"free\">Free</option>")
}

pub fn field_ties_text_to_its_control_test() {
  let html =
    render(
      ui.field([], [
        ui.label([attribute.for("email")], [text("Email")]),
        ui.input([
          attribute.id("email"),
          attribute.aria_invalid("true"),
          attribute.aria_describedby("email-error"),
        ]),
        ui.field_error([attribute.id("email-error")], [text("Required")]),
      ]),
    )
  assert string.contains(html, "aria-describedby=\"email-error\"")
  assert string.contains(html, "id=\"email-error\"")

  let html = render(ui.fieldset([], legend: [text("Plan")], children: []))
  assert string.contains(html, "<legend class=")
  assert string.contains(html, ">Plan</legend></fieldset>")
}

pub fn choices_wrap_native_controls_in_labels_test() {
  let html =
    render(
      ui.radio_group([attribute.aria_label("Plan")], [
        ui.choice(ui.radio([attribute.name("plan")]), [text("Free")]),
        ui.choice(ui.checkbox([attribute.name("terms")]), [text("Terms")]),
      ]),
    )
  assert string.contains(html, "role=\"radiogroup\"")
  assert string.contains(html, "type=\"radio\"")
  assert string.contains(html, "type=\"checkbox\"")
  assert string.contains(html, "<span>Free</span></label>")
}

pub fn card_parts_render_in_place_test() {
  let html =
    render(
      ui.card([], [
        ui.card_header([], [
          ui.card_title([text("Invoices")]),
          ui.card_description([text("Last 30 days")]),
          ui.card_action([], [text("Export")]),
        ]),
        ui.card_content([], [text("Body")]),
        ui.card_footer([], [text("Footer")]),
      ]),
    )
  assert string.contains(html, ">Invoices</div>")
  assert string.contains(html, ">Last 30 days</p>")
  assert string.contains(html, "<div>Body</div>")
}

pub fn separators_are_semantic_test() {
  assert string.starts_with(render(ui.separator(layout.Horizontal, [])), "<hr")
  let vertical = render(ui.separator(layout.Vertical, []))
  assert string.contains(vertical, "role=\"separator\"")
  assert string.contains(vertical, "aria-orientation=\"vertical\"")
}

pub fn badges_and_alerts_render_test() {
  assert string.starts_with(
    render(ui.badge(badge.Danger, [], [text("3")])),
    "<span class=",
  )
  let html =
    render(
      ui.alert(alert.Danger, [attribute.role("alert")], [
        ui.alert_title([text("Failed")]),
        ui.alert_description([text("Try again")]),
      ]),
    )
  assert string.contains(html, "role=\"alert\"")
  assert string.contains(html, ">Failed</div>")
}

pub fn table_scrolls_inside_a_wrapper_test() {
  let html =
    render(
      ui.table([attribute.id("orders")], [
        ui.table_caption([], [text("Orders")]),
        ui.table_header([], [
          ui.table_row([], [ui.table_head([], [text("Id")])]),
        ]),
        ui.table_body([], [ui.table_row([], [ui.table_cell([], [text("1")])])]),
      ]),
    )
  assert string.starts_with(html, "<div class=")
  assert string.contains(html, "<table class=")
  assert string.contains(html, "id=\"orders\"")
  assert string.contains(html, "<thead><tr class=")
  assert string.contains(html, ">1</td>")
}

pub fn loading_indicators_register_their_animation_test() {
  let #(spinner, css) =
    stylesheet.scoped(fn() { render(ui.spinner("Saving", [])) })
  assert string.contains(spinner, "role=\"status\"")
  assert string.contains(spinner, "aria-label=\"Saving\"")
  assert string.contains(css, "@keyframes howdy-spin")
  assert string.contains(css, "prefers-reduced-motion")

  let #(skeleton, css) = stylesheet.scoped(fn() { render(ui.skeleton([])) })
  assert string.contains(skeleton, "aria-hidden=\"true\"")
  assert string.contains(css, "@keyframes howdy-pulse")
}

pub fn every_copyable_entry_depends_only_on_what_it_may_test() {
  let css = stylesheet.css_of(ui.classes())
  assert css != ""
  use entry <- list.each(registry.entries())
  let assert Ok(source) = simplifile.read("src/" <> entry.module <> ".gleam")
  assert registry.description(source) != ""
  assert !string.contains(source, "import howdy/ui\n")
  let own_imports =
    source
    |> string.split("\n")
    |> list.filter(string.starts_with(_, "import howdy/ui/"))
  let core = fn(line) {
    string.starts_with(line, "import howdy/ui/style")
    || string.starts_with(line, "import howdy/ui/theme/tokens")
    || string.starts_with(line, "import howdy/ui/words")
  }
  case entry.kind {
    // Components use the core modules and, for a few, other components,
    // which `add` copies alongside.
    registry.Component -> {
      assert string.contains(source, "pub fn classes()")
      assert list.all(own_imports, fn(line) {
        core(line)
        || list.any(registry.entries(), fn(other) {
          other.kind == registry.Component
          && other.name != entry.name
          && string.starts_with(line, "import " <> other.module)
        })
      })
    }
    // Blocks may also use components, which `add` copies alongside.
    registry.Block -> {
      assert string.contains(source, "pub fn classes()")
      assert list.all(own_imports, fn(line) {
        core(line)
        || list.any(registry.entries(), fn(other) {
          other.kind == registry.Component
          && string.starts_with(line, "import " <> other.module)
        })
      })
    }
    registry.ThemePreset -> {
      assert list.all(own_imports, string.starts_with(
        _,
        "import howdy/ui/theme",
      ))
    }
  }
}
