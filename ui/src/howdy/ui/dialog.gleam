//// Dialogs, alert dialogs and sheets: content shown above the page, which
//// is inert until the dialog closes.
////
//// ```gleam
//// ui.button(Outline, dialog.trigger("rename"), [text("Rename")]),
//// dialog.dialog("rename", [], [
////   dialog.header([
////     dialog.title("rename", [text("Rename project")]),
////     dialog.description("rename", [text("Pick a name your team will recognise.")]),
////   ]),
////   ui.input([attribute.name("name")]),
////   dialog.footer([
////     ui.button(Outline, dialog.close("rename"), [text("Cancel")]),
////     ui.button(Primary, [event.on_click(Rename)], [text("Save")]),
////   ]),
//// ])
//// ```
////
//// Each is a native `<dialog>` opened as a modal, so the browser keeps focus
//// inside it, closes it with Escape and returns focus to the trigger. The
//// trigger and the dialog are tied by id, so they must be in the same
//// document: both in the page, or both in one live view.
////
//// A `<form method="dialog">` inside a dialog closes it when submitted. A
//// live view hears the dialog close with `event.on("close", ...)`.
////
//// The behaviour needs `howdy/ui/behaviour` in older browsers; pages built
//// with `howdy/ui/page` include it.

import gleam/list
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{percent, rem}

/// The edge of the screen a sheet slides from.
pub type Side {
  Top
  Right
  Bottom
  Left
}

/// Attributes for a button that opens the dialog, alert dialog or sheet
/// with this id.
pub fn trigger(id: String) -> List(Attribute(msg)) {
  [
    attribute.attribute("commandfor", id),
    attribute.attribute("command", "show-modal"),
    attribute.aria_haspopup("dialog"),
  ]
}

/// Attributes for a button that closes the dialog with this id.
pub fn close(id: String) -> List(Attribute(msg)) {
  [
    attribute.attribute("commandfor", id),
    attribute.attribute("command", "close"),
  ]
}

/// A dialog in the middle of the screen. Clicking outside it closes it.
pub fn dialog(
  id: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.dialog(
    [
      class(dialog_class()),
      attribute.attribute("closedby", "any"),
      ..labelled(id, attributes)
    ],
    children,
  )
}

/// A dialog that asks for a decision. Clicking outside it does nothing, so
/// give it buttons for every answer. Escape still closes it.
pub fn alert_dialog(
  id: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.dialog(
    [
      class(dialog_class()),
      attribute.role("alertdialog"),
      attribute.attribute("closedby", "closerequest"),
      ..labelled(id, attributes)
    ],
    children,
  )
}

/// A dialog along one edge of the screen, for navigation or a form beside
/// the page's content. Clicking outside it closes it.
pub fn sheet(
  id: String,
  side: Side,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.dialog(
    [
      class(sheet_class(side)),
      attribute.attribute("closedby", "any"),
      ..labelled(id, attributes)
    ],
    children,
  )
}

fn labelled(
  id: String,
  attributes: List(Attribute(msg)),
) -> List(Attribute(msg)) {
  [
    attribute.id(id),
    attribute.aria_labelledby(id <> "-title"),
    attribute.aria_describedby(id <> "-description"),
    ..attributes
  ]
}

/// The title and description at the top.
pub fn header(children: List(Element(msg))) -> Element(msg) {
  html.div([class(header_class())], children)
}

/// The dialog's name, read out when it opens. Pass the dialog's id.
pub fn title(id: String, children: List(Element(msg))) -> Element(msg) {
  html.h2([class(title_class()), attribute.id(id <> "-title")], children)
}

/// A sentence about the dialog, read out after its title. Pass the dialog's
/// id.
pub fn description(id: String, children: List(Element(msg))) -> Element(msg) {
  html.p(
    [class(description_class()), attribute.id(id <> "-description")],
    children,
  )
}

/// A row of buttons at the bottom, aligned to the end.
pub fn footer(children: List(Element(msg))) -> Element(msg) {
  html.div([class(footer_class())], children)
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    dialog_class(),
    sheet_class(Top),
    sheet_class(Right),
    sheet_class(Bottom),
    sheet_class(Left),
    header_class(),
    title_class(),
    description_class(),
    footer_class(),
  ]
}

fn surface() -> List(css.Style) {
  [
    css.padding(rem(1.5)),
    css.background(tokens.surface),
    css.color(tokens.text),
    style.bordered(),
    css.box_shadow("0 20px 50px -12px rgb(0 0 0 / 0.35)"),
    css.overflow("auto"),
    css.property("overscroll-behavior", "contain"),
    css.backdrop([css.background("rgb(0 0 0 / 0.5)")]),
    css.focus_visible([css.outline("none")]),
  ]
}

pub fn dialog_class() -> Class {
  css.class([
    css.width(percent(100)),
    css.property("max-width", "min(32rem, calc(100% - 2rem))"),
    css.property("max-height", "calc(100% - 2rem)"),
    style.radius(tokens.radius_large),
    ..surface()
  ])
}

pub fn sheet_class(side: Side) -> Class {
  let placement = case side {
    Top -> [
      css.margin_("0 0 auto"),
      css.width(percent(100)),
      css.property("max-height", "80%"),
      css.property("border-width", "0 0 1px"),
    ]
    Bottom -> [
      css.margin_("auto 0 0"),
      css.width(percent(100)),
      css.property("max-height", "80%"),
      css.property("border-width", "1px 0 0"),
    ]
    Left -> [
      css.margin_("0 auto 0 0"),
      css.height(percent(100)),
      css.property("width", "min(24rem, calc(100% - 3rem))"),
      css.property("border-width", "0 1px 0 0"),
    ]
    Right -> [
      css.margin_("0 0 0 auto"),
      css.height(percent(100)),
      css.property("width", "min(24rem, calc(100% - 3rem))"),
      css.property("border-width", "0 0 0 1px"),
    ]
  }
  css.class(
    [
      css.inset("0"),
      css.property("max-width", "none"),
      css.property("max-height", "none"),
      style.radius("0"),
      ..surface()
    ]
    |> list.append(placement),
  )
}

pub fn header_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(0.375)),
    css.margin_("0 0 " <> tokens.space_4),
  ])
}

pub fn title_class() -> Class {
  css.class([
    css.margin(rem(0.0)),
    css.font_size(rem(1.125)),
    css.font_weight("600"),
    css.line_height("1.25"),
  ])
}

pub fn description_class() -> Class {
  css.class([
    css.margin(rem(0.0)),
    css.font_size(rem(0.875)),
    css.color(tokens.text_muted),
  ])
}

pub fn footer_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_wrap("wrap"),
    css.justify_content("flex-end"),
    css.gap(rem(0.5)),
    css.margin_(tokens.space_6 <> " 0 0"),
  ])
}
