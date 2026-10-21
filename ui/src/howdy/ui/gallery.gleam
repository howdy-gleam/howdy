//// A browsable reference of everything in howdy_ui, for development:
//// every component, block and theme preset, with examples drawn live
//// beside the code that drew them, the command that copies it, and its
//// full source.
////
//// ```gleam
//// howdy.new()
//// |> howdy.controller(gallery.controller(at: "/ui"))
//// ```
////
//// Open `/ui` and pick an entry. The theme menu redraws the gallery in any
//// preset, and the toggle switches light and dark. Mount it only in
//// development: it reads package sources from disk, as the command line
//// does.

import gleam/int
import gleam/list
import gleam/result
import gleam/string
import howdy/controller.{type Context, type Controller}
import howdy/cookie
import howdy/param
import howdy/query
import howdy/ui/badge
import howdy/ui/button
import howdy/ui/cli
import howdy/ui/gallery/examples.{type Example}
import howdy/ui/page
import howdy/ui/registry.{type Entry}
import howdy/ui/sidebar
import howdy/ui/style.{class}
import howdy/ui/theme.{type Themes}
import howdy/ui/theme/tokens
import howdy/ui/themes/green
import howdy/ui/themes/rose
import howdy/ui/themes/stone
import howdy/ui/themes/violet
import howdy/ui/themes/zinc
import howdy/ui/typography
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}
import sketch/css/length.{percent, rem}

/// The gallery, served under `path`.
pub fn controller(at path: String) -> Controller {
  let base = strip_slash(path)
  controller.new(path)
  |> controller.get("/", fn(ctx) { index(ctx, base) })
  |> controller.get("/:name", fn(ctx) {
    use name <- param.string(ctx, "name")
    entry_page(ctx, base, name)
  })
  |> controller.get("/:name/preview/:index", fn(ctx) {
    use name <- param.string(ctx, "name")
    use index <- param.int(ctx, "index")
    preview(ctx, name, index)
  })
}

// -- Themes ------------------------------------------------------------------

const presets = ["default", "zinc", "stone", "rose", "green", "violet"]

fn themes(preset: String) -> Themes {
  case preset {
    "zinc" -> zinc.themes()
    "stone" -> stone.themes()
    "rose" -> rose.themes()
    "green" -> green.themes()
    "violet" -> violet.themes()
    _ -> theme.default_themes()
  }
}

/// The theme's custom properties as an inline style, to preview a theme
/// inside a page drawn in another.
fn scoped(theme: theme.Theme) -> attribute.Attribute(msg) {
  let scheme = case theme.scheme {
    theme.Light -> "light"
    theme.Dark -> "dark"
  }
  theme.variables(theme)
  |> list.map(fn(pair) { pair.0 <> ":" <> pair.1 })
  |> list.prepend("color-scheme:" <> scheme)
  |> string.join(";")
  |> attribute.attribute("style", _)
}

// -- Pages -------------------------------------------------------------------

fn document(
  ctx: Context,
  title: String,
  preset: String,
  body: List(Element(msg)),
) {
  use mode <- cookie.string_or(ctx, "theme", default: "system")
  page.new(title <> " · howdy_ui")
  |> page.themes(themes(preset))
  |> page.theme(mode)
  |> page.body(body)
  |> page.respond(ctx)
}

fn shell(
  base: String,
  preset: String,
  current: String,
  heading: String,
  content: List(Element(msg)),
) -> Element(msg) {
  let link = fn(name, label) {
    sidebar.link(
      base <> "/" <> name <> "?theme=" <> preset,
      active: name == current,
      attributes: [class(nav_link_class())],
      children: [text(label)],
    )
  }
  let groups =
    registry.entries()
    |> list.chunk(fn(entry) { entry.category })
    |> list.map(fn(group) {
      let assert [first, ..] = group
      sidebar.group(
        first.category,
        list.map(group, fn(entry) { link(entry.name, title_case(entry.name)) }),
      )
    })
  sidebar.layout(
    collapsed: False,
    attributes: [],
    sidebar: sidebar.sidebar(
      "gallery-navigation",
      [attribute.aria_label("Entries")],
      [
        sidebar.header([
          html.a(
            [class(home_class()), attribute.href(base <> "?theme=" <> preset)],
            [text("howdy_ui " <> cli.version())],
          ),
        ]),
        sidebar.content(groups),
      ],
    ),
    main: [
      html.header([class(bar_class())], [
        html.div([class(group_class())], [
          button.sized(
            button.Ghost,
            button.Icon,
            [
              attribute.aria_label("Toggle navigation"),
              ..sidebar.trigger("gallery-navigation")
            ],
            [html.span([attribute.aria_hidden(True)], [text("☰")])],
          ),
          html.h1([class(heading_class())], [text(heading)]),
        ]),
        html.div([class(group_class())], [
          html.form([class(group_class()), attribute.method("get")], [
            html.label([attribute.for("gallery-theme"), class(muted_class())], [
              text("Theme"),
            ]),
            html.select(
              [
                class(theme_select_class()),
                attribute.id("gallery-theme"),
                attribute.name("theme"),
                attribute.attribute("onchange", "this.form.submit()"),
              ],
              list.map(presets, fn(name) {
                html.option(
                  [attribute.value(name), attribute.selected(name == preset)],
                  title_case(name),
                )
              }),
            ),
            html.noscript([], [
              button.sized_submit(button.Outline, button.Small, [], [
                text("Use"),
              ]),
            ]),
          ]),
          button.theme_toggle([text("Light / dark")], from: "light", to: "dark"),
        ]),
      ]),
      html.div([class(content_class())], content),
    ],
  )
}

fn index(ctx: Context, base: String) {
  use preset <- query.string_or(ctx, "theme", default: "default")
  let cards =
    registry.entries()
    |> list.chunk(fn(entry) { entry.category })
    |> list.map(fn(group) {
      let assert [first, ..] = group
      html.section([], [
        html.h2([class(section_class())], [text(first.category)]),
        html.div(
          [class(grid_class())],
          list.map(group, fn(entry) {
            html.a(
              [
                class(tile_class()),
                attribute.href(base <> "/" <> entry.name <> "?theme=" <> preset),
              ],
              [
                html.strong([class(tile_title_class())], [
                  text(title_case(entry.name)),
                ]),
                html.span([class(muted_class())], [
                  text(registry.summary(describe(entry))),
                ]),
              ],
            )
          }),
        ),
      ])
    })
  document(ctx, "Gallery", preset, [
    shell(base, preset, "", "Gallery", [
      typography.p([
        text(
          "Every component, block and theme preset in howdy_ui. Each page draws its examples beside their code, and shows the command that copies it into your project.",
        ),
      ]),
      ..cards
    ]),
  ])
}

fn entry_page(ctx: Context, base: String, name: String) {
  use preset <- query.string_or(ctx, "theme", default: "default")
  case registry.find(name) {
    Error(Nil) -> controller.status(ctx, 404)
    Ok(entry) -> {
      let source = cli.template(entry.module) |> result.unwrap("")
      let dependencies = registry.dependencies(source)
      let content =
        list.flatten([
          [
            typography.p([text(registry.description(source))]),
            html.div([class(group_class())], [
              badge.badge(badge.Secondary, [], [
                text(registry.kind_name(entry.kind)),
              ]),
              typography.muted("import " <> entry.module),
            ]),
            code("gleam run -m howdy/ui add " <> entry.name),
            case dependencies {
              [] -> element.none()
              deps -> {
                let links =
                  list.map(deps, fn(dep) {
                    typography.link(base <> "/" <> dep <> "?theme=" <> preset, [
                      text(title_case(dep)),
                    ])
                  })
                  |> list.intersperse(text(", "))
                typography.p(
                  list.flatten([
                    [text("Copying it also copies ")],
                    links,
                    [text(".")],
                  ]),
                )
              }
            },
          ],
          examples_view(base, preset, entry),
          [
            html.details([class(source_class())], [
              html.summary([], [text("Full source of " <> entry.module)]),
              code(source),
            ]),
          ],
        ])
      document(ctx, title_case(name), preset, [
        shell(base, preset, name, title_case(name), content),
      ])
    }
  }
}

/// Blocks that fill the screen are drawn in a frame of their own.
const full_screen = ["app_shell", "sign_in", "sign_up"]

fn examples_view(
  base: String,
  preset: String,
  entry: Entry,
) -> List(Element(msg)) {
  let source = cli.template("howdy/ui/gallery/examples") |> result.unwrap("")
  list.index_map(examples.for(entry.name), fn(example: Example(msg), index) {
    let drawn = case entry.kind, list.contains(full_screen, entry.name) {
      registry.ThemePreset, _ -> {
        let themes = themes(entry.name)
        html.div([class(pair_class())], [
          html.div([class(swatch_class()), scoped(themes.default)], [
            example.view(),
          ]),
          ..list.map(themes.alternatives, fn(alternative) {
            html.div([class(swatch_class()), scoped(alternative)], [
              example.view(),
            ])
          })
        ])
      }
      _, True ->
        html.iframe([
          class(frame_class()),
          attribute.title(example.title),
          attribute.src(
            base
            <> "/"
            <> entry.name
            <> "/preview/"
            <> int.to_string(index)
            <> "?theme="
            <> preset,
          ),
        ])
      _, False -> html.div([class(preview_class())], [example.view()])
    }
    let shown = case entry.kind {
      registry.ThemePreset ->
        "import howdy/ui/themes/"
        <> entry.name
        <> "\n\npage.new(\"Orders\")\n|> page.themes("
        <> entry.name
        <> ".themes())"
      _ -> function_body(source, example.function)
    }
    html.section([class(example_class())], [
      html.h2([class(section_class())], [text(example.title)]),
      drawn,
      code(shown),
    ])
  })
}

fn preview(ctx: Context, name: String, index: Int) {
  use preset <- query.string_or(ctx, "theme", default: "default")
  case list.drop(examples.for(name), index) {
    [example, ..] -> document(ctx, title_case(name), preset, [example.view()])
    [] -> controller.status(ctx, 404)
  }
}

fn code(source: String) -> Element(msg) {
  html.pre([class(code_class()), attribute.tabindex(0)], [
    html.code([], [text(source)]),
  ])
}

/// The body of `pub fn name()` in `source`, without its signature and
/// closing brace, and indented as it would be at the top level.
fn function_body(source: String, name: String) -> String {
  source
  |> string.split("\n")
  |> list.drop_while(fn(line) {
    !string.starts_with(line, "pub fn " <> name <> "(")
  })
  |> list.drop(1)
  |> list.take_while(fn(line) { line != "}" })
  |> list.map(fn(line) {
    case line {
      "  " <> rest -> rest
      _ -> line
    }
  })
  |> string.join("\n")
}

fn describe(entry: Entry) -> String {
  cli.template(entry.module)
  |> result.map(registry.description)
  |> result.unwrap("")
}

fn title_case(name: String) -> String {
  case string.split(name, "_") {
    [first, ..rest] -> string.join([string.capitalise(first), ..rest], " ")
    [] -> name
  }
}

fn strip_slash(path: String) -> String {
  case string.ends_with(path, "/") && path != "/" {
    True -> strip_slash(string.drop_end(path, 1))
    False ->
      case path {
        "/" -> ""
        _ -> path
      }
  }
}

// -- Styles ------------------------------------------------------------------

/// Every class this module uses.
pub fn classes() -> List(Class) {
  [
    home_class(),
    nav_link_class(),
    bar_class(),
    group_class(),
    heading_class(),
    content_class(),
    section_class(),
    grid_class(),
    tile_class(),
    tile_title_class(),
    muted_class(),
    theme_select_class(),
    example_class(),
    preview_class(),
    frame_class(),
    pair_class(),
    swatch_class(),
    code_class(),
    source_class(),
  ]
}

// Most presets differ from each other only in their primary colour, so the
// gallery's own chrome carries it: otherwise switching preset on a page
// without buttons or links would appear to do nothing.

pub fn home_class() -> Class {
  css.class([
    css.color(tokens.primary),
    css.font_weight("600"),
    css.text_decoration("none"),
  ])
}

pub fn nav_link_class() -> Class {
  css.class([
    css.selector("[aria-current=\"page\"]", [
      css.property("box-shadow", "inset 3px 0 0 " <> tokens.primary),
    ]),
  ])
}

pub fn bar_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_wrap("wrap"),
    css.align_items("center"),
    css.justify_content("space-between"),
    css.gap(rem(1.0)),
    css.padding_(tokens.space_3 <> " " <> tokens.space_6),
    css.property("border-bottom", "1px solid " <> tokens.border),
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
  css.class([css.margin(rem(0.0)), css.font_size(rem(1.25))])
}

pub fn content_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(1.5)),
    css.padding(rem(1.5)),
    css.property("max-width", "56rem"),
  ])
}

pub fn section_class() -> Class {
  css.class([
    css.margin_("0 0 " <> tokens.space_3),
    css.font_size(rem(1.0)),
    css.font_weight("600"),
  ])
}

pub fn grid_class() -> Class {
  css.class([
    css.display("grid"),
    css.gap(rem(0.75)),
    css.grid_template_columns("repeat(auto-fill, minmax(15rem, 1fr))"),
  ])
}

pub fn tile_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(0.25)),
    css.padding(rem(1.0)),
    css.background(tokens.surface),
    css.color(tokens.text),
    css.border("1px solid " <> tokens.border),
    css.property("border-radius", tokens.radius_medium),
    css.text_decoration("none"),
    css.hover([css.property("border-color", tokens.primary)]),
    css.focus_visible([
      css.outline("2px solid " <> tokens.focus),
      css.property("outline-offset", "2px"),
    ]),
  ])
}

pub fn tile_title_class() -> Class {
  css.class([css.color(tokens.primary)])
}

pub fn muted_class() -> Class {
  css.class([css.font_size(rem(0.875)), css.color(tokens.text_muted)])
}

pub fn theme_select_class() -> Class {
  css.class([
    css.padding_(tokens.space_1 <> " " <> tokens.space_2),
    css.background(tokens.surface),
    css.color(tokens.text),
    css.border("1px solid " <> tokens.border),
    css.property("border-radius", tokens.radius_small),
    css.font_family(tokens.font_body),
  ])
}

pub fn example_class() -> Class {
  css.class([
    css.display("flex"),
    css.flex_direction("column"),
    css.gap(rem(0.75)),
  ])
}

pub fn preview_class() -> Class {
  css.class([
    css.padding(rem(1.5)),
    css.background(tokens.background),
    css.border("1px solid " <> tokens.border),
    css.property("border-radius", tokens.radius_medium),
  ])
}

pub fn frame_class() -> Class {
  css.class([
    css.width(percent(100)),
    css.property("height", "36rem"),
    css.border("1px solid " <> tokens.border),
    css.property("border-radius", tokens.radius_medium),
    css.background(tokens.background),
  ])
}

pub fn pair_class() -> Class {
  css.class([
    css.display("grid"),
    css.gap(rem(0.75)),
    css.grid_template_columns("repeat(auto-fit, minmax(18rem, 1fr))"),
  ])
}

pub fn swatch_class() -> Class {
  css.class([
    css.padding(rem(1.0)),
    css.background(tokens.background),
    css.color(tokens.text),
    css.border("1px solid " <> tokens.border),
    css.property("border-radius", tokens.radius_medium),
  ])
}

pub fn code_class() -> Class {
  css.class([
    css.margin(rem(0.0)),
    css.padding(rem(1.0)),
    css.overflow_x("auto"),
    css.background(tokens.muted),
    css.color(tokens.text),
    css.property("border-radius", tokens.radius_medium),
    css.font_family(tokens.font_mono),
    css.font_size(rem(0.8125)),
    css.line_height("1.5"),
    css.property("font-variant-ligatures", "none"),
    css.focus_visible([
      css.outline("2px solid " <> tokens.focus),
      css.property("outline-offset", "2px"),
    ]),
  ])
}

pub fn source_class() -> Class {
  css.class([
    css.selector(" > summary", [
      css.margin_("0 0 " <> tokens.space_2),
      css.color(tokens.text_muted),
      css.cursor("pointer"),
    ]),
  ])
}
