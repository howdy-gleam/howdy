# howdy_ui

Pages, themes and live server components for [howdy](https://github.com/mikeyjones/howdy/blob/v2.1.1/README.md), built
on [Lustre](https://hexdocs.pm/lustre) and [Sketch](https://hexdocs.pm/sketch).

```sh
gleam add howdy_ui
```

It is a separate package so that howdy itself stays free of Lustre and
Sketch. Apps that only serve JSON never pull them in.

## Pages

`howdy/ui/page` renders a Lustre element as a full HTML document. The head
carries the theme variables, base styles and the CSS for every component
in the body.

```gleam
import howdy/cookie
import howdy/ui
import howdy/ui/page
import lustre/element.{text}

controller.new("/")
|> controller.get("/", fn(ctx) {
  use theme <- cookie.string_or(ctx, "theme", default: "system")

  page.new("Orders")
  |> page.theme(theme)
  |> page.body([
    ui.container([], [
      ui.h1("Orders"),
      ui.p([text("Nothing yet.")]),
    ]),
  ])
  |> page.respond(ctx)
})
```

`page.theme` sets the `data-theme` attribute on the root element. A name
the page does not offer, such as the `"system"` default above, is ignored
and the browser's colour scheme preference decides. That means the first
paint is already in the right theme; no flash.

Use `page.render` or `page.to_string` to get the document without a
response, and `page.head` to add your own elements to the head.

### Serving the CSS as a file

Embedding needs no extra route and is fine for development. To serve the
CSS as one file instead, mount the development route and link it:

```gleam
howdy.new()
|> howdy.controller(pages())
|> howdy.controller(ui.stylesheet(at: "/assets/ui.css", themes: theme.default_themes()))
```

```gleam
page.new("Orders")
|> page.stylesheet(at: "/assets/ui.css")
```

The route serves every class registered so far with an ETag and
`cache-control: no-cache`, so browsers revalidate once per page load and
see new classes as soon as they exist. It is meant for development: it only
knows classes that have been rendered on that node.

To publish, write a static file from a known list of classes. See
[Publishing](#publishing).

## Themes

A theme is a record in `howdy/ui/theme`. Every component reads its colours,
fonts and radii through CSS variables defined by the theme, so changing a
theme changes every element.

```gleam
import howdy/ui/theme.{Colors}

pub fn brand() -> theme.Theme {
  theme.light()
  |> theme.named("brand")
  |> theme.colors(fn(c) { Colors(..c, primary: "#0f766e", on_primary: "#fff") })
}

page.new("Orders")
|> page.themes(theme.themes(default: brand(), alternatives: [theme.dark()]))
```

- The default theme goes on `:root`.
- Every theme is also written under `[data-theme="name"]`.
- With no attribute set, the first alternative whose scheme differs from the
  default is applied through `prefers-color-scheme`.
- Each theme sets `color-scheme`, so form controls and scrollbars follow.

Adding a field to `Colors`, `Font` or `Radius` is a compile error until every
theme supplies it. A test in this package checks every token in
`howdy/ui/theme/tokens` is defined by every built-in theme.

### Presets

`howdy/ui/themes` has five presets, each a light and a dark theme: `zinc`
and `stone` (neutral and warm greys with a near-black primary), and `rose`,
`green` and `violet`. Every text colour in every theme, built-in or preset,
meets WCAG AA contrast against the surfaces it sits on, and focus rings
3:1 against the page; a test checks it. Chart colours are checked for
colour-vision-deficiency separation against each theme's surfaces.

```gleam
import howdy/ui/themes/violet

page.new("Orders")
|> page.themes(violet.themes())
```

`gleam run -m howdy/ui add violet` copies one to adjust.

`ui.theme_toggle` renders a button that switches the document between two
named themes in place and stores the choice in a `theme` cookie:

```gleam
ui.theme_toggle([text("Toggle theme")], from: "light", to: "dark")
```

## Components

Each component lives in its own module under `howdy/ui`, and `howdy/ui`
re-exports them. Every one is a Sketch class built from tokens.

| Module | Components |
| --- | --- |
| `heading`, `typography` | `h1`–`h4`, `p`, `muted`, `link`, `prose` (styles plain elements such as rendered Markdown, in three sizes) |
| `button` | `button` in `Primary`, `Secondary`, `Outline`, `Ghost`, `Link` and `Danger`; `sized_button` in `ExtraSmall`, `Small`, `Medium`, `Large`, `Icon`, `IconExtraSmall`, `IconSmall` and `IconLarge`; `submit_button` for one that submits its form (don't pass `type="submit"` to `button`: a page and a live view resolve two types differently); `theme_toggle` |
| `input` | `input`, `textarea`, `native_select`, `label` |
| `field` | `field`, `field_description`, `field_error`, `fieldset` |
| `checkbox` | `checkbox`, `radio`, `choice` (a control with its label), `radio_group` |
| `layout` | `container`, `stack`, `row`, `separator` |
| `card` | `card` (or `card.sized` for `Compact`), `card_header`, `card_title`, `card_description`, `card_action`, `card_content`, `card_footer` |
| `badge` | `badge` in `Primary`, `Secondary`, `Outline` and `Danger` |
| `alert` | `alert` in `Info` and `Danger`, `alert_title`, `alert_description` |
| `table` | `table`, `table_caption`, `table_header`, `table_body`, `table_footer`, `table_row`, `table_head`, `table_cell` |
| `loading` | `skeleton`, `spinner` |
| `dialog` | `dialog`, `alert_dialog`, `sheet`, `dialog_trigger`, `dialog_close`, `dialog_header`, `dialog_title`, `dialog_description`, `dialog_footer` |
| `drawer` | `drawer`, `drawer_trigger`: a bottom panel dragged by its handle, with `drawer.snap_points` |
| `direction` | `direction` for a right-to-left part of a page; `page.direction` for the whole page |
| `popover` | `popover`, `popover_trigger`, `popover_close` |
| `tooltip` | `tooltip`, `tooltip_trigger` |
| `menu` | `menu`, `menu_trigger`, `menu_item`, `menu_link`, `menu_checkbox_item`, `menu_radio_group`, `menu_radio_item`, `menu_submenu`, `menu_label`, `menu_separator` |
| `tabs` | `tabs`, `tab`; `tabs.styled` for `Vertical` and the underlined `Line` look |
| `accordion` | `accordion`, `accordion_item`, `collapsible` |
| `select` | `select`, `select_item`, `select_group` (a styled list; `native_select` is the browser's own) |
| `toast` | `toast_region`, `toast` in `Info`, `Success`, `Loading` and `Danger`, `toast_title`, `toast_description`, `toast_close`; `toast.duration`, `toast.persistent`; `toast.queue` for a live view's model: the browser reports when a toast fades or is held open, so cleanup never removes one being read |
| `sidebar` | `sidebar_layout`, `sidebar`, `sidebar_trigger`, `sidebar_header`, `sidebar_content`, `sidebar_footer`, `sidebar_group`, `sidebar_link`, `sidebar_button`; `sidebar.styled_layout` for a `Rail` or `Floating`/`Inset` sidebar, `sidebar.icon_link`, `sidebar.submenu` |
| `pagination` | `pagination`; `pagination.live_pagination` for live views |
| `command` | `command`, `command_group`, `command_item`, `command_link`, `command_empty`, `command_dialog` (with a ⌘K shortcut), `combobox`, `multiple_combobox` (chips, one form field per value; `live.on_values` in a live view), `combobox_option` |
| `calendar` | `calendar.new(...)` built up with `selected`, `range`, `multiple`, `months`, `today`, `disabled`, `sunday_first`, `locale`, `navigation` and `name`, shown with `view` or as a date `picker` |
| `data_table` | `data_table.new(columns, rows)` with `sort`, `selectable`, `hide`, `empty` and `caption`; `columns_menu` |
| `chart` | `chart.bar`, `line`, `area`, `pie`, `donut`, `radial` and `radar`, shown with `view` |
| `avatar` | `avatar` with initials behind the picture, `avatar_initials` |
| `progress` | `progress`, `progress_indeterminate` |
| `effects` | `scroll_fade`, `shimmer` |
| `chat` | `chat_conversation`, `chat_message`, `chat_bubble`, `chat_note`; `remember`, `start_at`, `on_older` (load history as the reader scrolls back, keeping their place), `styled_bubble`, `tinted_note`, `status`, `jump`, `reactions`, `reaction` |
| `attachment` | `attachment` (uploading, processing, failed or done, with a thumbnail and actions), `attachment_group`; `attachment.styled` for `Compact` and `Tile` |
| `kbd` | `kbd`, `shortcut` |
| `button_group` | `button_group` |
| `toggle` | `toggle`, `toggle_group` (single or multiple) |
| `switch`, `slider` | `switch`, `slider` (the browser's own controls, themed); `slider.range` with two thumbs, `slider.thumbs` with any number, either way up; `slider.vertical` |
| `input_group` | `input_group`, `input_group_input`, `input_group_addon`; `input_group.textarea`, `block_start`, `block_end` |
| `input_otp` | `input_otp`: one input drawn as a box per character; `input_otp.grouped` for `1234-5678` |
| `aspect_ratio`, `scroll_area` | `aspect_ratio`, `scroll_area` |
| `resizable` | `resizable_group`, `resizable_panel`, `resizable_handle`; `resizable.minimum`, `collapsible`, `remember` |
| `context_menu` | `context_menu_area`, `context_menu`, with `menu_item`s |
| `menubar` | `menubar`, `menubar_button`, with `menu`s |
| `hover_card` | `hover_card`, `hover_card_trigger` |
| `breadcrumb` | `breadcrumb`, `breadcrumb_link`, `breadcrumb_page`, `breadcrumb_ellipsis` |
| `navigation_menu` | `navigation_menu`, `navigation_link`, `navigation_panel`, `navigation_panel_link` |
| `carousel` | `carousel`, `carousel_slide`; `carousel.styled` for `Vertical` and looping, `carousel.autoplay` (with a pause button, still for reduced motion), `carousel.on_change` |
| `item` | `item_group`, `item`, `item_link` |
| `empty` | `empty` |
| `questionnaire` | `questionnaire.question`s asked one at a time with back, skip and next, checked as they go; works as a plain form or in a live view |
| `uploader` | `uploader.new(name:, start:)` built up with `multiple`, `accept`, `max_size`, `required`, `layout`, `stored`, `id` and `words`, shown with `view`: drop or choose files, which the browser sends straight to storage with progress, posting each file's key; `file_size`, `describe` |
| `rich_text` | `rich_text.new(name:)` built up with `value`, `placeholder`, `tools`, `mentions(trigger:, kind:, search:)`, `attachments(start:, url:)`, `accept`, `max_size`, `required`, `disabled`, `invalid`, `id` and `words`, shown with `view`: a ProseMirror editor posting its document as JSON; `field`, `not_empty`, `max_length` and `suggestions_to_json` on the server. `howdy/ui/rich_text/document` decodes, stores and draws documents. Mount `ui.rich_text()` |

`calendar`, `data_table`, `chart`, `uploader` and `rich_text` are builders with several
options, so use them from their own modules rather than through `howdy/ui`.

Controls follow their native state. `attribute.disabled(True)` dims them
and `attribute.aria_invalid("true")` gives them the danger colour, so a form
is wired for assistive technology and styled by the same attributes:

```gleam
ui.field([], [
  ui.label([attribute.for("email")], [text("Email")]),
  ui.input([
    attribute.id("email"),
    attribute.aria_invalid("true"),
    attribute.aria_describedby("email-error"),
  ]),
  ui.field_error([attribute.id("email-error")], [text("Enter an email address.")]),
])
```

### Words and languages

Everything the components say, from a pagination's "Previous" to a toast's
close button, is in one `howdy/ui/words.Words` record. Components that are
plain functions take it as their first argument. Those built step by step
take it with a `words` step, and speak English without one:

```gleam
let w = words.translated(i18n.new(locale.to_string(l)))  // or words.english()

ui.pagination(w, current: 3, total: 12, href: page_href)
data_table.new(columns, rows) |> data_table.words(w)
calendar.new("due", year: 2026, month: 10) |> calendar.locale(w.calendar)
```

`translated` covers Arabic, Chinese, Dutch, English, French, German,
Italian, Japanese, Polish, Portuguese and Spanish. Numbers, month and
weekday names, and the first day of the week come from CLDR for 46
locales. The words outside English were machine translated and await
review. Change any of them with a record update:
`Words(..words.english(), dismiss: "Close")`. For right-to-left
languages, set `page.direction(direction.of(l))`.

### Interactive components

Dialogs, popovers, menus, tooltips, tabs, accordions and selects are built
on what the browser already does: `<dialog>` opened by an invoker command,
the popover API, CSS anchor positioning and `<details>`. The browser keeps
focus inside a modal, closes things on Escape or an outside click, puts
floating panels above everything else and returns focus afterwards.

A trigger and what it opens are tied by id. The trigger functions return
attributes, so any button can open one:

```gleam
ui.button(Outline, ui.menu_trigger("account"), [text("Account")]),
ui.menu("account", [], [
  ui.menu_item([event.on_click(OpenProfile)], [text("Profile")]),
  ui.menu_separator(),
  ui.menu_link("/sign-out", [], [text("Sign out")]),
])
```

`howdy/ui/behaviour` is a small script for what the browser does not do:
arrow keys and typeahead in menus and selects, arrow keys between tabs,
tooltips on hover and focus, and fallbacks for browsers without invoker
commands or anchor positioning. Every page includes it. It listens on the
document and follows events into live views' shadow roots, so a widget
inside a live view works without a round trip to the server.

The browser owns whether something is open and which tab or option is
selected. A live view that wants to know listens for the native events:
`close` on a dialog, `toggle` on a popover or accordion item, `change` on a
select's hidden input, or `click` on a tab or menu item. Keep a trigger and
its target in the same tree: both in the page, or both in one live view.

A live view hears the value of a select, combobox or calendar with
`live.on_value`, on any element around the control:

```gleam
html.div([live.on_value("status", FilterStatus)], [
  ui.combobox(words: w, id: "status", name: "status", ...),
])
```

### Charts

Charts are drawn on the server: lines, areas and gridlines as SVG, and text,
dots, columns and readouts as HTML over it, so type stays the same size at
any width. Series take the theme's chart colours, `chart_1` to `chart_5`, in
order; the built-in themes' five pass colour-vision-deficiency separation
checks against their own surfaces. Hovering over or focusing a label shows
every series' value there, and "Show data" opens the numbers as a table, so
no value depends on colour or a mouse. None of it needs a script.

### Blocks

Blocks are whole screens and cards built from the components:
`howdy/ui/blocks/app_shell` (a sidebar, a top bar and the page),
`stat_card`, `sign_in` and `sign_up`. Use them from the package, or copy
one with `add` to make it your own; see below.

`examples/gallery` builds an application from them: a dashboard with
charts and a live orders table, a live chat whose replies stream in, and
sign-in and sign-up screens with server-side validation.

### Chat

`howdy/ui/chat` lays a conversation out from the bottom, so it stays on the
newest message as messages arrive or a reply streams in, and keeps its
place when you scroll back to read; the browser does this, with no script.
It is a `log` for screen readers. Pair it with `avatar`, `attachment` and
`shimmer` for a reply being written.

### The gallery

`howdy/ui/gallery` is a browsable reference of everything here: each
component, block and theme preset, its examples drawn beside the code that
drew them, the command that copies it, and its full source. It is a
development tool, not part of the package's API: it is an internal module,
left out of the documentation, and it reads package sources from disk.
Mount it in development only:

```gleam
howdy.new()
|> howdy.controller(gallery.controller(at: "/ui"))
```

A menu redraws the gallery in any theme preset, and a toggle switches light
and dark.

### Making a component your own

Copy a component into your project and edit it, the way shadcn does:

```sh
gleam run -m howdy/ui init --theme=zinc
gleam run -m howdy/ui list
gleam run -m howdy/ui add button layout
```

- `init` makes `src/<app>/ui`, writes `all.gleam` there, and with
  `--theme=<name>` copies a theme preset. It checks the project depends on
  `lustre` and `sketch`, which copies import directly.
- `list` shows every component, block and theme by category;
  `search <words>` finds them; `view <name>` shows what one depends on and
  its source.
- `add` writes `src/<app>/ui/button.gleam` and `layout.gleam`: the source
  the package ships, with a header saying where it came from. Most
  components depend only on the package's core modules, so you can change
  anything in them; a few build on another, as `context_menu` and
  `menubar` do on `menu`, and `add` copies that too.
- Adding a block also adds the components it uses, and points its imports
  at those copies, so the block is built from your versions. A copy you
  have already edited is kept, and the new block uses it.
- `diff button` shows how a copy has drifted from the version it came
  from, or what a newer package version changed. `add` shows it too
  instead of overwriting a copy that differs.

Options: `--to=<dir>` puts copies elsewhere, `--force` overwrites copies
you have edited, `--dry-run` shows what would change without changing
anything, and `--install` runs `gleam add` for any package the copies need
that the project lacks.

`add` regenerates `all.gleam`, which lists the classes of every module in
the directory that has a `classes` function. Hand that list to the export
when publishing:

```gleam
export.new(theme.default_themes())
|> export.classes(my_app/ui/all.classes())
```

### Registries

The catalogue is data: `gleam run -m howdy/ui registry` writes it to
`registry/`, as `index.json`, one `<name>.json` per entry holding its
source and dependencies, and an `llms.txt` index for tools and coding
assistants.

Publish entries of your own the same way, serve the directory, and install
from it by URL or path:

```sh
gleam run -m howdy/ui add invoice_table --registry=https://ui.example.com/r
gleam run -m howdy/ui list --registry=./shared/ui-registry
```

An entry in another registry may depend on built-in ones, which are copied
alongside it and its imports pointed at them.

A registry URL must be `https://`: what it serves is code that runs in your
project, so it is not fetched over a connection that could be altered in
transit. Pass `--insecure` to accept that for a plain `http://` registry,
such as one on your own machine.

### Writing one from scratch

Keep the classes in a module with a `classes` function, build each from
`howdy/ui/theme/tokens`, and attach it with `ui.class`. Never name a colour
directly; use a token so the element follows the theme.

```gleam
// src/my_app/ui/badge.gleam
import howdy/ui/style.{class}
import howdy/ui/theme/tokens
import lustre/element.{type Element, text}
import lustre/element/html
import sketch/css.{type Class}

pub fn badge(content: String) -> Element(msg) {
  html.span([class(badge_class())], [text(content)])
}

pub fn classes() -> List(Class) {
  [badge_class()]
}

pub fn badge_class() -> Class {
  css.class([
    css.background(tokens.primary),
    css.color(tokens.on_primary),
    css.property("border-radius", tokens.radius_small),
  ])
}
```

Put it in the same directory as your copied components and the next `add`
includes it in `all.gleam`.

Class names are content hashes, computed in the calling process. The CSS
for each distinct class is rendered once and kept in an ETS table owned by
a supervised process in the `howdy_ui` application. Gleam starts it before
running your entry point; direct Erlang callers also start it automatically
on first cache access. After startup, rendering reads and writes ETS directly
without waiting on the owner process. Pages and
live views include the CSS for you. Anywhere else, put `ui.styles()` in the
document after the elements it styles.

Stopping the application clears the cache. If the owner crashes, its supervisor
restarts it with an empty cache and subsequent renders register their classes
again. A render in progress during that crash can fail; recovery does not replay
it automatically. Startup failures are reported rather than leaving callers
waiting for an owner that never started.

## Live components

A Lustre server component keeps its `init`, `update` and `view` on the
server. The browser runs a thin client that sends events up a WebSocket and
applies DOM patches that come back. `howdy/ui/live` turns one into a howdy
route:

```gleam
import howdy/ui/live

controller.new("/counter")
|> controller.get("/", fn(ctx) { live.serve(ctx, counter.app(), with: 0) })
```

and mounts it in a page:

```gleam
page.new("Counter")
|> page.live
|> page.body([live.mount("/counter")])
|> page.respond(ctx)
```

`page.live` includes the Lustre client runtime. The socket route goes through
guards and middleware like any other, so authentication works the same as for
`howdy/websocket`: read a cookie or query parameter, since browsers cannot set
handshake headers.

- `live.serve` starts one runtime per connection and shuts it down when the
  socket closes.
- `live.start` at boot returns a runtime that outlives connections, and
  `live.serve_shared` attaches sockets to it. Every client sees the same
  model. `live.dispatch` sends it a message from anywhere.
- `live.socket` and `live.socket_shared` return the plain `howdy/websocket`
  builder so you can add an `on_close` of your own before upgrading.

The component renders into a shadow root, so its view is wrapped to carry
a `<style>` node with the CSS for exactly the classes it used. It is styled
whether the page embeds, links the development route, or links a published
file, and it needs no setup. Theme variables are inherited from the page,
so a live view switches theme with the rest of the document.

### Live links

A live link moves between live pages without reloading. Mount one
`live.outlet` in place of a `live.mount`, and link with `live.link`:

```gleam
fn layout(ctx, mount mount: String) {
  page.new("Shop")
  |> page.live
  |> page.body([
    live.link(to: "/", mount: "/live/home", children: [text("Home")]),
    live.link(to: "/orders", mount: "/live/orders", children: [text("Orders")]),
    live.outlet(mount),
  ])
  |> page.respond(ctx)
}

controller.new("/")
|> controller.get("/", fn(ctx) { layout(ctx, mount: "/live/home") })
|> controller.get("/orders", fn(ctx) { layout(ctx, mount: "/live/orders") })
```

A click connects the outlet to the link's socket route and puts `href` in
the address bar. The old view stays on screen until the new one arrives, and
everything outside the outlet, including other live components, is left
alone. Back and forward swap the outlet too.

- `href` is what a reload, a bookmark, a new tab or a browser without
  JavaScript loads, so it must serve the page with that view in the outlet.
- Modified clicks, middle clicks, `target` links and links to other origins
  behave as plain links, as does every live link on a page with no outlet.
- Links work inside live views as well as in the page. `live.navigate`
  returns the attributes for an `<a>` you style yourself.
- Put `live.title("Orders")` in a view to rename the document when the view
  mounts.
- After a click the page scrolls to the top and focus moves to the outlet.
- Each swap starts a fresh runtime, so view state does not carry across.

`page.live` includes the script. If you render the document yourself, add
`live.script()` after `server_component.script()`.

In `howdy/testing` there is no socket to upgrade, so a live route answers
`426`. Test the app's `init`, `update` and `view` directly, or start a
runtime with `live.start` and register your own subject as the client, as
`test/live_test.gleam` does.

See `examples/live` for a page with a private and a shared counter, and
live links between two views.

## Publishing

For a published site, write the CSS once as a static file, minified, from
the built-in components and the classes in your own `all.gleam`. Add a script module and
run it whenever the styles change:

```gleam
// src/tasks/css.gleam
import howdy/ui/export
import howdy/ui/theme
import my_app/ui/all

pub fn main() {
  let assert Ok(Nil) =
    export.new(theme.default_themes())
    |> export.classes(all.classes())
    |> export.write(to: "priv/static/ui.css")
}
```

```sh
gleam run -m tasks/css
```

The output is deterministic for the same ordered class list, independent of
which pages were rendered beforehand. Built-in classes come first, followed by
classes in the order passed to `export.classes`; duplicate classes keep their
first position. Choose this order deliberately because equally specific rules
later in the stylesheet win. Export uses an isolated stylesheet and does not
populate the runtime registry.

CSS a Sketch class cannot carry, such as the `@keyframes` behind spinners,
skeletons and toasts, is registered by name with `style.rule` when the
component is drawn and written once per document by pages, live views and
the development stylesheet. The built-in rules are exported after the
classes; a copied or custom component that registers its own passes them
with `export.rules(my_component.rules())`.

Minification preserves descendant selectors such as `div :hover`. CSS containing
escapes, comments or URLs is left unchanged rather than risking a tokenization
change; such exports may retain whitespace.

Serve the file with `howdy/static` and a long cache lifetime, and link it with whatever
cache-busting you use for other assets:

```gleam
howdy.controller(
  static.new(from: "priv/static")
  |> static.at("/assets")
  |> static.max_age(seconds: 31_536_000)
  |> static.build,
)
```

```gleam
page.stylesheet(page, at: "/assets/ui.css?v=" <> my_app.version)
```

Live components carry their own CSS, so they are unaffected by what the
file contains.

## Developing

This package lives in the howdy repository and depends on howdy by path, so
a change to both lands in one commit. Before publishing, replace the path
dependency in `gleam.toml` with a version range, since `gleam publish`
rejects path dependencies.

```sh
cd ui
gleam test
```

The interactive behaviour is tested in a real browser. With the gallery
running (`cd examples/gallery && gleam run`), drive Chromium through its
DevTools protocol; it needs Node 22 or later and nothing else:

```sh
node ui/browser_test/run.mjs          # every test
node ui/browser_test/run.mjs drawer   # the ones whose name contains "drawer"
```

Most tests open a component's gallery preview. The live ones use the
gallery's `/lab` page, a live view that shows the server's view of each
component beside it, and `/survey`, a questionnaire posted as a plain form.
