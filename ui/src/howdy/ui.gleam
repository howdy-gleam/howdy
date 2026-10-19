//// Ready-made elements that follow the theme.
////
//// Every element here is a Sketch class built from `howdy/ui/theme/tokens`,
//// so it looks right under any theme in `howdy/ui/theme`. Use them in pages
//// and in live views alike:
////
//// ```gleam
//// import howdy/ui
//// import howdy/ui/button.{Primary, Secondary}
//// import lustre/element.{text}
//// import lustre/event
////
//// ui.card([], [
////   ui.h2("Counter"),
////   ui.row([], [
////     ui.button(Secondary, [event.on_click(Decrement)], [text("-")]),
////     ui.button(Primary, [event.on_click(Increment)], [text("+")]),
////   ]),
//// ])
//// ```
////
//// Each component lives in its own module under `howdy/ui`, and this
//// module re-exports them. To make one your own, copy it into your project:
////
//// ```sh
//// gleam run -m howdy/ui add button
//// ```
////
//// That writes `src/<app>/ui/button.gleam`, the same source as the
//// built-in, for you to edit. `gleam run -m howdy/ui list` shows what is
//// available and `gleam run -m howdy/ui diff button` compares your copy
//// with the version this package ships.
////
//// To add a component from scratch, keep the classes in a styles module,
//// build each from tokens, and attach it with `class`:
////
//// ```gleam
//// // src/my_styles.gleam
//// pub fn badge() -> css.Class {
////   css.class([css.background(tokens.primary), css.color(tokens.on_primary)])
//// }
////
//// pub fn classes() -> List(css.Class) {
////   [badge()]
//// }
//// ```
////
//// ```gleam
//// html.span([ui.class(my_styles.badge())], [text(content)])
//// ```
////
//// The `classes` list is what `howdy/ui/export` uses to write the CSS file
//// for a published site.
////
//// ## Where the CSS goes
////
//// Pages embed the CSS they need by default. In development, mount
//// `stylesheet` and link it with `page.stylesheet` to serve it as one file
//// instead:
////
//// ```gleam
//// howdy.new()
//// |> howdy.controller(pages())
//// |> howdy.controller(ui.stylesheet(at: "/assets/ui.css", themes: theme.default_themes()))
//// ```
////
//// To publish, write a static file with `howdy/ui/export` and serve it
//// with `howdy/static`. Live components carry the CSS for their own
//// classes either way, so they are always styled.

import argv
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option
import howdy/controller.{type Controller}
import howdy/ui/accordion
import howdy/ui/alert
import howdy/ui/aspect_ratio
import howdy/ui/attachment
import howdy/ui/avatar
import howdy/ui/badge
import howdy/ui/bell
import howdy/ui/blocks/app_shell
import howdy/ui/blocks/sign_in
import howdy/ui/blocks/sign_up
import howdy/ui/blocks/stat_card
import howdy/ui/breadcrumb
import howdy/ui/button
import howdy/ui/button_group
import howdy/ui/calendar
import howdy/ui/card
import howdy/ui/carousel
import howdy/ui/chart
import howdy/ui/chat
import howdy/ui/checkbox
import howdy/ui/cli
import howdy/ui/command
import howdy/ui/context_menu
import howdy/ui/data_table
import howdy/ui/dialog
import howdy/ui/direction
import howdy/ui/drawer
import howdy/ui/effects
import howdy/ui/empty
import howdy/ui/field
import howdy/ui/heading
import howdy/ui/hover_card
import howdy/ui/input
import howdy/ui/input_group
import howdy/ui/input_otp
import howdy/ui/internal/stylesheet
import howdy/ui/item
import howdy/ui/kbd
import howdy/ui/layout
import howdy/ui/loading
import howdy/ui/menu
import howdy/ui/menubar
import howdy/ui/navigation_menu
import howdy/ui/pagination
import howdy/ui/popover
import howdy/ui/progress
import howdy/ui/questionnaire
import howdy/ui/resizable
import howdy/ui/scroll_area
import howdy/ui/select
import howdy/ui/sidebar
import howdy/ui/slider
import howdy/ui/style
import howdy/ui/switch
import howdy/ui/table
import howdy/ui/tabs
import howdy/ui/theme.{type Themes}
import howdy/ui/toast
import howdy/ui/toggle
import howdy/ui/tooltip
import howdy/ui/typography
import howdy/ui/uploader
import howdy/ui/words.{type Words}
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import sketch/css.{type Class}

/// The command line: `gleam run -m howdy/ui list|search|view|add|diff|init|registry`.
pub fn main() -> Nil {
  cli.run(argv.load().arguments)
}

/// Register a Sketch class and use it on an element. The CSS is included
/// by `howdy/ui/page` and `howdy/ui/live`, or by `styles`.
pub fn class(class: Class) -> Attribute(msg) {
  style.class(class)
}

/// A `<style>` element holding the CSS for every class used so far. Build
/// it after the elements it styles. Pages and live views include this for
/// you.
pub fn styles() -> Element(msg) {
  style.styles()
}

/// Every class the built-in components use. `howdy/ui/export` includes
/// these in the file it writes.
pub fn classes() -> List(Class) {
  list.flatten([
    heading.classes(),
    typography.classes(),
    button.classes(),
    input.classes(),
    field.classes(),
    checkbox.classes(),
    layout.classes(),
    card.classes(),
    badge.classes(),
    alert.classes(),
    table.classes(),
    loading.classes(),
    dialog.classes(),
    popover.classes(),
    tooltip.classes(),
    menu.classes(),
    tabs.classes(),
    accordion.classes(),
    select.classes(),
    toast.classes(),
    bell.classes(),
    sidebar.classes(),
    pagination.classes(),
    calendar.classes(),
    command.classes(),
    data_table.classes(),
    chart.classes(),
    avatar.classes(),
    progress.classes(),
    effects.classes(),
    chat.classes(),
    attachment.classes(),
    uploader.classes(),
    app_shell.classes(),
    stat_card.classes(),
    sign_in.classes(),
    sign_up.classes(),
    aspect_ratio.classes(),
    breadcrumb.classes(),
    button_group.classes(),
    carousel.classes(),
    context_menu.classes(),
    empty.classes(),
    hover_card.classes(),
    input_group.classes(),
    input_otp.classes(),
    item.classes(),
    kbd.classes(),
    menubar.classes(),
    navigation_menu.classes(),
    resizable.classes(),
    scroll_area.classes(),
    slider.classes(),
    switch.classes(),
    toggle.classes(),
    direction.classes(),
    drawer.classes(),
    questionnaire.classes(),
  ])
}

/// The CSS the built-in components register with `style.rule`, such as
/// their `@keyframes`. `howdy/ui/export` includes these in the file it
/// writes.
pub fn rules() -> List(#(String, String)) {
  list.flatten([
    loading.rules(),
    progress.rules(),
    effects.rules(),
    toast.rules(),
    drawer.rules(),
  ])
}

/// A controller for development that serves the theme variables, base
/// styles and every class registered so far as one `text/css` file at
/// `path`. Link it with `page.stylesheet`. It is sent with an ETag and
/// `cache-control: no-cache`, so browsers revalidate on each page load and
/// see new classes as soon as they exist.
///
/// For a published site, write a static file with `howdy/ui/export` and
/// serve it with `howdy/static` instead.
pub fn stylesheet(at path: String, themes themes: Themes) -> Controller {
  controller.new(path)
  |> controller.get("/", fn(ctx) {
    let css = stylesheet.document_css(themes)
    let etag = stylesheet.etag(css)
    case request.get_header(ctx.request, "if-none-match") == Ok(etag) {
      True -> controller.status(ctx, 304)
      False ->
        controller.text(ctx, css)
        |> response.set_header("content-type", "text/css; charset=utf-8")
    }
    |> response.set_header("cache-control", "no-cache")
    |> response.set_header("etag", etag)
  })
}

// -- Components --------------------------------------------------------------
//
// Thin wrappers so labels and docs survive; each lives in its own module.

/// See `howdy/ui/heading`.
pub fn h1(content: String) -> Element(msg) {
  heading.h1(content)
}

pub fn h2(content: String) -> Element(msg) {
  heading.h2(content)
}

pub fn h3(content: String) -> Element(msg) {
  heading.h3(content)
}

pub fn h4(content: String) -> Element(msg) {
  heading.h4(content)
}

/// See `howdy/ui/typography`.
pub fn p(children: List(Element(msg))) -> Element(msg) {
  typography.p(children)
}

pub fn muted(content: String) -> Element(msg) {
  typography.muted(content)
}

pub fn link(href: String, children: List(Element(msg))) -> Element(msg) {
  typography.link(href, children)
}

/// Styles the plain elements inside it, such as rendered Markdown.
pub fn prose(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  typography.prose(attributes, children)
}

/// See `howdy/ui/direction`.
pub fn direction(
  direction: direction.Direction,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  direction.provider(direction, attributes, children)
}

/// See `howdy/ui/button`. Variants are `button.Primary`, `Secondary`,
/// `Outline`, `Ghost`, `Link` and `Danger`.
pub fn button(
  variant: button.Variant,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  button.button(variant, attributes, children)
}

/// A button of a given size: `button.Small`, `Medium`, `Large` or `Icon`.
pub fn sized_button(
  variant: button.Variant,
  size: button.Size,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  button.sized(variant, size, attributes, children)
}

/// A button that submits its form.
pub fn submit_button(
  variant: button.Variant,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  button.submit(variant, attributes, children)
}

pub fn theme_toggle(
  children: List(Element(msg)),
  from a: String,
  to b: String,
) -> Element(msg) {
  button.theme_toggle(children, from: a, to: b)
}

/// See `howdy/ui/input`.
pub fn input(attributes: List(Attribute(msg))) -> Element(msg) {
  input.input(attributes)
}

pub fn textarea(
  attributes: List(Attribute(msg)),
  content: String,
) -> Element(msg) {
  input.textarea(attributes, content)
}

pub fn native_select(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  input.native_select(attributes, children)
}

pub fn label(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  input.label(attributes, children)
}

/// See `howdy/ui/field`.
pub fn field(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  field.field(attributes, children)
}

pub fn field_description(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  field.description(attributes, children)
}

pub fn field_error(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  field.error(attributes, children)
}

pub fn fieldset(
  attributes: List(Attribute(msg)),
  legend legend: List(Element(msg)),
  children children: List(Element(msg)),
) -> Element(msg) {
  field.fieldset(attributes, legend:, children:)
}

/// See `howdy/ui/checkbox`.
pub fn checkbox(attributes: List(Attribute(msg))) -> Element(msg) {
  checkbox.checkbox(attributes)
}

pub fn radio(attributes: List(Attribute(msg))) -> Element(msg) {
  checkbox.radio(attributes)
}

pub fn choice(
  control: Element(msg),
  children: List(Element(msg)),
) -> Element(msg) {
  checkbox.choice(control, children)
}

pub fn radio_group(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  checkbox.radio_group(attributes, children)
}

/// See `howdy/ui/layout`.
pub fn container(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  layout.container(attributes, children)
}

pub fn stack(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  layout.stack(attributes, children)
}

pub fn row(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  layout.row(attributes, children)
}

pub fn separator(
  orientation: layout.Orientation,
  attributes: List(Attribute(msg)),
) -> Element(msg) {
  layout.separator(orientation, attributes)
}

/// See `howdy/ui/card`.
pub fn card(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  card.card(attributes, children)
}

pub fn card_header(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  card.header(attributes, children)
}

pub fn card_title(children: List(Element(msg))) -> Element(msg) {
  card.title(children)
}

pub fn card_description(children: List(Element(msg))) -> Element(msg) {
  card.description(children)
}

pub fn card_action(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  card.action(attributes, children)
}

pub fn card_content(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  card.content(attributes, children)
}

pub fn card_footer(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  card.footer(attributes, children)
}

/// See `howdy/ui/badge`.
pub fn badge(
  variant: badge.Variant,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  badge.badge(variant, attributes, children)
}

/// See `howdy/ui/alert`.
pub fn alert(
  variant: alert.Variant,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  alert.alert(variant, attributes, children)
}

pub fn alert_title(children: List(Element(msg))) -> Element(msg) {
  alert.title(children)
}

pub fn alert_description(children: List(Element(msg))) -> Element(msg) {
  alert.description(children)
}

/// See `howdy/ui/table`.
pub fn table(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  table.table(attributes, children)
}

pub fn table_caption(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  table.caption(attributes, children)
}

pub fn table_header(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  table.header(attributes, children)
}

pub fn table_body(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  table.body(attributes, children)
}

pub fn table_footer(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  table.footer(attributes, children)
}

pub fn table_row(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  table.row(attributes, children)
}

pub fn table_head(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  table.head(attributes, children)
}

pub fn table_cell(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  table.cell(attributes, children)
}

/// See `howdy/ui/loading`.
pub fn skeleton(attributes: List(Attribute(msg))) -> Element(msg) {
  loading.skeleton(attributes)
}

pub fn spinner(
  label: String,
  attributes: List(Attribute(msg)),
) -> Element(msg) {
  loading.spinner(label, attributes)
}

/// See `howdy/ui/dialog`.
pub fn dialog(
  id: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  dialog.dialog(id, attributes, children)
}

pub fn alert_dialog(
  id: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  dialog.alert_dialog(id, attributes, children)
}

pub fn sheet(
  id: String,
  side: dialog.Side,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  dialog.sheet(id, side, attributes, children)
}

pub fn dialog_trigger(id: String) -> List(Attribute(msg)) {
  dialog.trigger(id)
}

pub fn dialog_close(id: String) -> List(Attribute(msg)) {
  dialog.close(id)
}

pub fn dialog_header(children: List(Element(msg))) -> Element(msg) {
  dialog.header(children)
}

pub fn dialog_title(id: String, children: List(Element(msg))) -> Element(msg) {
  dialog.title(id, children)
}

pub fn dialog_description(
  id: String,
  children: List(Element(msg)),
) -> Element(msg) {
  dialog.description(id, children)
}

pub fn dialog_footer(children: List(Element(msg))) -> Element(msg) {
  dialog.footer(children)
}

/// See `howdy/ui/drawer`. Its header, title, description and footer are
/// the dialog's.
pub fn drawer(
  words: Words,
  id: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  drawer.drawer(words, id, attributes, children)
}

pub fn drawer_trigger(id: String) -> List(Attribute(msg)) {
  drawer.trigger(id)
}

/// See `howdy/ui/popover`.
pub fn popover(
  id: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  popover.popover(id, attributes, children)
}

pub fn popover_trigger(id: String) -> List(Attribute(msg)) {
  popover.trigger(id)
}

pub fn popover_close(id: String) -> List(Attribute(msg)) {
  popover.close(id)
}

/// See `howdy/ui/tooltip`.
pub fn tooltip(id: String, children: List(Element(msg))) -> Element(msg) {
  tooltip.tooltip(id, children)
}

pub fn tooltip_trigger(id: String) -> List(Attribute(msg)) {
  tooltip.trigger(id)
}

/// See `howdy/ui/menu`.
pub fn menu(
  id: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  menu.menu(id, attributes, children)
}

pub fn menu_trigger(id: String) -> List(Attribute(msg)) {
  menu.trigger(id)
}

pub fn menu_item(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  menu.item(attributes, children)
}

pub fn menu_link(
  href: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  menu.link(href, attributes, children)
}

pub fn menu_checkbox_item(
  checked: Bool,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  menu.checkbox_item(checked, attributes, children)
}

pub fn menu_label(children: List(Element(msg))) -> Element(msg) {
  menu.label(children)
}

pub fn menu_separator() -> Element(msg) {
  menu.separator()
}

pub fn menu_radio_group(
  label: String,
  items: List(Element(msg)),
) -> Element(msg) {
  menu.radio_group(label, items)
}

pub fn menu_radio_item(
  checked: Bool,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  menu.radio_item(checked, attributes, children)
}

pub fn menu_submenu(
  id: String,
  label label: List(Element(msg)),
  items items: List(Element(msg)),
) -> Element(msg) {
  menu.submenu(id, label:, items:)
}

/// See `howdy/ui/tabs`.
pub fn tabs(
  id: String,
  selected selected: String,
  attributes attributes: List(Attribute(msg)),
  tabs items: List(tabs.Tab(msg)),
) -> Element(msg) {
  tabs.tabs(id, selected:, attributes:, tabs: items)
}

pub fn tab(
  value: String,
  attributes: List(Attribute(msg)),
  label label: List(Element(msg)),
  panel panel: List(Element(msg)),
) -> tabs.Tab(msg) {
  tabs.tab(value, attributes, label:, panel:)
}

/// See `howdy/ui/accordion`.
pub fn accordion(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  accordion.accordion(attributes, children)
}

pub fn accordion_item(
  group: String,
  open open: Bool,
  summary summary: List(Element(msg)),
  content content: List(Element(msg)),
) -> Element(msg) {
  accordion.item(group, open:, summary:, content:)
}

pub fn collapsible(
  attributes: List(Attribute(msg)),
  open open: Bool,
  summary summary: List(Element(msg)),
  content content: List(Element(msg)),
) -> Element(msg) {
  accordion.collapsible(attributes, open:, summary:, content:)
}

/// See `howdy/ui/select`. For the browser's own select, see
/// `native_select`.
pub fn select(
  id id: String,
  name name: String,
  value value: String,
  placeholder placeholder: String,
  attributes attributes: List(Attribute(msg)),
  items items: List(select.Item),
) -> Element(msg) {
  select.select(id:, name:, value:, placeholder:, attributes:, items:)
}

pub fn select_item(value: String, label: String) -> select.Item {
  select.item(value, label)
}

pub fn select_group(label: String, items: List(select.Item)) -> select.Item {
  select.group(label, items)
}

/// See `howdy/ui/toast`.
pub fn toast_region(
  words: Words,
  attributes: List(Attribute(msg)),
  toasts: List(Element(msg)),
) -> Element(msg) {
  toast.region(words, attributes, toasts)
}

pub fn toast(
  variant: toast.Variant,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  toast.toast(variant, attributes, children)
}

pub fn toast_title(children: List(Element(msg))) -> Element(msg) {
  toast.title(children)
}

pub fn toast_description(children: List(Element(msg))) -> Element(msg) {
  toast.description(children)
}

pub fn toast_close(attributes: List(Attribute(msg))) -> Element(msg) {
  toast.close(attributes)
}

/// See `howdy/ui/sidebar`.
pub fn sidebar_layout(
  collapsed collapsed: Bool,
  attributes attributes: List(Attribute(msg)),
  sidebar sidebar_element: Element(msg),
  main main: List(Element(msg)),
) -> Element(msg) {
  sidebar.layout(collapsed:, attributes:, sidebar: sidebar_element, main:)
}

pub fn sidebar(
  id: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  sidebar.sidebar(id, attributes, children)
}

pub fn sidebar_trigger(id: String) -> List(Attribute(msg)) {
  sidebar.trigger(id)
}

pub fn sidebar_header(children: List(Element(msg))) -> Element(msg) {
  sidebar.header(children)
}

pub fn sidebar_content(children: List(Element(msg))) -> Element(msg) {
  sidebar.content(children)
}

pub fn sidebar_footer(children: List(Element(msg))) -> Element(msg) {
  sidebar.footer(children)
}

pub fn sidebar_group(label: String, items: List(Element(msg))) -> Element(msg) {
  sidebar.group(label, items)
}

pub fn sidebar_link(
  href: String,
  active active: Bool,
  attributes attributes: List(Attribute(msg)),
  children children: List(Element(msg)),
) -> Element(msg) {
  sidebar.link(href, active:, attributes:, children:)
}

pub fn sidebar_button(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  sidebar.button(attributes, children)
}

/// See `howdy/ui/pagination`.
pub fn pagination(
  words words: Words,
  current current: Int,
  total total: Int,
  href href: fn(Int) -> String,
) -> Element(msg) {
  pagination.pagination(words:, current:, total:, href:)
}

/// See `howdy/ui/command`.
pub fn command(
  id: String,
  placeholder placeholder: String,
  attributes attributes: List(Attribute(msg)),
  children children: List(Element(msg)),
) -> Element(msg) {
  command.command(id, placeholder:, attributes:, children:)
}

pub fn command_group(
  heading: String,
  items: List(Element(msg)),
) -> Element(msg) {
  command.group(heading, items)
}

pub fn command_item(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  command.item(attributes, children)
}

pub fn command_link(
  href: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  command.link(href, attributes, children)
}

pub fn command_empty(children: List(Element(msg))) -> Element(msg) {
  command.empty(children)
}

pub fn command_dialog(
  words: Words,
  id: String,
  shortcut shortcut: String,
  attributes attributes: List(Attribute(msg)),
  command command_element: Element(msg),
) -> Element(msg) {
  command.dialog(words, id, shortcut:, attributes:, command: command_element)
}

pub fn combobox(
  words words: Words,
  id id: String,
  name name: String,
  value value: String,
  label label: String,
  placeholder placeholder: String,
  search search: String,
  attributes attributes: List(Attribute(msg)),
  options options: List(Element(msg)),
) -> Element(msg) {
  command.combobox(
    words:,
    id:,
    name:,
    value:,
    label:,
    placeholder:,
    search:,
    attributes:,
    options:,
  )
}

pub fn multiple_combobox(
  words words: Words,
  id id: String,
  name name: String,
  values values: List(String),
  placeholder placeholder: String,
  search search: String,
  attributes attributes: List(Attribute(msg)),
  options options: List(#(String, String)),
) -> Element(msg) {
  command.multiple_combobox(
    words:,
    id:,
    name:,
    values:,
    placeholder:,
    search:,
    attributes:,
    options:,
  )
}

pub fn combobox_option(
  value: String,
  selected selected: Bool,
  children children: List(Element(msg)),
) -> Element(msg) {
  command.option(value, selected:, children:)
}

/// See `howdy/ui/avatar`.
pub fn avatar(
  src src: String,
  alt alt: String,
  initials initials: String,
) -> Element(msg) {
  avatar.avatar(src:, alt:, initials:)
}

pub fn avatar_initials(initials: String) -> Element(msg) {
  avatar.initials(initials)
}

/// See `howdy/ui/progress`.
pub fn progress(
  label label: String,
  value value: Int,
  max max: Int,
) -> Element(msg) {
  progress.progress(label:, value:, max:)
}

pub fn progress_indeterminate(label label: String) -> Element(msg) {
  progress.indeterminate(label:)
}

/// See `howdy/ui/effects`.
pub fn scroll_fade() -> Attribute(msg) {
  effects.scroll_fade()
}

pub fn shimmer(children: List(Element(msg))) -> Element(msg) {
  effects.shimmer(children)
}

/// See `howdy/ui/chat`.
pub fn chat_conversation(
  words: Words,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  chat.conversation(words, attributes, children)
}

pub fn chat_message(
  side: chat.Side,
  attributes attributes: List(Attribute(msg)),
  avatar avatar_element: Element(msg),
  header header: List(Element(msg)),
  content content: List(Element(msg)),
  footer footer: List(Element(msg)),
) -> Element(msg) {
  chat.message(
    side,
    attributes:,
    avatar: avatar_element,
    header:,
    content:,
    footer:,
  )
}

pub fn chat_bubble(
  side: chat.Side,
  children: List(Element(msg)),
) -> Element(msg) {
  chat.bubble(side, children)
}

pub fn chat_note(children: List(Element(msg))) -> Element(msg) {
  chat.note(children)
}

/// See `howdy/ui/attachment`.
pub fn attachment(
  words words: attachment.Words,
  name name: String,
  detail detail: String,
  status status: attachment.Status,
  media media: option.Option(Element(msg)),
  actions actions: List(Element(msg)),
) -> Element(msg) {
  attachment.attachment(words:, name:, detail:, status:, media:, actions:)
}

pub fn attachment_group(attachments: List(Element(msg))) -> Element(msg) {
  attachment.group(attachments)
}

/// See `howdy/ui/switch`.
pub fn switch(attributes: List(Attribute(msg))) -> Element(msg) {
  switch.switch(attributes)
}

/// See `howdy/ui/slider`.
pub fn slider(attributes: List(Attribute(msg))) -> Element(msg) {
  slider.slider(attributes)
}

/// See `howdy/ui/input_otp`.
pub fn input_otp(
  length: Int,
  attributes: List(Attribute(msg)),
) -> Element(msg) {
  input_otp.input_otp(length, attributes)
}

/// See `howdy/ui/input_group`.
pub fn input_group(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  input_group.group(attributes, children)
}

pub fn input_group_input(attributes: List(Attribute(msg))) -> Element(msg) {
  input_group.input(attributes)
}

pub fn input_group_addon(children: List(Element(msg))) -> Element(msg) {
  input_group.addon(children)
}

/// See `howdy/ui/kbd`.
pub fn kbd(key: String) -> Element(msg) {
  kbd.kbd(key)
}

pub fn shortcut(keys: List(String)) -> Element(msg) {
  kbd.shortcut(keys)
}

/// See `howdy/ui/toggle`.
pub fn toggle(
  pressed: Bool,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  toggle.toggle(pressed, attributes, children)
}

pub fn toggle_group(
  selection: toggle.Selection,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  toggle.group(selection, attributes, children)
}

/// See `howdy/ui/button_group`.
pub fn button_group(
  orientation: button_group.Orientation,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  button_group.group(orientation, attributes, children)
}

/// See `howdy/ui/breadcrumb`.
pub fn breadcrumb(
  words: Words,
  attributes: List(Attribute(msg)),
  items: List(Element(msg)),
) -> Element(msg) {
  breadcrumb.breadcrumb(words, attributes, items)
}

pub fn breadcrumb_link(
  href: String,
  children: List(Element(msg)),
) -> Element(msg) {
  breadcrumb.link(href, children)
}

pub fn breadcrumb_page(children: List(Element(msg))) -> Element(msg) {
  breadcrumb.page(children)
}

pub fn breadcrumb_ellipsis() -> Element(msg) {
  breadcrumb.ellipsis()
}

/// See `howdy/ui/empty`.
pub fn empty(
  icon icon: Element(msg),
  title title: String,
  description description: String,
  actions actions: List(Element(msg)),
) -> Element(msg) {
  empty.empty(icon:, title:, description:, actions:)
}

/// See `howdy/ui/item`.
pub fn item_group(items: List(Element(msg))) -> Element(msg) {
  item.group(items)
}

pub fn item(
  media media: Element(msg),
  title title: List(Element(msg)),
  description description: List(Element(msg)),
  actions actions: List(Element(msg)),
) -> Element(msg) {
  item.item(media:, title:, description:, actions:)
}

pub fn item_link(
  href: String,
  media media: Element(msg),
  title title: List(Element(msg)),
  description description: List(Element(msg)),
) -> Element(msg) {
  item.link(href, media:, title:, description:)
}

/// See `howdy/ui/aspect_ratio`.
pub fn aspect_ratio(
  width: Int,
  height: Int,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  aspect_ratio.aspect_ratio(width, height, attributes, children)
}

/// See `howdy/ui/scroll_area`.
pub fn scroll_area(
  label: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  scroll_area.scroll_area(label, attributes, children)
}

/// See `howdy/ui/carousel`.
pub fn carousel(
  words: Words,
  id: String,
  label label: String,
  attributes attributes: List(Attribute(msg)),
  slides slides: List(carousel.Slide(msg)),
) -> Element(msg) {
  carousel.carousel(words, id, label:, attributes:, slides:)
}

pub fn carousel_slide(children: List(Element(msg))) -> carousel.Slide(msg) {
  carousel.slide(children)
}

/// See `howdy/ui/resizable`.
pub fn resizable_group(
  direction: resizable.Direction,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  resizable.group(direction, attributes, children)
}

pub fn resizable_panel(
  size: Int,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  resizable.panel(size, attributes, children)
}

pub fn resizable_handle(label: String) -> Element(msg) {
  resizable.handle(label)
}

/// See `howdy/ui/hover_card`.
pub fn hover_card(
  id: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  hover_card.card(id, attributes, children)
}

pub fn hover_card_trigger(id: String) -> List(Attribute(msg)) {
  hover_card.trigger(id)
}

/// See `howdy/ui/context_menu`. Its items are `menu_item` and friends.
pub fn context_menu_area(
  id: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  context_menu.area(id, attributes, children)
}

pub fn context_menu(
  id: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  context_menu.menu(id, attributes, children)
}

/// See `howdy/ui/menubar`. Its menus are `menu`s.
pub fn menubar(
  attributes: List(Attribute(msg)),
  buttons: List(Element(msg)),
) -> Element(msg) {
  menubar.menubar(attributes, buttons)
}

pub fn menubar_button(
  id: String,
  children: List(Element(msg)),
) -> Element(msg) {
  menubar.menu_button(id, children)
}

/// See `howdy/ui/navigation_menu`.
pub fn navigation_menu(
  attributes: List(Attribute(msg)),
  items: List(Element(msg)),
) -> Element(msg) {
  navigation_menu.menu(attributes, items)
}

pub fn navigation_link(
  href: String,
  active active: Bool,
  children children: List(Element(msg)),
) -> Element(msg) {
  navigation_menu.link(href, active:, children:)
}

pub fn navigation_panel(
  id: String,
  label label: List(Element(msg)),
  links links: List(Element(msg)),
) -> Element(msg) {
  navigation_menu.panel(id, label:, links:)
}

pub fn navigation_panel_link(
  href: String,
  title title: String,
  description description: String,
) -> Element(msg) {
  navigation_menu.panel_link(href, title:, description:)
}
