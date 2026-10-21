//// An application shell: a sidebar of navigation, a top bar with the page
//// heading and actions, and the page's content.
////
//// ```gleam
//// use state <- cookie.string_or(ctx, "sidebar", default: "expanded")
////
//// app_shell.app_shell(
////   app: "Acme",
////   collapsed: state == "collapsed",
////   current: "/orders",
////   navigation: [
////     app_shell.Group("Workspace", [
////       app_shell.Link("/", "Dashboard"),
////       app_shell.Link("/orders", "Orders"),
////     ]),
////   ],
////   footer: [text("ada@example.com")],
////   heading: "Orders",
////   actions: [ui.theme_toggle([text("Theme")], from: "light", to: "dark")],
////   content: [orders_table],
//// )
//// ```
////
//// The sidebar collapses on wide screens and opens over the page on narrow
//// ones; see `howdy/ui/sidebar`.

import gleam/list
import howdy/ui/button
import howdy/ui/sidebar
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// A labelled group of links in the sidebar.
pub type Group {
  Group(label: String, links: List(Link))
}

pub type Link {
  Link(href: String, label: String)
}

pub fn app_shell(
  app app: String,
  collapsed collapsed: Bool,
  current current: String,
  navigation navigation: List(Group),
  footer footer: List(Element(msg)),
  heading heading: String,
  actions actions: List(Element(msg)),
  content content: List(Element(msg)),
) -> Element(msg) {
  sidebar.layout(
    collapsed:,
    attributes: [],
    sidebar: sidebar.sidebar("app-navigation", [attribute.aria_label("Main")], [
      sidebar.header([text(app)]),
      sidebar.content(
        list.map(navigation, fn(group) {
          sidebar.group(
            group.label,
            list.map(group.links, fn(link) {
              sidebar.link(
                link.href,
                active: link.href == current,
                attributes: [],
                children: [text(link.label)],
              )
            }),
          )
        }),
      ),
      case footer {
        [] -> element.none()
        _ -> sidebar.footer(footer)
      },
    ]),
    main: [
      html.header([class(bar_class())], [
        html.div([class(group_class())], [
          button.sized(
            button.Ghost,
            button.Icon,
            [
              attribute.aria_label("Toggle navigation"),
              ..sidebar.trigger("app-navigation")
            ],
            [html.span([attribute.aria_hidden(True)], [text("☰")])],
          ),
          html.h1([class(heading_class())], [text(heading)]),
        ]),
        html.div([class(group_class())], actions),
      ]),
      html.div([class(content_class())], content),
    ],
  )
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [bar_class(), group_class(), heading_class(), content_class()]
}

pub fn bar_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_wrap("wrap"),
    css.align_items("center"),
    css.justify_content("space-between"),
    css.gap(rem(1.0)),
    css.padding_(tokens.space_3 <> " " <> tokens.space_6),
    style.bordered_side("bottom"),
  ])
}

pub fn group_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_wrap("wrap"),
    css.align_items("center"),
    css.gap(rem(0.75)),
  ])
}

pub fn heading_class() -> Class {
  css.class([
    css.margin(rem(0.0)),
    css.font_size(rem(1.125)),
    css.font_weight("600"),
  ])
}

pub fn content_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(1.5)),
    css.padding(rem(1.5)),
    css.property("max-width", "72rem"),
  ])
}
