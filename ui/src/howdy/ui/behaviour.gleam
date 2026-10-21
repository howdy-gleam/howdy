//// The browser side of the interactive components: dialogs, popovers,
//// menus, tooltips, tabs and selects.
////
//// Those components are built on what the browser already does. A dialog
//// is a `<dialog>` opened with an invoker command, a popover or menu uses
//// the popover API and CSS anchor positioning, an accordion is a set of
//// `<details>`. The browser traps focus in a modal, closes on Escape and
//// outside clicks, and puts focus back afterwards.
////
//// This script adds what the browser does not:
////
//// - arrow keys, Home, End and typeahead in menus and selects, arrow keys
////   between tabs and between the days of a calendar;
//// - choosing a select, combobox or calendar option, and switching tab
////   panels;
//// - filtering a command menu as you type, and its keyboard shortcut;
//// - showing a tooltip on hover and focus, and closing a toast;
//// - sending an uploader's files straight to storage, with progress;
//// - keeping a notification bell's count and list up to date as
////   notifications arrive, and showing each as a toast;
//// - collapsing the sidebar on wide screens and remembering it;
//// - fallbacks for browsers without invoker commands, `closedby` on
////   dialogs, or CSS anchor positioning.
////
//// It listens on the document and follows events into open shadow roots,
//// so the same script serves the page and every live view on it. The
//// components find each other by element id, and ids are looked up in the
//// tree that holds the element, so a trigger and what it opens must both be
//// in the page or both in the same live view.
////
//// `howdy/ui/page` includes the script in every page. If you render the
//// document yourself, add `script()` to its head. The JavaScript itself
//// lives in `priv/behaviour.js`, read once on first use.
////
//// The browser owns open and selected state. A live view that wants to know
//// listens for the native events: `close` on a dialog, `toggle` on a
//// popover or `<details>`, `change` on the hidden input of a select,
//// combobox or calendar, or `click` on a tab, menu item or command item.

import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

/// The script, as a module script for the document head.
pub fn script() -> Element(msg) {
  html.script([attribute.type_("module")], source())
}

/// The script's source, as served in every page: the contents of
/// `priv/behaviour.js` in this package.
///
/// The file is read from the package's priv directory the first time it is
/// needed and kept in memory from then on. A missing file is an error
/// naming the path.
pub fn source() -> String {
  load_source()
}

@external(erlang, "howdy_ui_ffi", "behaviour_source")
fn load_source() -> String
