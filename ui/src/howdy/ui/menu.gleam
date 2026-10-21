//// Dropdown menus: a list of actions opened from a button.
////
//// ```gleam
//// ui.button(Outline, menu.trigger("account"), [text("Account")]),
//// menu.menu("account", [], [
////   menu.label([text("Signed in as ada")]),
////   menu.item([event.on_click(OpenProfile)], [text("Profile")]),
////   menu.checkbox_item(model.compact, [event.on_click(ToggleCompact)], [text("Compact view")]),
////   menu.separator(),
////   menu.link("/sign-out", [], [text("Sign out")]),
//// ])
//// ```
////
//// The arrow keys, Home, End and the first letters of an item move between
//// items; Escape, Tab or choosing an item closes the menu and returns focus
//// to the button. The trigger and the menu are tied by id, so both must be
//// in the page or both in one live view.

import howdy/ui/style.{anchor_name, class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{rem}

/// Attributes for the button that opens the menu with this id.
pub fn trigger(id: String) -> List(Attribute(msg)) {
  [
    attribute.attribute("popovertarget", id),
    attribute.aria_haspopup("menu"),
    attribute.data("howdy-menu-trigger", ""),
    attribute.data("howdy-anchor", anchor_name(id)),
  ]
}

pub fn menu(
  id: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div(
    [
      class(menu_class()),
      attribute.id(id),
      attribute.popover("auto"),
      attribute.role("menu"),
      attribute.data("howdy-anchored", anchor_name(id)),
      ..attributes
    ],
    children,
  )
}

/// An action. Disable one with `attribute.aria_disabled(True)`, which
/// keeps it visible and announced but not chosen.
pub fn item(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.button(
    [
      class(item_class()),
      attribute.type_("button"),
      attribute.role("menuitem"),
      attribute.tabindex(-1),
      ..attributes
    ],
    children,
  )
}

/// An item that goes to another page.
pub fn link(
  href: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.a(
    [
      class(item_class()),
      attribute.href(href),
      attribute.role("menuitem"),
      attribute.tabindex(-1),
      ..attributes
    ],
    children,
  )
}

/// An item that turns a setting on or off, with a tick when it is on.
/// Choosing it flips the tick in the browser; a live view that keeps the
/// setting should update it from the item's click, so the two agree.
pub fn checkbox_item(
  checked: Bool,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.button(
    [
      class(item_class()),
      attribute.type_("button"),
      attribute.role("menuitemcheckbox"),
      attribute.aria_checked(case checked {
        True -> "true"
        False -> "false"
      }),
      attribute.tabindex(-1),
      ..attributes
    ],
    children,
  )
}

/// Items of which exactly one is chosen, such as a sort order. Label the
/// group; it is announced before its items.
pub fn radio_group(label: String, items: List(Element(msg))) -> Element(msg) {
  html.div([attribute.role("group"), attribute.aria_label(label)], items)
}

/// One choice in a `radio_group`, with a dot when it is the chosen one.
/// Choosing it moves the dot in the browser; update your own state from
/// its click too.
pub fn radio_item(
  checked: Bool,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.button(
    [
      class(item_class()),
      attribute.type_("button"),
      attribute.role("menuitemradio"),
      attribute.aria_checked(case checked {
        True -> "true"
        False -> "false"
      }),
      attribute.tabindex(-1),
      ..attributes
    ],
    children,
  )
}

/// An item that opens a menu of its own beside it: with the right arrow,
/// Enter, a click, or by pointing at it. The left arrow or Escape closes
/// it again. `id` must be unique in the document.
pub fn submenu(
  id: String,
  label label: List(Element(msg)),
  items items: List(Element(msg)),
) -> Element(msg) {
  // The submenu sits inside its parent, so opening it keeps the parent open.
  html.div([attribute.role("none")], [
    html.button(
      [
        class(item_class()),
        attribute.type_("button"),
        attribute.role("menuitem"),
        attribute.aria_haspopup("menu"),
        attribute.tabindex(-1),
        attribute.attribute("popovertarget", id),
        attribute.data("howdy-submenu-trigger", ""),
        attribute.data("howdy-anchor", anchor_name(id)),
      ],
      label,
    ),
    html.div(
      [
        class(menu_class()),
        class(submenu_class()),
        attribute.id(id),
        attribute.popover("auto"),
        attribute.role("menu"),
        attribute.data("howdy-anchored", anchor_name(id)),
      ],
      items,
    ),
  ])
}

/// A heading for the items after it.
pub fn label(children: List(Element(msg))) -> Element(msg) {
  html.div([class(label_class()), attribute.role("presentation")], children)
}

pub fn separator() -> Element(msg) {
  html.div([class(separator_class()), attribute.role("separator")], [])
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    menu_class(),
    submenu_class(),
    item_class(),
    label_class(),
    separator_class(),
  ]
}

pub fn menu_class() -> Class {
  css.class([
    css.inset("auto"),
    css.margin_("0.375rem 0"),
    css.property("position-area", "block-end span-inline-end"),
    css.property("position-try-fallbacks", "flip-block, flip-inline"),
    css.property("min-width", "10rem"),
    css.property("max-height", "calc(100vh - 2rem)"),
    css.overflow_y("auto"),
    css.padding(rem(0.25)),
    css.background(tokens.surface),
    css.color(tokens.text),
    style.bordered(),
    style.radius(tokens.radius_medium),
    css.box_shadow("0 10px 30px -10px rgb(0 0 0 / 0.3)"),
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
    css.property("user-select", "none"),
    css.outline("none"),
    css.hover([css.background(tokens.muted)]),
    css.focus([css.background(tokens.muted)]),
    css.selector("[aria-disabled=\"true\"]", [
      css.property("opacity", "0.5"),
      css.cursor("default"),
      css.property("pointer-events", "none"),
    ]),
    // Checkbox and radio items keep room for their mark, so labels line up.
    css.selector("[role=\"menuitemcheckbox\"]", [
      css.property("padding-inline-start", "1.75rem"),
      css.position("relative"),
    ]),
    css.selector("[role=\"menuitemradio\"]", [
      css.property("padding-inline-start", "1.75rem"),
      css.position("relative"),
    ]),
    css.selector("[role=\"menuitemradio\"][aria-checked=\"true\"]::before", [
      css.content("\"\""),
      css.position("absolute"),
      css.property("inset-inline-start", "0.6rem"),
      css.property("top", "50%"),
      css.property("width", "0.4rem"),
      css.property("height", "0.4rem"),
      style.pill(),
      css.background("currentColor"),
      css.transform_("translateY(-50%)"),
    ]),
    // A submenu's item ends with a chevron pointing the way it opens.
    css.selector("[aria-haspopup=\"menu\"]::after", [
      css.content("\"\""),
      css.property("margin-inline-start", "auto"),
      css.property("width", "0.4rem"),
      css.property("height", "0.4rem"),
      css.property("border-right", "2px solid " <> tokens.text_muted),
      css.property("border-bottom", "2px solid " <> tokens.text_muted),
      css.transform_("rotate(-45deg)"),
    ]),
    css.selector(":dir(rtl)[aria-haspopup=\"menu\"]::after", [
      css.transform_("rotate(135deg)"),
    ]),
    css.selector("[aria-expanded=\"true\"]", [css.background(tokens.muted)]),
    css.selector("[role=\"menuitemcheckbox\"][aria-checked=\"true\"]::before", [
      css.content("\"\""),
      css.position("absolute"),
      css.property("inset-inline-start", "0.7rem"),
      css.property("top", "45%"),
      css.property("width", "0.3rem"),
      css.property("height", "0.55rem"),
      css.property("border-right", "2px solid currentColor"),
      css.property("border-bottom", "2px solid currentColor"),
      css.transform_("translateY(-50%) rotate(45deg)"),
    ]),
  ])
}

/// A submenu opens beside its item, or on the other side if there is no
/// room.
pub fn submenu_class() -> Class {
  css.class([
    css.margin_("0 0.25rem"),
    css.property("position-area", "inline-end span-block-end"),
    css.property("position-try-fallbacks", "flip-inline, flip-block"),
  ])
}

pub fn label_class() -> Class {
  css.class([
    css.padding_("0.375rem " <> tokens.space_2),
    css.font_size(rem(0.75)),
    css.font_weight("500"),
    css.color(tokens.text_muted),
  ])
}

pub fn separator_class() -> Class {
  css.class([
    css.height(length.px(1)),
    css.margin_(tokens.space_1 <> " -" <> tokens.space_1),
    css.background(tokens.border),
  ])
}
