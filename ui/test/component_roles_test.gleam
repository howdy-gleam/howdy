//// One focused test per component that had none of its own: the primary
//// gallery example drawn through the module, checked for its landmark or
//// role, its ARIA state and the classes that style it.

import gleam/list
import gleam/string
import howdy/ui/aspect_ratio
import howdy/ui/blocks/app_shell.{Group, Link}
import howdy/ui/blocks/stat_card
import howdy/ui/breadcrumb
import howdy/ui/button.{Primary}
import howdy/ui/context_menu
import howdy/ui/empty
import howdy/ui/hover_card
import howdy/ui/input_group
import howdy/ui/internal/stylesheet
import howdy/ui/item
import howdy/ui/kbd
import howdy/ui/menu
import howdy/ui/menubar
import howdy/ui/navigation_menu
import howdy/ui/scroll_area
import howdy/ui/words
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}

fn render(element: Element(msg)) -> String {
  element.to_string(element)
}

/// The element carries the class, and the classes are what the module
/// exports for a published stylesheet.
fn uses(html: String, class: Class, exported: List(Class)) -> Bool {
  let name = stylesheet.class_name(class)
  string.contains(html, name)
  && list.any(exported, fn(c) { stylesheet.class_name(c) == name })
}

pub fn menubars_are_menubars_of_menu_items_test() {
  let html =
    render(
      html.div([], [
        menubar.menubar([], [
          menubar.menu_button("file-menu", [text("File")]),
          menubar.menu_button("edit-menu", [text("Edit")]),
        ]),
        menu.menu("file-menu", [], [menu.item([], [text("New")])]),
      ]),
    )
  assert string.contains(html, "role=\"menubar\"")
  assert string.contains(html, "data-howdy-menubar")
  assert list.length(string.split(html, "role=\"menuitem\"")) == 4
  assert string.contains(html, "type=\"button\"")
  assert string.contains(html, "popovertarget=\"file-menu\"")
  assert string.contains(html, "aria-haspopup=\"menu\"")
  assert uses(html, menubar.menubar_class(), menubar.classes())
  assert uses(html, menubar.button_class(), menubar.classes())
}

pub fn navigation_menus_are_navs_with_current_page_and_panels_test() {
  let html =
    render(
      navigation_menu.menu([attribute.aria_label("Main")], [
        navigation_menu.link("/", active: True, children: [text("Home")]),
        navigation_menu.link("/docs", active: False, children: [text("Docs")]),
        navigation_menu.panel("products", label: [text("Products")], links: [
          navigation_menu.panel_link(
            "/a",
            title: "Alpha",
            description: "The first",
          ),
        ]),
      ]),
    )
  assert string.starts_with(html, "<nav aria-label=\"Main\"")
  assert list.length(string.split(html, "aria-current=\"page\"")) == 2
  assert string.contains(html, "popovertarget=\"products\"")
  assert string.contains(html, "popover=\"auto\"")
  assert string.contains(html, "aria-hidden=\"true\"")
  assert string.contains(
    html,
    "data-howdy-anchored=\"--howdy-anchor-products\"",
  )
  assert uses(html, navigation_menu.list_class(), navigation_menu.classes())
  assert uses(html, navigation_menu.trigger_class(), navigation_menu.classes())
  assert uses(html, navigation_menu.panel_class(), navigation_menu.classes())
  assert uses(
    html,
    navigation_menu.panel_link_class(),
    navigation_menu.classes(),
  )
}

pub fn hover_cards_are_manual_popovers_anchored_to_their_link_test() {
  let html =
    render(
      html.div([], [
        html.a([attribute.href("/ada"), ..hover_card.trigger("ada-card")], [
          text("@ada"),
        ]),
        hover_card.card("ada-card", [], [text("Ada Lovelace")]),
      ]),
    )
  assert string.contains(html, "data-howdy-hover-card=\"ada-card\"")
  assert string.contains(html, "data-howdy-anchor=\"--howdy-anchor-ada-card\"")
  assert string.contains(html, "id=\"ada-card\"")
  assert string.contains(html, "popover=\"manual\"")
  assert string.contains(
    html,
    "data-howdy-anchored=\"--howdy-anchor-ada-card\"",
  )
  assert uses(html, hover_card.card_class(), hover_card.classes())
}

pub fn context_menus_are_menus_placed_at_the_pointer_test() {
  let html =
    render(
      html.div([], [
        context_menu.area("file", [], [text("Right-click me")]),
        context_menu.menu("file", [], [menu.item([], [text("Rename")])]),
      ]),
    )
  assert string.contains(html, "data-howdy-context-menu=\"file\"")
  assert string.contains(html, "id=\"file\"")
  assert string.contains(html, "role=\"menu\"")
  assert string.contains(html, "popover=\"auto\"")
  assert string.contains(html, "data-howdy-at-pointer")
  assert string.contains(html, "role=\"menuitem\"")
  // Styled by the menu it reuses, so it exports no classes of its own.
  assert context_menu.classes() == []
  assert string.contains(html, stylesheet.class_name(menu.menu_class()))
}

pub fn scroll_areas_are_focusable_labelled_regions_test() {
  let html = render(scroll_area.scroll_area("Notes", [], [text("...")]))
  assert string.contains(html, "role=\"region\"")
  assert string.contains(html, "aria-label=\"Notes\"")
  assert string.contains(html, "tabindex=\"0\"")
  assert uses(html, scroll_area.area_class(), scroll_area.classes())
}

pub fn aspect_ratios_set_the_ratio_and_clamp_the_height_test() {
  let html = render(aspect_ratio.aspect_ratio(16, 9, [], [html.img([])]))
  assert string.contains(html, "aspect-ratio:16 / 9")
  assert string.contains(html, "<img")
  assert uses(html, aspect_ratio.ratio_class(), aspect_ratio.classes())
  assert string.contains(
    render(aspect_ratio.aspect_ratio(1, 0, [], [])),
    "1 / 1",
  )
}

pub fn input_groups_are_groups_around_one_field_test() {
  let html =
    render(
      input_group.group([], [
        input_group.addon([text("https://")]),
        input_group.input([attribute.aria_label("Website")]),
        input_group.block_end([text("0 / 200")]),
      ]),
    )
  assert string.contains(html, "role=\"group\"")
  assert string.contains(html, "aria-label=\"Website\"")
  assert list.length(string.split(html, "<input")) == 2
  assert uses(html, input_group.group_class(), input_group.classes())
  assert uses(html, input_group.input_class(), input_group.classes())
  assert uses(html, input_group.addon_class(), input_group.classes())
  assert uses(html, input_group.block_end_class(), input_group.classes())
  let composer =
    render(input_group.group([], [input_group.textarea([], "Draft")]))
  assert string.contains(composer, ">Draft</textarea>")
  assert uses(composer, input_group.textarea_class(), input_group.classes())
}

pub fn breadcrumbs_are_a_labelled_nav_ending_at_the_current_page_test() {
  let html =
    render(
      breadcrumb.breadcrumb(words.english(), [], [
        breadcrumb.link("/", [text("Home")]),
        breadcrumb.ellipsis(),
        breadcrumb.link("/docs", [text("Docs")]),
        breadcrumb.page([text("Breadcrumb")]),
      ]),
    )
  assert string.starts_with(html, "<nav aria-label=\"Breadcrumb\"")
  assert string.contains(html, "<ol")
  assert list.length(string.split(html, "<li")) == 5
  assert string.contains(html, "aria-current=\"page\"")
  assert string.contains(html, "aria-hidden=\"true\"")
  assert uses(html, breadcrumb.list_class(), breadcrumb.classes())
  assert uses(html, breadcrumb.item_class(), breadcrumb.classes())
  assert uses(html, breadcrumb.link_class(), breadcrumb.classes())
  assert uses(html, breadcrumb.page_class(), breadcrumb.classes())
}

pub fn items_are_list_rows_with_optional_parts_test() {
  let html =
    render(
      item.group([
        item.item(
          media: html.span([], [text("A")]),
          title: [text("Ada")],
          description: [text("Engineer")],
          actions: [button.button(Primary, [], [text("Invite")])],
        ),
        item.link(
          "/grace",
          media: element.none(),
          title: [text("Grace")],
          description: [],
        ),
      ]),
    )
  assert string.contains(html, "<ul")
  assert list.length(string.split(html, "<li")) == 3
  assert string.contains(html, "href=\"/grace\"")
  assert list.length(string.split(html, "Engineer")) == 2
  assert uses(html, item.group_class(), item.classes())
  assert uses(html, item.item_class(), item.classes())
  assert uses(html, item.link_class(), item.classes())
  assert uses(html, item.title_class(), item.classes())
  assert uses(html, item.description_class(), item.classes())
  assert uses(html, item.actions_class(), item.classes())
  // A row with no description or actions leaves those parts out.
  let bare =
    render(
      item.item(
        media: element.none(),
        title: [text("Bare")],
        description: [],
        actions: [],
      ),
    )
  assert !string.contains(bare, stylesheet.class_name(item.description_class()))
  assert !string.contains(bare, stylesheet.class_name(item.actions_class()))
}

pub fn keys_are_kbd_elements_nested_for_shortcuts_test() {
  let html = render(kbd.shortcut(["Ctrl", "K"]))
  assert list.length(string.split(html, "<kbd")) == 4
  assert string.contains(html, ">Ctrl</kbd>")
  assert string.contains(html, ">K</kbd>")
  assert uses(html, kbd.shortcut_class(), kbd.classes())
  assert uses(html, kbd.key_class(), kbd.classes())
  assert string.starts_with(render(kbd.kbd("Esc")), "<kbd")
}

pub fn empty_states_hide_their_icon_from_screen_readers_test() {
  let html =
    render(
      empty.empty(
        icon: text("!"),
        title: "No projects yet",
        description: "Create one to get started.",
        actions: [button.button(Primary, [], [text("New project")])],
      ),
    )
  assert string.contains(html, "aria-hidden=\"true\"")
  assert string.contains(html, ">No projects yet</div>")
  assert string.contains(html, "<p")
  assert uses(html, empty.empty_class(), empty.classes())
  assert uses(html, empty.icon_class(), empty.classes())
  assert uses(html, empty.title_class(), empty.classes())
  assert uses(html, empty.description_class(), empty.classes())
  assert uses(html, empty.actions_class(), empty.classes())
  let quiet =
    render(
      empty.empty(icon: text("!"), title: "None", description: "", actions: []),
    )
  assert !string.contains(quiet, stylesheet.class_name(empty.actions_class()))
}

pub fn stat_cards_are_cards_with_label_value_and_change_test() {
  let html =
    render(stat_card.stat_card(
      label: "Revenue",
      value: "$12,400",
      change: "+8%",
    ))
  assert string.contains(html, ">Revenue</div>")
  assert string.contains(html, ">$12,400</div>")
  assert string.contains(html, ">+8%</div>")
  assert uses(html, stat_card.label_class(), stat_card.classes())
  assert uses(html, stat_card.value_class(), stat_card.classes())
  assert uses(html, stat_card.change_class(), stat_card.classes())
}

pub fn app_shells_have_a_main_navigation_a_toggle_and_a_heading_test() {
  let html =
    render(
      app_shell.app_shell(
        app: "Acme",
        collapsed: False,
        current: "/orders",
        navigation: [
          Group("Overview", [Link("/", "Dashboard"), Link("/orders", "Orders")]),
        ],
        footer: [text("Signed in")],
        heading: "Orders",
        actions: [button.button(Primary, [], [text("New order")])],
        content: [text("Table")],
      ),
    )
  assert string.contains(html, "aria-label=\"Main\"")
  assert string.contains(html, "id=\"app-navigation\"")
  assert string.contains(html, "aria-label=\"Toggle navigation\"")
  assert string.contains(html, "aria-controls=\"app-navigation\"")
  assert string.contains(html, "popovertarget=\"app-navigation\"")
  assert list.length(string.split(html, "aria-current=\"page\"")) == 2
  assert string.contains(html, "<h1")
  assert string.contains(html, ">Orders</h1>")
  assert string.contains(html, "Signed in")
  assert uses(html, app_shell.bar_class(), app_shell.classes())
  assert uses(html, app_shell.group_class(), app_shell.classes())
  assert uses(html, app_shell.heading_class(), app_shell.classes())
  assert uses(html, app_shell.content_class(), app_shell.classes())
}
