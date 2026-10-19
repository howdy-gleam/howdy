import gleam/list
import gleam/string
import howdy/ui
import howdy/ui/button.{Outline}
import howdy/ui/button_group
import howdy/ui/resizable
import howdy/ui/toggle
import howdy/ui/words
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html

fn render(element: Element(msg)) -> String {
  element.to_string(element)
}

pub fn switches_are_checkboxes_with_the_switch_role_test() {
  let html = render(ui.switch([attribute.name("alerts")]))
  assert string.contains(html, "type=\"checkbox\"")
  assert string.contains(html, "role=\"switch\"")
  assert string.contains(render(ui.slider([])), "type=\"range\"")
}

pub fn one_time_codes_are_one_input_test() {
  let html = render(ui.input_otp(6, [attribute.name("code")]))
  assert string.contains(html, "autocomplete=\"one-time-code\"")
  assert string.contains(html, "inputmode=\"numeric\"")
  assert string.contains(html, "maxlength=\"6\"")
  assert string.contains(html, "--howdy-otp-length:6")
  assert list.length(string.split(html, "<input")) == 2
}

pub fn input_groups_are_labelled_groups_test() {
  let html =
    render(
      ui.input_group([], [
        ui.input_group_addon([text("https://")]),
        ui.input_group_input([attribute.aria_label("Website")]),
      ]),
    )
  assert string.contains(html, "role=\"group\"")
  assert string.contains(html, "aria-label=\"Website\"")
}

pub fn toggles_carry_their_pressed_state_test() {
  let html =
    render(
      ui.toggle_group(toggle.Single, [attribute.aria_label("Align")], [
        ui.toggle(True, [], [text("Left")]),
        ui.toggle(False, [], [text("Right")]),
      ]),
    )
  assert string.contains(html, "data-howdy-toggle-group=\"single\"")
  assert string.contains(html, "aria-pressed=\"true\"")
  assert string.contains(html, "aria-pressed=\"false\"")
  let group =
    render(
      ui.button_group(button_group.Vertical, [], [
        ui.button(Outline, [], [text("Up")]),
      ]),
    )
  assert string.contains(group, "role=\"group\"")
}

pub fn breadcrumbs_mark_the_current_page_test() {
  let html =
    render(
      ui.breadcrumb(words.english(), [], [
        ui.breadcrumb_link("/", [text("Home")]),
        ui.breadcrumb_ellipsis(),
        ui.breadcrumb_page([text("Order")]),
      ]),
    )
  assert string.contains(html, "aria-label=\"Breadcrumb\"")
  assert string.contains(html, "<ol")
  assert string.contains(html, "aria-current=\"page\"")
  assert string.contains(html, "aria-hidden=\"true\"")
}

pub fn carousels_announce_each_slide_test() {
  let html =
    render(
      ui.carousel(
        words.english(),
        "tour",
        label: "Tour",
        attributes: [],
        slides: [
          ui.carousel_slide([text("A")]),
          ui.carousel_slide([text("B")]),
        ],
      ),
    )
  assert string.contains(html, "aria-roledescription=\"carousel\"")
  assert string.contains(html, "aria-label=\"2 of 2\"")
  assert string.contains(html, "aria-controls=\"tour-slides\"")
  assert string.contains(html, "data-howdy-carousel-next")
}

pub fn resizable_handles_are_focusable_separators_test() {
  let html =
    render(
      ui.resizable_group(resizable.Vertical, [], [
        ui.resizable_panel(40, [], []),
        ui.resizable_handle("Resize"),
        ui.resizable_panel(60, [], []),
      ]),
    )
  assert string.contains(html, "data-howdy-resizable=\"vertical\"")
  assert string.contains(html, "flex-grow:40")
  assert string.contains(html, "role=\"separator\"")
  assert string.contains(html, "tabindex=\"0\"")
}

pub fn menus_in_other_shapes_reuse_menu_items_test() {
  let context =
    render(
      html.div([], [
        ui.context_menu_area("file", [], [text("File")]),
        ui.context_menu("file", [], [ui.menu_item([], [text("Rename")])]),
      ]),
    )
  assert string.contains(context, "data-howdy-context-menu=\"file\"")
  assert string.contains(context, "data-howdy-at-pointer")
  assert string.contains(context, "role=\"menuitem\"")

  let bar =
    render(ui.menubar([], [ui.menubar_button("file-menu", [text("File")])]))
  assert string.contains(bar, "role=\"menubar\"")
  assert string.contains(bar, "popovertarget=\"file-menu\"")
  assert string.contains(bar, "aria-haspopup=\"menu\"")
}

pub fn hover_cards_and_navigation_panels_are_popovers_test() {
  assert string.contains(
    render(html.a(ui.hover_card_trigger("card"), [])),
    "data-howdy-hover-card=\"card\"",
  )
  assert string.contains(
    render(ui.hover_card("card", [], [])),
    "popover=\"manual\"",
  )
  let nav =
    render(
      ui.navigation_menu([], [
        ui.navigation_link("/", active: True, children: [text("Home")]),
        ui.navigation_panel("more", label: [text("More")], links: [
          ui.navigation_panel_link("/a", title: "A", description: "The first"),
        ]),
      ]),
    )
  assert string.contains(nav, "aria-current=\"page\"")
  assert string.contains(nav, "popovertarget=\"more\"")
  assert string.contains(nav, "popover=\"auto\"")
}

pub fn items_empties_ratios_keys_and_scroll_areas_render_test() {
  assert string.contains(
    render(
      ui.item_link(
        "/p",
        media: element.none(),
        title: [text("Ada")],
        description: [],
      ),
    ),
    "href=\"/p\"",
  )
  assert string.contains(
    render(
      ui.empty(icon: text("!"), title: "None", description: "Yet", actions: []),
    ),
    ">None</div>",
  )
  assert string.contains(
    render(ui.aspect_ratio(16, 9, [], [])),
    "aspect-ratio:16 / 9",
  )
  assert string.contains(render(ui.shortcut(["⌘", "K"])), "<kbd")
  let area = render(ui.scroll_area("Notes", [], []))
  assert string.contains(area, "role=\"region\"")
  assert string.contains(area, "aria-label=\"Notes\"")
  assert string.contains(area, "tabindex=\"0\"")
}
