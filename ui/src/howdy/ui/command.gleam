//// Command menus and comboboxes: a search box over a list of options that
//// narrows as you type.
////
//// ```gleam
//// command.command("actions", placeholder: "Type a command…", attributes: [], children: [
////   command.group("Suggestions", [
////     command.item([event.on_click(NewInvoice)], [text("New invoice")]),
////     command.item([command.keywords("customer client")], [text("Add contact")]),
////   ]),
////   command.empty([text("No results.")]),
//// ])
//// ```
////
//// Typing hides the options that do not match their text or `keywords`;
//// the arrow keys move through the rest and Enter activates one, as if it
//// were clicked. Focus stays in the search box throughout.
////
//// `dialog` opens a command menu over the page, with a keyboard shortcut
//// such as ⌘K. `combobox` is a select with a search box: choosing an option
//// sets a hidden input, like `howdy/ui/select`.
////
//// Filtering happens in the browser. With too many options to send at
//// once, render the matches from the server instead: listen for `input`
//// on the search box and pass `server_filtered` so the browser leaves the
//// list as it is.
////
//// `dialog` and the comboboxes take `words` for their names and the
//// labels of their clear and remove buttons; see `howdy/ui/words`.

import gleam/list
import gleam/string
import howdy/ui/style.{anchor_name, class}
import howdy/ui/theme/tokens
import howdy/ui/words.{type Words}
import lustre/attribute.{type Attribute}
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{percent, rem}

/// A search box above a list of groups, items and an empty message.
/// `attributes` go on the search box.
pub fn command(
  id: String,
  placeholder placeholder: String,
  attributes attributes: List(Attribute(msg)),
  children children: List(Element(msg)),
) -> Element(msg) {
  search_list(id, placeholder, attributes, children, [])
}

fn search_list(
  id: String,
  placeholder: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
  listbox: List(Attribute(msg)),
) -> Element(msg) {
  html.div([class(command_class()), attribute.data("howdy-command", "")], [
    html.input([
      class(input_class()),
      attribute.type_("text"),
      attribute.id(id),
      attribute.role("combobox"),
      attribute.aria_expanded(True),
      attribute.aria_controls(id <> "-list"),
      attribute.aria_autocomplete("list"),
      attribute.autocomplete("off"),
      attribute.attribute("spellcheck", "false"),
      attribute.placeholder(placeholder),
      ..attributes
    ]),
    html.div(
      [
        class(list_class()),
        attribute.id(id <> "-list"),
        attribute.role("listbox"),
        attribute.aria_label(placeholder),
        ..listbox
      ],
      children,
    ),
  ])
}

/// Leave the list as the server renders it instead of filtering it in the
/// browser. Put it in the command's `attributes`.
pub fn server_filtered() -> Attribute(msg) {
  attribute.data("howdy-server-filtered", "")
}

/// Options under a heading. Hidden when none of them match.
pub fn group(heading: String, items: List(Element(msg))) -> Element(msg) {
  html.div(
    [
      class(group_class()),
      attribute.role("group"),
      attribute.aria_label(heading),
    ],
    [
      html.div([class(heading_class()), attribute.aria_hidden(True)], [
        text(heading),
      ]),
      ..items
    ],
  )
}

/// An option. Its click handler runs when it is chosen with the mouse or
/// with Enter. Disable one with `attribute.aria_disabled(True)`.
pub fn item(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.div(
    [class(item_class()), attribute.role("option"), ..attributes],
    children,
  )
}

/// An option that goes to another page when chosen.
pub fn link(
  href: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.a(
    [
      class(item_class()),
      attribute.role("option"),
      attribute.href(href),
      attribute.tabindex(-1),
      ..attributes
    ],
    children,
  )
}

/// Extra words an item matches, beyond its text.
pub fn keywords(words: String) -> Attribute(msg) {
  attribute.data("keywords", words)
}

/// A line between groups.
pub fn separator() -> Element(msg) {
  html.div([class(separator_class()), attribute.role("separator")], [])
}

/// Shown when nothing matches.
pub fn empty(children: List(Element(msg))) -> Element(msg) {
  html.div(
    [
      class(empty_class()),
      attribute.data("howdy-command-empty", ""),
      attribute.role("presentation"),
      attribute.hidden(True),
    ],
    children,
  )
}

/// A command menu in a dialog. `shortcut` is a letter that opens it with
/// ⌘ on macOS or Ctrl elsewhere; pass `""` for none. Open it with a button
/// too, using `howdy/ui/dialog.trigger`.
pub fn dialog(
  words: Words,
  id: String,
  shortcut shortcut: String,
  attributes attributes: List(Attribute(msg)),
  command command: Element(msg),
) -> Element(msg) {
  let shortcut = case shortcut {
    "" -> []
    key -> [attribute.data("howdy-shortcut", string.lowercase(key))]
  }
  html.dialog(
    [
      class(dialog_class()),
      attribute.id(id),
      attribute.attribute("closedby", "any"),
      attribute.aria_label(words.command_menu),
      ..list.append(shortcut, attributes)
    ],
    [command],
  )
}

/// A button showing the chosen option, or `placeholder`, that opens a
/// searchable list. Choosing sets the hidden input called `name`; a clear
/// button beside it empties it again. Each option is an `item` with a
/// value, made with `option`. `attributes` go on the button: pass
/// `attribute.disabled(True)` or `attribute.aria_invalid("true")` there.
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
  picker(
    words,
    id,
    name,
    value,
    label,
    placeholder,
    search,
    attributes,
    options,
  )
}

/// A combobox where several options can be chosen, from `options` given
/// as `#(value, label)`. Choosing one toggles it and leaves the list open.
/// The chosen options show as chips beside the button, each with its own
/// remove button; Backspace on the button removes the last.
///
/// The form gets one field called `name` per chosen value, so values may
/// hold any character; read them with `list.key_filter(fields, name)`. A
/// live view hears the whole set with `howdy/ui/live.on_values`.
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
  let popover = id <> "-popover"
  let chosen = fn(value) { list.contains(values, value) }
  let placeholder_mark = case values {
    [] -> [attribute.data("placeholder", "")]
    _ -> []
  }
  html.div(
    [
      class(combobox_class()),
      attribute.data("howdy-select", ""),
      attribute.data("multiple", ""),
      attribute.data("name", name),
    ],
    list.flatten([
      [
        html.div(
          [
            class(chips_class()),
            attribute.data("howdy-anchor", anchor_name(popover)),
          ],
          list.append(
            list.map(options, fn(option) {
              let #(value, label) = option
              html.span(
                [
                  class(chip_class()),
                  attribute.data("howdy-chip", ""),
                  attribute.data("value", value),
                  attribute.hidden(!chosen(value)),
                ],
                [
                  html.span([], [text(label)]),
                  html.button(
                    [
                      class(chip_remove_class()),
                      attribute.type_("button"),
                      attribute.aria_label(words.remove(label)),
                      attribute.data("howdy-chip-remove", ""),
                    ],
                    [html.span([attribute.aria_hidden(True)], [text("×")])],
                  ),
                ],
              )
            }),
            [
              html.button(
                [
                  class(chips_trigger_class()),
                  attribute.type_("button"),
                  attribute.id(id),
                  attribute.attribute("popovertarget", popover),
                  attribute.aria_haspopup("listbox"),
                  attribute.data("howdy-select-trigger", ""),
                  ..list.append(placeholder_mark, attributes)
                ],
                [
                  html.span(
                    [
                      class(value_class()),
                      attribute.data("howdy-select-value", ""),
                      attribute.data("howdy-placeholder", placeholder),
                    ],
                    [text(placeholder)],
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
      // One field per option, sent only while it is chosen.
      list.map(options, fn(option) {
        html.input([
          attribute.type_("hidden"),
          attribute.name(name),
          attribute.value(option.0),
          attribute.data("howdy-choice", ""),
          attribute.disabled(!chosen(option.0)),
        ])
      }),
      [
        html.button(
          [
            class(clear_class()),
            attribute.type_("button"),
            attribute.aria_label(words.clear),
            attribute.data("howdy-select-clear", ""),
            attribute.hidden(values == []),
          ],
          [html.span([attribute.aria_hidden(True)], [text("×")])],
        ),
        html.div(
          [
            class(popover_class()),
            attribute.id(popover),
            attribute.popover("auto"),
            attribute.data("howdy-anchored", anchor_name(popover)),
          ],
          [
            search_list(
              id <> "-search",
              search,
              [],
              list.map(options, fn(option) {
                item(
                  [
                    attribute.data("value", option.0),
                    attribute.aria_selected(chosen(option.0)),
                  ],
                  [text(option.1)],
                )
              }),
              [attribute.aria_multiselectable(True)],
            ),
          ],
        ),
      ],
    ]),
  )
}

fn picker(
  words: Words,
  id: String,
  name: String,
  value: String,
  label: String,
  placeholder: String,
  search: String,
  attributes: List(Attribute(msg)),
  options: List(Element(msg)),
) -> Element(msg) {
  let popover = id <> "-popover"
  let #(shown, mark) = case value {
    "" -> #(placeholder, [attribute.data("placeholder", "")])
    _ -> #(label, [])
  }
  html.div([class(combobox_class()), attribute.data("howdy-select", "")], [
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
        attribute.attribute("popovertarget", popover),
        attribute.aria_haspopup("listbox"),
        attribute.data("howdy-select-trigger", ""),
        attribute.data("howdy-anchor", anchor_name(popover)),
        ..list.append(mark, attributes)
      ],
      [
        html.span(
          [
            class(value_class()),
            attribute.data("howdy-select-value", ""),
            attribute.data("howdy-placeholder", placeholder),
          ],
          [text(shown)],
        ),
      ],
    ),
    html.button(
      [
        class(clear_class()),
        attribute.type_("button"),
        attribute.aria_label(words.clear),
        attribute.data("howdy-select-clear", ""),
        attribute.hidden(value == ""),
      ],
      [html.span([attribute.aria_hidden(True)], [text("×")])],
    ),
    html.div(
      [
        class(popover_class()),
        attribute.id(popover),
        attribute.popover("auto"),
        attribute.data("howdy-anchored", anchor_name(popover)),
      ],
      [
        search_list(id <> "-search", search, [], options, []),
      ],
    ),
  ])
}

/// An option in a combobox. `selected` marks the one whose value is the
/// combobox's `value`.
pub fn option(
  value: String,
  selected selected: Bool,
  children children: List(Element(msg)),
) -> Element(msg) {
  item(
    [attribute.data("value", value), attribute.aria_selected(selected)],
    children,
  )
}

/// Every class this module uses, for `howdy/ui/export`.
pub fn classes() -> List(Class) {
  [
    command_class(),
    input_class(),
    list_class(),
    group_class(),
    heading_class(),
    item_class(),
    separator_class(),
    empty_class(),
    dialog_class(),
    combobox_class(),
    trigger_class(),
    value_class(),
    clear_class(),
    popover_class(),
    chips_class(),
    chip_class(),
    chip_remove_class(),
    chips_trigger_class(),
  ]
}

pub fn command_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.width(percent(100)),
    css.background(tokens.surface),
    css.color(tokens.text),
  ])
}

pub fn input_class() -> Class {
  css.class([
    css.width(percent(100)),
    css.padding_(tokens.space_3),
    css.border("0"),
    style.bordered_side("bottom"),
    css.background("transparent"),
    css.color(tokens.text),
    css.font_family(tokens.font_body),
    css.font_size(rem(0.875)),
    css.outline("none"),
    css.placeholder([css.color(tokens.text_muted)]),
  ])
}

pub fn list_class() -> Class {
  css.class([
    css.property("max-height", "18rem"),
    css.overflow_y("auto"),
    css.padding(rem(0.25)),
    css.property("scroll-padding", "0.25rem"),
  ])
}

pub fn group_class() -> Class {
  css.class([css.selector("[hidden]", [css.display("none")])])
}

pub fn heading_class() -> Class {
  css.class([
    css.padding_("0.375rem " <> tokens.space_2),
    css.font_size(rem(0.75)),
    css.font_weight("500"),
    css.color(tokens.text_muted),
  ])
}

pub fn item_class() -> Class {
  css.class([
    css.display("flex"),
    css.align_items("center"),
    css.gap(rem(0.5)),
    css.position("relative"),
    css.padding_("0.375rem " <> tokens.space_2),
    css.property("padding-inline-end", "2rem"),
    style.radius(tokens.radius_small),
    css.font_size(rem(0.875)),
    css.color(tokens.text),
    css.text_decoration("none"),
    css.cursor("pointer"),
    css.property("user-select", "none"),
    css.selector("[data-active]", [css.background(tokens.muted)]),
    css.selector("[hidden]", [css.display("none")]),
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

pub fn separator_class() -> Class {
  css.class([
    css.height(length.px(1)),
    css.margin_(tokens.space_1 <> " -" <> tokens.space_1),
    css.background(tokens.border),
  ])
}

pub fn empty_class() -> Class {
  css.class([
    css.padding_(tokens.space_6 <> " " <> tokens.space_2),
    css.text_align("center"),
    css.font_size(rem(0.875)),
    css.color(tokens.text_muted),
    css.selector("[hidden]", [css.display("none")]),
  ])
}

pub fn dialog_class() -> Class {
  css.class([
    css.width(percent(100)),
    css.property("max-width", "min(32rem, calc(100% - 2rem))"),
    css.property("margin-top", "15vh"),
    css.padding(rem(0.0)),
    css.overflow("hidden"),
    css.background(tokens.surface),
    style.bordered(),
    style.radius(tokens.radius_large),
    css.box_shadow("0 20px 50px -12px rgb(0 0 0 / 0.35)"),
    css.backdrop([css.background("rgb(0 0 0 / 0.5)")]),
  ])
}

pub fn combobox_class() -> Class {
  css.class([
    css.position("relative"),
    css.display("block"),
    css.width(percent(100)),
  ])
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
    style.disabled_look(),
    style.focus_ring(),
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

pub fn value_class() -> Class {
  css.class([
    css.overflow("hidden"),
    css.property("text-overflow", "ellipsis"),
    css.white_space("nowrap"),
    // Room for the clear button over the end of the trigger.
    css.property("padding-inline-end", "1.5rem"),
  ])
}

pub fn clear_class() -> Class {
  css.class([
    css.position("absolute"),
    css.property("inset-inline-end", "2.25rem"),
    css.property("top", "50%"),
    css.transform_("translateY(-50%)"),
    css.display("inline-flex"),
    css.align_items("center"),
    css.justify_content("center"),
    css.property("width", "1.5rem"),
    css.property("height", "1.5rem"),
    css.padding(rem(0.0)),
    css.border("0"),
    style.radius(tokens.radius_small),
    css.background("transparent"),
    css.color(tokens.text_muted),
    css.font_size(rem(1.0)),
    css.cursor("pointer"),
    css.hover([css.color(tokens.text), css.background(tokens.muted)]),
    style.focus_ring_offset("1px"),
    css.selector("[hidden]", [css.display("none")]),
  ])
}

pub fn popover_class() -> Class {
  css.class([
    css.inset("auto"),
    css.margin_("0.375rem 0"),
    css.property("position-area", "block-end span-inline-end"),
    css.property("position-try-fallbacks", "flip-block"),
    css.property("min-width", "anchor-size(width)"),
    css.padding(rem(0.0)),
    css.overflow("hidden"),
    css.background(tokens.surface),
    style.bordered(),
    style.radius(tokens.radius_medium),
    css.box_shadow("0 10px 30px -10px rgb(0 0 0 / 0.3)"),
  ])
}

/// The box around a multiple combobox's chips and button, drawn as the
/// field.
pub fn chips_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_wrap("wrap"),
    css.align_items("center"),
    css.gap(rem(0.25)),
    css.width(percent(100)),
    css.padding_(tokens.space_1),
    css.property("padding-inline-end", "3.75rem"),
    css.background(tokens.surface),
    style.bordered(),
    style.radius(tokens.radius_medium),
    css.selector(":has([aria-invalid=\"true\"])", [
      css.property("border-color", tokens.danger),
    ]),
    css.selector(":has(:disabled)", [css.property("opacity", "0.5")]),
  ])
}

pub fn chip_class() -> Class {
  css.class([
    css.display("inline-flex"),
    css.align_items("center"),
    css.gap(rem(0.125)),
    css.property("padding-block", "0.125rem"),
    css.property("padding-inline", tokens.space_2 <> " 0.125rem"),
    style.radius(tokens.radius_small),
    css.background(tokens.muted),
    css.color(tokens.text),
    css.font_size(rem(0.875)),
    css.line_height("1.5"),
    css.selector("[hidden]", [css.display("none")]),
  ])
}

pub fn chip_remove_class() -> Class {
  css.class([
    css.display("inline-flex"),
    css.align_items("center"),
    css.justify_content("center"),
    css.property("width", "1.25rem"),
    css.property("height", "1.25rem"),
    css.padding(rem(0.0)),
    css.border("0"),
    style.radius(tokens.radius_small),
    css.background("transparent"),
    css.color(tokens.text_muted),
    css.cursor("pointer"),
    css.hover([css.color(tokens.text), css.background(tokens.border)]),
    style.focus_ring_offset("1px"),
  ])
}

/// The button in a multiple combobox: it takes the rest of the row.
pub fn chips_trigger_class() -> Class {
  css.class([
    css.display("flex"),
    css.align_items("center"),
    css.justify_content("space-between"),
    css.gap(rem(0.5)),
    css.property("flex", "1 1 6rem"),
    css.property("min-width", "6rem"),
    css.padding_(tokens.space_1 <> " " <> tokens.space_2),
    css.background("transparent"),
    css.color(tokens.text),
    css.border("0"),
    style.radius(tokens.radius_small),
    css.font_family(tokens.font_body),
    css.font_size(rem(1.0)),
    css.line_height("1.5"),
    css.text_align("start"),
    css.cursor("pointer"),
    css.selector("[data-placeholder]", [css.color(tokens.text_muted)]),
    css.disabled([css.cursor("not-allowed")]),
    style.focus_ring(),
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
