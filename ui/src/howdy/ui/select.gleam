//// Selects: a button that opens a list of options to choose one from.
////
//// ```gleam
//// select.select(
////   id: "plan",
////   name: "plan",
////   value: "",
////   placeholder: "Choose a plan",
////   attributes: [],
////   items: [
////     select.item("free", "Free"),
////     select.item("pro", "Pro"),
////     select.disabled_item("enterprise", "Enterprise"),
////   ],
//// )
//// ```
////
//// Unlike the native select in `howdy/ui/input`, the list is styled to
//// match the theme. The chosen value is kept in a hidden input called
//// `name`, so it submits with a form; a live view hears it with
//// `live.on_value(name, ...)` on an element around the select.
////
//// `attributes` go on the button that opens the list: `attribute.disabled`
//// disables it, and `attribute.aria_invalid("true")` with
//// `aria-describedby` marks it wrong and points at the message.
////
//// The arrow keys, Home, End and the first letters of an option move
//// through the list; Enter or Space chooses. Label it with
//// `input.label([attribute.for(id)], ...)`.

import gleam/int
import gleam/list
import howdy/ui/style.{anchor_name, class}
import howdy/ui/theme/tokens
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{percent, rem}

/// An option, or a labelled group of them.
pub opaque type Item {
  Item(value: String, label: String, disabled: Bool)
  Group(label: String, items: List(Item))
}

pub fn item(value: String, label: String) -> Item {
  Item(value:, label:, disabled: False)
}

/// An option that is shown but cannot be chosen.
pub fn disabled_item(value: String, label: String) -> Item {
  Item(value:, label:, disabled: True)
}

pub fn group(label: String, items: List(Item)) -> Item {
  Group(label:, items:)
}

/// A select showing the option whose value is `value`, or `placeholder`
/// when none matches.
pub fn select(
  id id: String,
  name name: String,
  value value: String,
  placeholder placeholder: String,
  attributes attributes: List(Attribute(msg)),
  items items: List(Item),
) -> Element(msg) {
  let listbox = id <> "-listbox"
  let chosen = find_label(items, value)
  let shown = case chosen {
    Ok(label) -> label
    Error(Nil) -> placeholder
  }
  let placeholder_mark = case chosen {
    Ok(_) -> []
    Error(Nil) -> [attribute.data("placeholder", "")]
  }
  html.div([class(root_class()), attribute.data("howdy-select", "")], [
    html.input([
      attribute.type_("hidden"),
      attribute.name(name),
      attribute.value(value),
    ]),
    html.button(
      [
        class(trigger_class()),
        attribute.type_("button"),
        attribute.id(id),
        attribute.attribute("popovertarget", listbox),
        attribute.aria_haspopup("listbox"),
        attribute.data("howdy-select-trigger", ""),
        attribute.data("howdy-anchor", anchor_name(listbox)),
        ..list.append(placeholder_mark, attributes)
      ],
      [
        html.span(
          [
            attribute.data("howdy-select-value", ""),
            attribute.data("howdy-placeholder", placeholder),
          ],
          [text(shown)],
        ),
      ],
    ),
    html.div(
      [
        class(listbox_class()),
        attribute.id(listbox),
        attribute.popover("auto"),
        attribute.role("listbox"),
        attribute.data("howdy-anchored", anchor_name(listbox)),
      ],
      render_items(items, id, value),
    ),
  ])
}

fn find_label(items: List(Item), value: String) -> Result(String, Nil) {
  list.find_map(items, fn(item) {
    case item {
      Item(value: v, label:, ..) if v == value -> Ok(label)
      Item(..) -> Error(Nil)
      Group(items:, ..) -> find_label(items, value)
    }
  })
}

fn render_items(
  items: List(Item),
  id: String,
  value: String,
) -> List(Element(msg)) {
  list.index_map(items, fn(item, index) {
    case item {
      Item(value: v, label:, disabled:) ->
        html.div(
          [
            class(option_class()),
            attribute.role("option"),
            attribute.data("value", v),
            attribute.tabindex(-1),
            attribute.aria_selected(v == value),
            attribute.aria_disabled(disabled),
          ],
          [text(label)],
        )
      Group(label:, items:) -> {
        let label_id = id <> "-group-" <> int.to_string(index)
        html.div(
          [attribute.role("group"), attribute.aria_labelledby(label_id)],
          [
            html.div([class(group_label_class()), attribute.id(label_id)], [
              text(label),
            ]),
            ..render_items(items, label_id, value)
          ],
        )
      }
    }
  })
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    root_class(),
    trigger_class(),
    listbox_class(),
    option_class(),
    group_label_class(),
  ]
}

pub fn root_class() -> Class {
  css.class([css.display("block"), css.width(percent(100))])
}

pub fn trigger_class() -> Class {
  css.class([
    css.display("flex"),
    css.align_items("center"),
    css.justify_content("space-between"),
    css.gap(rem(0.5)),
    css.width(percent(100)),
    css.padding_(tokens.space_2 <> " " <> tokens.space_3),
    css.background(tokens.surface),
    css.color(tokens.text),
    style.bordered(),
    style.radius(tokens.radius_medium),
    css.font_family(tokens.font_body),
    css.font_size(rem(1.0)),
    css.line_height("1.5"),
    css.text_align("start"),
    css.cursor("pointer"),
    css.selector("[data-placeholder]", [css.color(tokens.text_muted)]),
    css.selector("[aria-invalid=\"true\"]", [
      css.property("border-color", tokens.danger),
    ]),
    style.focus_ring(),
    style.disabled_look(),
    css.after([
      css.content("\"\""),
      css.flex_shrink(0.0),
      css.property("width", "0.45rem"),
      css.property("height", "0.45rem"),
      css.property("border-right", "2px solid " <> tokens.text_muted),
      css.property("border-bottom", "2px solid " <> tokens.text_muted),
      css.transform_("translateY(-25%) rotate(45deg)"),
    ]),
  ])
}

pub fn listbox_class() -> Class {
  css.class([
    css.inset("auto"),
    css.margin_("0.375rem 0"),
    css.property("position-area", "block-end span-inline-end"),
    css.property("position-try-fallbacks", "flip-block"),
    css.property("min-width", "anchor-size(width)"),
    css.property("max-height", "min(18rem, calc(100vh - 2rem))"),
    css.overflow_y("auto"),
    css.padding(rem(0.25)),
    css.background(tokens.surface),
    css.color(tokens.text),
    style.bordered(),
    style.radius(tokens.radius_medium),
    css.box_shadow("0 10px 30px -10px rgb(0 0 0 / 0.3)"),
  ])
}

pub fn option_class() -> Class {
  css.class([
    css.position("relative"),
    css.padding_("0.375rem " <> tokens.space_2),
    css.property("padding-inline-end", "2rem"),
    style.radius(tokens.radius_small),
    css.font_size(rem(0.875)),
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
    css.selector("[aria-selected=\"true\"]::after", [
      css.content("\"\""),
      css.position("absolute"),
      css.property("inset-inline-end", "0.75rem"),
      css.property("top", "45%"),
      css.property("width", "0.3rem"),
      css.property("height", "0.55rem"),
      css.property("border-right", "2px solid currentColor"),
      css.property("border-bottom", "2px solid currentColor"),
      css.transform_("translateY(-50%) rotate(45deg)"),
    ]),
  ])
}

pub fn group_label_class() -> Class {
  css.class([
    css.padding_("0.375rem " <> tokens.space_2),
    css.font_size(rem(0.75)),
    css.font_weight("500"),
    css.color(tokens.text_muted),
  ])
}
