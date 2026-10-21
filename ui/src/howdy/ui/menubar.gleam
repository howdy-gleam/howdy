//// Menubars: a row of menus, as at the top of a desktop application.
////
//// ```gleam
//// menubar.menubar([attribute.aria_label("Editor")], [
////   menubar.menu_button("file-menu", [text("File")]),
////   menubar.menu_button("edit-menu", [text("Edit")]),
//// ]),
//// menu.menu("file-menu", [], [menu.item([], [text("New")]), menu.item([], [text("Open…")])]),
//// menu.menu("edit-menu", [], [menu.item([], [text("Undo")])]),
//// ```
////
//// The menus are `howdy/ui/menu` menus. Left and right move between the
//// buttons, and between open menus; down opens one. Once a menu is open,
//// pointing at another button opens that one instead.

import howdy/ui/menu
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

pub fn menubar(
  attributes: List(Attribute(msg)),
  buttons: List(Element(msg)),
) -> Element(msg) {
  html.div(
    [
      class(menubar_class()),
      attribute.role("menubar"),
      attribute.data("howdy-menubar", ""),
      ..attributes
    ],
    buttons,
  )
}

/// A button in the menubar that opens the menu with this id.
pub fn menu_button(id: String, children: List(Element(msg))) -> Element(msg) {
  html.button(
    [
      class(button_class()),
      attribute.type_("button"),
      attribute.role("menuitem"),
      ..menu.trigger(id)
    ],
    children,
  )
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [menubar_class(), button_class()]
}

pub fn menubar_class() -> Class {
  css.class([
    css.display("inline-flex"),
    css.align_items("center"),
    css.gap(rem(0.125)),
    css.padding(rem(0.25)),
    css.background(tokens.surface),
    style.bordered(),
    style.radius(tokens.radius_medium),
  ])
}

pub fn button_class() -> Class {
  css.class([
    css.padding_("0.375rem " <> tokens.space_3),
    css.border("0"),
    style.radius(tokens.radius_small),
    css.background("transparent"),
    css.color(tokens.text),
    css.font_family(tokens.font_body),
    css.font_size(rem(0.875)),
    css.font_weight("500"),
    css.cursor("pointer"),
    css.hover([css.background(tokens.muted)]),
    style.focus_ring_offset("-2px"),
    css.selector("[aria-expanded=\"true\"]", [css.background(tokens.muted)]),
  ])
}
