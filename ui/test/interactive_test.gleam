import gleam/list
import gleam/string
import howdy/ui
import howdy/ui/dialog
import howdy/ui/page
import howdy/ui/select
import howdy/ui/style
import lustre/element.{type Element, text}
import lustre/element/html

fn render(element: Element(msg)) -> String {
  element.to_string(element)
}

/// Render a list of attributes on an element, to inspect them.
fn attributes(attributes) -> String {
  render(html.span(attributes, []))
}

pub fn every_page_carries_the_behaviour_script_test() {
  let html = page.new("Plain") |> page.to_string
  assert string.contains(html, "window.howdyBehaviour")
}

pub fn anchor_names_are_valid_identifiers_test() {
  assert style.anchor_name("filters") == "--howdy-anchor-filters"
  assert style.anchor_name("a.b c:1") == "--howdy-anchor-a_b_c_1"
}

pub fn dialogs_open_by_command_and_name_themselves_test() {
  let trigger = attributes(ui.dialog_trigger("rename"))
  assert string.contains(trigger, "commandfor=\"rename\"")
  assert string.contains(trigger, "command=\"show-modal\"")
  assert string.contains(
    attributes(ui.dialog_close("rename")),
    "command=\"close\"",
  )

  let html =
    render(
      ui.dialog("rename", [], [
        ui.dialog_title("rename", [text("Rename")]),
        ui.dialog_description("rename", [text("Pick a name")]),
      ]),
    )
  assert string.starts_with(html, "<dialog")
  assert string.contains(html, "closedby=\"any\"")
  assert string.contains(html, "aria-labelledby=\"rename-title\"")
  assert string.contains(html, "id=\"rename-title\"")
  assert string.contains(html, "aria-describedby=\"rename-description\"")

  let html = render(ui.alert_dialog("confirm", [], []))
  assert string.contains(html, "role=\"alertdialog\"")
  assert string.contains(html, "closedby=\"closerequest\"")

  assert string.starts_with(
    render(ui.sheet("nav", dialog.Left, [], [])),
    "<dialog",
  )
}

pub fn floating_elements_share_an_anchor_with_their_trigger_test() {
  let anchor = style.anchor_name("filters")
  let trigger = attributes(ui.popover_trigger("filters"))
  assert string.contains(trigger, "popovertarget=\"filters\"")
  assert string.contains(trigger, "data-howdy-anchor=\"" <> anchor <> "\"")
  let html = render(ui.popover("filters", [], []))
  assert string.contains(html, "popover=\"auto\"")
  assert string.contains(html, "data-howdy-anchored=\"" <> anchor <> "\"")

  let trigger = attributes(ui.tooltip_trigger("tip"))
  assert string.contains(trigger, "data-howdy-tooltip=\"tip\"")
  assert string.contains(trigger, "aria-describedby=\"tip\"")
  let html = render(ui.tooltip("tip", [text("Hint")]))
  assert string.contains(html, "popover=\"manual\"")
  assert string.contains(html, "role=\"tooltip\"")

  let trigger = attributes(ui.menu_trigger("account"))
  assert string.contains(trigger, "aria-haspopup=\"menu\"")
  assert string.contains(trigger, "data-howdy-menu-trigger")
}

pub fn menu_items_have_roles_and_state_test() {
  let html =
    render(
      ui.menu("account", [], [
        ui.menu_item([], [text("Profile")]),
        ui.menu_link("/out", [], [text("Sign out")]),
        ui.menu_checkbox_item(True, [], [text("Compact")]),
        ui.menu_separator(),
      ]),
    )
  assert string.contains(html, "role=\"menu\"")
  assert string.contains(html, "role=\"menuitem\"")
  assert string.contains(html, "href=\"/out\"")
  assert string.contains(html, "role=\"menuitemcheckbox\"")
  assert string.contains(html, "aria-checked=\"true\"")
  assert string.contains(html, "role=\"separator\"")
}

pub fn tabs_show_only_the_selected_panel_test() {
  let html =
    render(
      ui.tabs("account", selected: "b", attributes: [], tabs: [
        ui.tab("a", [], label: [text("A")], panel: [text("Panel A")]),
        ui.tab("b", [], label: [text("B")], panel: [text("Panel B")]),
      ]),
    )
  assert string.contains(html, "data-howdy-tabs")
  assert string.contains(html, "role=\"tablist\"")
  // Each tab controls its panel and each panel is named by its tab.
  assert string.contains(html, "aria-controls=\"account-panel-a\"")
  assert string.contains(html, "aria-labelledby=\"account-tab-b\"")
  // Lustre sorts attributes, so `hidden` comes just before the `id`.
  assert string.contains(html, "hidden id=\"account-panel-a\"")
  assert !string.contains(html, "hidden id=\"account-panel-b\"")
  // The selected tab is the one in the tab order.
  assert string.contains(
    html,
    "aria-controls=\"account-panel-b\" aria-selected=\"true\"",
  )
  assert string.contains(
    html,
    "id=\"account-tab-b\" role=\"tab\" tabindex=\"0\"",
  )
  assert string.contains(
    html,
    "id=\"account-tab-a\" role=\"tab\" tabindex=\"-1\"",
  )
}

pub fn accordion_items_in_a_group_share_a_name_test() {
  let html =
    render(
      ui.accordion([], [
        ui.accordion_item("faq", open: True, summary: [text("Q1")], content: []),
        ui.accordion_item(
          "faq",
          open: False,
          summary: [text("Q2")],
          content: [],
        ),
      ]),
    )
  assert list.length(string.split(html, "name=\"faq\"")) == 3
  assert string.contains(html, "<details")
  assert string.contains(html, "open")

  let html =
    render(ui.accordion_item("", open: False, summary: [], content: []))
  assert !string.contains(html, "name=")
}

pub fn select_shows_the_chosen_option_or_placeholder_test() {
  let items = [
    ui.select_item("free", "Free"),
    select.disabled_item("ent", "Enterprise"),
    ui.select_group("Legacy", [ui.select_item("basic", "Basic")]),
  ]
  let html =
    render(ui.select(
      id: "plan",
      name: "plan",
      value: "basic",
      placeholder: "Choose",
      attributes: [],
      items:,
    ))
  assert string.contains(html, "type=\"hidden\"")
  assert string.contains(html, "name=\"plan\"")
  assert string.contains(html, "value=\"basic\"")
  assert string.contains(html, "data-howdy-select-value>Basic</span>")
  assert !string.contains(html, "data-placeholder")
  assert string.contains(html, "popovertarget=\"plan-listbox\"")
  assert string.contains(html, "role=\"listbox\"")
  assert string.contains(html, "aria-disabled=\"true\"")
  assert string.contains(html, "role=\"group\"")

  let html =
    render(ui.select(
      id: "plan",
      name: "plan",
      value: "",
      placeholder: "Choose",
      attributes: [],
      items:,
    ))
  assert string.contains(html, ">Choose</span>")
  assert string.contains(html, "data-placeholder")
}
