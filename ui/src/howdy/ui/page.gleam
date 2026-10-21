//// Whole HTML documents from Lustre elements, with the theme applied
//// before first paint.
////
//// ```gleam
//// import howdy/cookie
//// import howdy/ui
//// import howdy/ui/page
////
//// controller.get("/", fn(ctx) {
////   use theme <- cookie.string_or(ctx, "theme", default: "system")
////
////   page.new("Orders")
////   |> page.theme(theme)
////   |> page.body([ui.h1("Orders"), ui.p([element.text("Nothing yet.")])])
////   |> page.respond(ctx)
//// })
//// ```
////
//// The head carries the theme variables, base styles and the CSS for every
//// `howdy/ui` component used in the body. By default that CSS is embedded
//// in the page. To serve it as a file instead, mount `ui.stylesheet` in
//// development or write one with `howdy/ui/export` for publishing, and
//// link it with `stylesheet`. Use `live` to add the Lustre client runtime
//// when the body mounts a server component.
////
//// Every page includes `howdy/ui/behaviour`, the small script behind menus,
//// tabs, selects and tooltips, in the page and in its live views.

import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import howdy/content.{type Content}
import howdy/controller.{type GuardedContext}
import howdy/ui/behaviour
import howdy/ui/direction
import howdy/ui/internal/stylesheet
import howdy/ui/live
import howdy/ui/theme.{type Themes}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/server_component

/// A document under construction.
pub opaque type Page(msg) {
  Page(
    title: String,
    lang: String,
    dir: Option(String),
    themes: Themes,
    theme: Option(String),
    head: List(Element(msg)),
    body: List(Element(msg)),
    live: Bool,
    stylesheet: Option(String),
  )
}

/// A page with the given title, English as its language and the default
/// light and dark themes.
pub fn new(title: String) -> Page(msg) {
  Page(
    title:,
    lang: "en",
    dir: None,
    themes: theme.default_themes(),
    theme: None,
    head: [],
    body: [],
    live: False,
    stylesheet: None,
  )
}

/// Set the `lang` attribute of the root element.
pub fn lang(page: Page(msg), lang: String) -> Page(msg) {
  Page(..page, lang:)
}

/// Which way the page's text runs. See `howdy/ui/direction`.
pub fn direction(page: Page(msg), direction: direction.Direction) -> Page(msg) {
  Page(
    ..page,
    dir: Some(case direction {
      direction.Ltr -> "ltr"
      direction.Rtl -> "rtl"
      direction.Auto -> "auto"
    }),
  )
}

/// The themes this page offers. See `howdy/ui/theme`.
pub fn themes(page: Page(msg), themes: Themes) -> Page(msg) {
  Page(..page, themes:)
}

/// Select a theme by name for this render, usually from a cookie. A name
/// that is not in the page's themes is ignored, so a default such as
/// `"system"` leaves the choice to the browser's colour scheme preference.
pub fn theme(page: Page(msg), name: String) -> Page(msg) {
  Page(..page, theme: Some(name))
}

/// Add elements to the `<head>`, after the title and styles.
pub fn head(page: Page(msg), elements: List(Element(msg))) -> Page(msg) {
  Page(..page, head: list.append(page.head, elements))
}

/// Add elements to the `<body>`.
pub fn body(page: Page(msg), elements: List(Element(msg))) -> Page(msg) {
  Page(..page, body: list.append(page.body, elements))
}

/// Include the Lustre client runtime so `live.mount` elements connect, and
/// the script that lets `live.link` swap a `live.outlet`.
pub fn live(page: Page(msg)) -> Page(msg) {
  Page(..page, live: True)
}

/// Link a stylesheet instead of embedding the CSS: the route mounted with
/// `ui.stylesheet` in development, or the file written by
/// `howdy/ui/export` when published. The path is used as given.
pub fn stylesheet(page: Page(msg), at path: String) -> Page(msg) {
  Page(..page, stylesheet: Some(path))
}

/// The finished document as an element.
pub fn render(page: Page(msg)) -> Element(msg) {
  let runtime = case page.live {
    True -> [server_component.script(), live.script()]
    False -> []
  }
  let dir = case page.dir {
    Some(dir) -> [attribute.attribute("dir", dir)]
    None -> []
  }
  html.html(
    [attribute.lang(page.lang), ..list.append(dir, theme_attribute(page))],
    [
      html.head(
        [],
        list.flatten([
          [
            html.meta([attribute.attribute("charset", "utf-8")]),
            html.meta([
              attribute.name("viewport"),
              attribute.content("width=device-width, initial-scale=1"),
            ]),
            html.title([], page.title),
          ],
          styles(page),
          page.head,
          [behaviour.script()],
          runtime,
        ]),
      ),
      html.body([], page.body),
    ],
  )
}

/// The finished document as HTML, with the doctype.
pub fn to_string(page: Page(msg)) -> String {
  page
  |> render
  |> element.to_document_string
}

/// Answer the request with the document as `text/html`.
pub fn respond(
  page: Page(msg),
  ctx: GuardedContext(guarded),
) -> Response(Content) {
  controller.html(ctx, to_string(page))
}

fn styles(page: Page(msg)) -> List(Element(msg)) {
  case page.stylesheet {
    Some(path) -> [
      html.link([attribute.rel("stylesheet"), attribute.href(path)]),
    ]
    None -> [html.style([], stylesheet.document_css(page.themes))]
  }
}

fn theme_attribute(page: Page(msg)) -> List(attribute.Attribute(msg)) {
  let theme.Themes(default:, alternatives:) = page.themes
  case page.theme {
    Some(name) ->
      case
        list.any([default, ..alternatives], fn(theme) { theme.name == name })
      {
        True -> [attribute.data("theme", name)]
        False -> []
      }
    None -> []
  }
}
