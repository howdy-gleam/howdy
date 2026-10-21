//// Context menus: a menu that opens where you right-click, or press the
//// context menu key, inside an area.
////
//// ```gleam
//// context_menu.area("file-actions", [], [file_preview]),
//// context_menu.menu("file-actions", [], [
////   menu.item([event.on_click(Rename)], [text("Rename")]),
////   menu.item([event.on_click(Duplicate)], [text("Duplicate")]),
////   menu.separator(),
////   menu.item([event.on_click(Delete)], [text("Delete")]),
//// ])
//// ```
////
//// Its items are `howdy/ui/menu` items, with the same keys: arrows, Home,
//// End and typeahead, Escape to close. A context menu is a shortcut, so
//// offer its actions somewhere visible too: touch screens and many
//// keyboards have no way to open it.

import howdy/ui/menu
import howdy/ui/style.{class}
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}

/// The area that opens the menu with this id.
pub fn area(
  id: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div([attribute.data("howdy-context-menu", id), ..attributes], children)
}

pub fn menu(
  id: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div(
    [
      class(menu.menu_class()),
      attribute.id(id),
      attribute.popover("auto"),
      attribute.role("menu"),
      attribute.data("howdy-at-pointer", ""),
      ..attributes
    ],
    children,
  )
}

/// Every class this module uses, for `howdy/ui/export`. The menu is
/// styled by `howdy/ui/menu`; the script places it at the pointer.
pub fn classes() -> List(Class) {
  []
}
