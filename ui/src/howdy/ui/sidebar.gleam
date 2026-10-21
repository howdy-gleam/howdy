//// An application layout with a sidebar for navigation.
////
//// ```gleam
//// use state <- cookie.string_or(ctx, "sidebar", default: "expanded")
////
//// sidebar.layout(collapsed: state == "collapsed", attributes: [], sidebar:
////   sidebar.sidebar("nav", [], [
////     sidebar.header([text("Acme")]),
////     sidebar.content([
////       sidebar.group("Workspace", [
////         sidebar.link("/", active: True, attributes: [], children: [text("Home")]),
////         sidebar.link("/orders", active: False, attributes: [], children: [text("Orders")]),
////       ]),
////     ]),
////     sidebar.footer([text("ada@example.com")]),
////   ]),
//// main: [
////   ui.sized_button(Ghost, Icon, [attribute.aria_label("Toggle sidebar"), ..sidebar.trigger("nav")], [menu_icon]),
////   page_content,
//// ])
//// ```
////
//// On screens at least 48rem wide the sidebar is a column beside the
//// content, and the trigger collapses and expands it. The choice is kept
//// in a `sidebar` cookie holding `collapsed` or `expanded`, so read it and
//// pass `collapsed` to render the next page the same way. On narrower
//// screens the sidebar is hidden and the trigger opens it over the page,
//// where Escape or a click outside closes it.
////
//// The trigger and the sidebar are tied by id, so both must be in the
//// page or both in one live view.

import gleam/list
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{px, rem}
import sketch/css/media

/// The whole screen: the sidebar and the main content beside it.
pub fn layout(
  collapsed collapsed: Bool,
  attributes attributes: List(Attribute(msg)),
  sidebar sidebar: Element(msg),
  main main: List(Element(msg)),
) -> Element(msg) {
  styled_layout(
    collapsed:,
    collapse: Offcanvas,
    variant: Plain,
    attributes:,
    sidebar:,
    main:,
  )
}

/// What collapsing does on a wide screen.
pub type Collapse {
  /// The sidebar goes away entirely.
  Offcanvas
  /// The sidebar narrows to a rail of icons; labels are hidden but still
  /// read by screen readers, and shown as a tooltip on hover. Give links
  /// icons with `icon_link`.
  Rail
}

/// How the sidebar sits beside the page.
pub type Variant {
  /// Flush with the page, with a line between them.
  Plain
  /// A card floating over the page's edge.
  Floating
  /// The page is a card set into the sidebar's background.
  Inset
}

/// A layout that collapses another way, or is drawn another way.
pub fn styled_layout(
  collapsed collapsed: Bool,
  collapse collapse: Collapse,
  variant variant: Variant,
  attributes attributes: List(Attribute(msg)),
  sidebar sidebar: Element(msg),
  main main: List(Element(msg)),
) -> Element(msg) {
  let state = case collapsed {
    True -> "collapsed"
    False -> "expanded"
  }
  let collapse = case collapse {
    Offcanvas -> "offcanvas"
    Rail -> "rail"
  }
  let variant = case variant {
    Plain -> "plain"
    Floating -> "floating"
    Inset -> "inset"
  }
  html.div(
    [
      class(layout_class()),
      attribute.data("howdy-sidebar-layout", ""),
      attribute.data("state", state),
      attribute.data("collapse", collapse),
      attribute.data("variant", variant),
      ..attributes
    ],
    [sidebar, html.main([class(main_class())], main)],
  )
}

/// Text that the icon rail hides, such as the app's name in the header.
pub fn label(children: List(Element(msg))) -> Element(msg) {
  html.span([attribute.data("howdy-sidebar-label", "")], children)
}

/// A link with an icon, which stays when the sidebar is a rail.
pub fn icon_link(
  href: String,
  active active: Bool,
  icon icon: Element(msg),
  label text_label: String,
  attributes attributes: List(Attribute(msg)),
) -> Element(msg) {
  link(
    href,
    active:,
    attributes: [attribute.title(text_label), ..attributes],
    children: [
      html.span([class(icon_class()), attribute.aria_hidden(True)], [icon]),
      label([text(text_label)]),
    ],
  )
}

/// A section of links that opens and closes, such as the pages under
/// "Settings". It is a `<details>`, so it works without scripts.
pub fn submenu(
  icon icon: Element(msg),
  label text_label: String,
  open open: Bool,
  items items: List(Element(msg)),
) -> Element(msg) {
  html.li([], [
    html.details([class(submenu_class()), attribute.open(open)], [
      html.summary([class(item_class()), attribute.title(text_label)], [
        html.span([class(icon_class()), attribute.aria_hidden(True)], [icon]),
        label([text(text_label)]),
      ]),
      html.ul([class(submenu_list_class())], items),
    ]),
  ])
}

/// Attributes for the button that collapses the sidebar with this id, or
/// opens it on a narrow screen.
pub fn trigger(id: String) -> List(Attribute(msg)) {
  [
    attribute.attribute("popovertarget", id),
    attribute.aria_controls(id),
    attribute.data("howdy-sidebar-trigger", ""),
  ]
}

pub fn sidebar(
  id: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.aside(
    [
      class(sidebar_class()),
      attribute.id(id),
      attribute.popover("auto"),
      ..attributes
    ],
    children,
  )
}

/// The top of the sidebar, such as the app's name or a workspace switcher.
pub fn header(children: List(Element(msg))) -> Element(msg) {
  html.div([class(header_class())], children)
}

/// The part of the sidebar that scrolls.
pub fn content(children: List(Element(msg))) -> Element(msg) {
  html.nav([class(content_class())], children)
}

/// The bottom of the sidebar, such as the signed-in user.
pub fn footer(children: List(Element(msg))) -> Element(msg) {
  html.div([class(footer_class())], children)
}

/// A labelled list of links. Pass `""` for no label.
pub fn group(label: String, items: List(Element(msg))) -> Element(msg) {
  let heading = case label {
    "" -> []
    _ -> [
      html.div(
        [class(group_label_class()), attribute.data("howdy-sidebar-label", "")],
        [text(label)],
      ),
    ]
  }
  html.div(
    [class(group_class())],
    list.append(heading, [html.ul([class(menu_class())], items)]),
  )
}

/// A link in a group. `active` marks the page being shown.
pub fn link(
  href: String,
  active active: Bool,
  attributes attributes: List(Attribute(msg)),
  children children: List(Element(msg)),
) -> Element(msg) {
  let current = case active {
    True -> [attribute.aria_current("page")]
    False -> []
  }
  html.li([], [
    html.a(
      [
        class(item_class()),
        attribute.href(href),
        ..list.append(current, attributes)
      ],
      children,
    ),
  ])
}

/// A button in a group, for an action rather than a page.
pub fn button(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.li([], [
    html.button(
      [class(item_class()), attribute.type_("button"), ..attributes],
      children,
    ),
  ])
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    icon_class(),
    submenu_class(),
    submenu_list_class(),
    layout_class(),
    main_class(),
    sidebar_class(),
    header_class(),
    content_class(),
    footer_class(),
    group_class(),
    group_label_class(),
    menu_class(),
    item_class(),
  ]
}

const wide = 768

/// Visually hidden, but still read by screen readers.
fn screen_reader_only() -> List(css.Style) {
  [
    css.position("absolute"),
    css.property("width", "1px"),
    css.property("height", "1px"),
    css.overflow("hidden"),
    css.property("clip-path", "inset(50%)"),
    css.white_space("nowrap"),
  ]
}

pub fn layout_class() -> Class {
  let collapsed_rail = "[data-collapse=\"rail\"][data-state=\"collapsed\"]"
  css.class([
    css.display("grid"),
    css.grid_template_columns("minmax(0, 1fr)"),
    css.property("min-height", "100vh"),
    css.selector("[data-variant=\"inset\"]", [css.background(tokens.surface)]),
    css.media(media.min_width(px(wide)), [
      css.grid_template_columns("16rem minmax(0, 1fr)"),
      css.transition("grid-template-columns 150ms"),
      css.selector("[data-collapse=\"offcanvas\"][data-state=\"collapsed\"]", [
        css.grid_template_columns("minmax(0, 1fr)"),
      ]),
      css.selector(
        "[data-collapse=\"offcanvas\"][data-state=\"collapsed\"] > aside",
        [css.display("none")],
      ),
      // The rail: icons only, labels kept for screen readers.
      css.selector(collapsed_rail, [
        css.grid_template_columns("3.5rem minmax(0, 1fr)"),
      ]),
      css.selector(
        collapsed_rail <> " [data-howdy-sidebar-label]",
        screen_reader_only(),
      ),
      css.selector(collapsed_rail <> " details > ul", [css.display("none")]),
      css.selector(collapsed_rail <> " summary::after", [css.display("none")]),
      // Floating: the sidebar is a card, clear of the page's edge.
      css.selector("[data-variant=\"floating\"] > aside", [
        css.margin(rem(0.5)),
        css.property("height", "calc(100vh - 1rem)"),
        css.property("top", "0.5rem"),
        style.bordered(),
        style.radius(tokens.radius_large),
        css.box_shadow("0 4px 16px -8px rgb(0 0 0 / 0.2)"),
      ]),
      // Inset: the page is a card set into the sidebar's background.
      css.selector("[data-variant=\"inset\"] > aside", [
        css.property("border-inline-end", "0"),
      ]),
      css.selector("[data-variant=\"inset\"] > main", [
        css.margin_("0.5rem 0.5rem 0.5rem 0"),
        css.background(tokens.background),
        style.bordered(),
        style.radius(tokens.radius_large),
        css.overflow("hidden"),
      ]),
    ]),
  ])
}

pub fn main_class() -> Class {
  css.class([css.property("min-width", "0")])
}

pub fn sidebar_class() -> Class {
  css.class([
    css.flex_direction("column"),
    css.margin(rem(0.0)),
    css.padding(rem(0.0)),
    css.background(tokens.surface),
    css.color(tokens.text),
    css.border("0"),
    css.overflow("hidden"),
    // Opened over the page on a narrow screen.
    css.selector(":popover-open", [
      css.display("flex"),
      css.position("fixed"),
      css.property("inset-block", "0"),
      css.property("inset-inline", "0 auto"),
      css.property("width", "min(18rem, 85vw)"),
      css.property("height", "100%"),
      css.property("max-height", "none"),
      style.bordered_side("inline-end"),
      css.box_shadow("0 20px 50px -12px rgb(0 0 0 / 0.35)"),
    ]),
    css.backdrop([css.background("rgb(0 0 0 / 0.5)")]),
    // A column in the layout on a wide screen, whether or not it is open.
    css.media(media.min_width(px(wide)), [
      css.display("flex"),
      css.position("sticky"),
      css.property("inset-block", "0 auto"),
      css.property("inset-inline", "0 auto"),
      css.property("top", "0"),
      css.property("width", "auto"),
      css.property("height", "100vh"),
      style.bordered_side("inline-end"),
      css.box_shadow("none"),
    ]),
  ])
}

pub fn header_class() -> Class {
  css.class([
    css.padding_(tokens.space_4),
    css.font_weight("600"),
  ])
}

pub fn content_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(1.0)),
    css.property("flex", "1"),
    css.overflow_y("auto"),
    css.padding_("0 " <> tokens.space_2),
  ])
}

pub fn footer_class() -> Class {
  css.class([
    css.padding_(tokens.space_4),
    style.bordered_side("top"),
    css.font_size(rem(0.875)),
  ])
}

pub fn group_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(0.25)),
  ])
}

pub fn group_label_class() -> Class {
  css.class([
    css.padding_("0 " <> tokens.space_2),
    css.font_size(rem(0.75)),
    css.font_weight("500"),
    css.color(tokens.text_muted),
  ])
}

pub fn menu_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(0.125)),
    css.margin(rem(0.0)),
    css.padding(rem(0.0)),
    css.list_style("none"),
  ])
}

pub fn icon_class() -> Class {
  css.class([
    css.display("inline-flex"),
    css.align_items("center"),
    css.justify_content("center"),
    css.flex_shrink(0.0),
    css.property("width", "1.25rem"),
    css.property("height", "1.25rem"),
  ])
}

pub fn submenu_class() -> Class {
  css.class([
    css.selector(" > summary", [css.list_style("none")]),
    css.selector(" > summary::-webkit-details-marker", [css.display("none")]),
    css.selector(" > summary::after", [
      css.content("\"\""),
      css.property("margin-inline-start", "auto"),
      css.property("width", "0.4rem"),
      css.property("height", "0.4rem"),
      css.property("border-right", "2px solid " <> tokens.text_muted),
      css.property("border-bottom", "2px solid " <> tokens.text_muted),
      css.transform_("rotate(45deg)"),
      css.transition("transform 150ms"),
    ]),
    css.selector("[open] > summary::after", [css.transform_("rotate(-135deg)")]),
  ])
}

pub fn submenu_list_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(0.125)),
    css.margin_("0.125rem 0 0"),
    css.padding(rem(0.0)),
    css.property("padding-inline-start", "1.75rem"),
    css.list_style("none"),
  ])
}

pub fn item_class() -> Class {
  css.class([
    css.display("flex"),
    css.align_items("center"),
    css.gap(rem(0.5)),
    css.width(length.percent(100)),
    css.padding_("0.375rem " <> tokens.space_2),
    css.border("0"),
    style.radius(tokens.radius_small),
    css.background("transparent"),
    css.color(tokens.text),
    css.font_family(tokens.font_body),
    css.font_size(rem(0.875)),
    css.line_height("1.25"),
    css.text_align("start"),
    css.text_decoration("none"),
    css.cursor("pointer"),
    css.hover([css.background(tokens.muted)]),
    style.focus_ring_offset("-2px"),
    css.selector("[aria-current=\"page\"]", [
      css.background(tokens.muted),
      css.font_weight("500"),
    ]),
  ])
}
