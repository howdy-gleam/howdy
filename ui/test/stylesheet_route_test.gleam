import gleam/http/response
import gleam/string
import howdy
import howdy/controller
import howdy/testing
import howdy/ui
import howdy/ui/button
import howdy/ui/page
import howdy/ui/theme
import lustre/element.{text}

fn app() -> howdy.App {
  howdy.new()
  |> howdy.controller(
    controller.new("/")
    |> controller.get("/", fn(ctx) {
      page.new("Linked")
      |> page.stylesheet(at: "/assets/ui.css")
      |> page.body([ui.button(button.Primary, [], [text("Go")])])
      |> page.respond(ctx)
    }),
  )
  |> howdy.controller(ui.stylesheet(
    at: "/assets/ui.css",
    themes: theme.default_themes(),
  ))
}

pub fn page_links_the_stylesheet_instead_of_embedding_test() {
  let html = testing.get("/") |> testing.send(app()) |> testing.text
  let assert Ok(#(head, _)) = string.split_once(html, "</head>")

  assert !string.contains(head, "<style>")
  assert string.contains(
    head,
    "<link href=\"/assets/ui.css\" rel=\"stylesheet\">",
  )
}

pub fn route_serves_the_same_css_a_page_would_embed_test() {
  let _ = testing.get("/") |> testing.send(app())
  let res = testing.get("/assets/ui.css") |> testing.send(app())
  let css = testing.text(res)

  assert res.status == 200
  assert response.get_header(res, "content-type")
    == Ok("text/css; charset=utf-8")
  assert response.get_header(res, "cache-control") == Ok("no-cache")
  assert string.contains(css, ":root { color-scheme: light;")
  assert string.contains(css, "body { margin: 0;")
  assert string.contains(css, "background: var(--howdy-primary)")

  let embedded =
    page.new("Embedded")
    |> page.body([ui.button(button.Primary, [], [text("Go")])])
    |> page.to_string
  assert string.contains(embedded, "<style>" <> css <> "</style>")
}

pub fn browsers_revalidate_with_the_etag_test() {
  let res = testing.get("/assets/ui.css") |> testing.send(app())
  let assert Ok(etag) = response.get_header(res, "etag")
  assert string.starts_with(etag, "\"")

  let again =
    testing.get("/assets/ui.css")
    |> testing.header("if-none-match", etag)
    |> testing.send(app())
  assert again.status == 304
  assert response.get_header(again, "etag") == Ok(etag)

  let stale =
    testing.get("/assets/ui.css")
    |> testing.header("if-none-match", "\"something-else\"")
    |> testing.send(app())
  assert stale.status == 200
}
