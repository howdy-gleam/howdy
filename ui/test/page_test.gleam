import gleam/http/response
import gleam/string
import howdy
import howdy/controller
import howdy/cookie
import howdy/testing
import howdy/ui
import howdy/ui/button
import howdy/ui/live
import howdy/ui/page
import howdy/ui/theme
import lustre/element.{text}

fn app() -> howdy.App {
  howdy.new()
  |> howdy.controller(
    controller.new("/")
    |> controller.get("/", fn(ctx) {
      use chosen <- cookie.string_or(ctx, "theme", default: "system")
      page.new("Howdy UI")
      |> page.theme(chosen)
      |> page.body([
        ui.h1("Hello"),
        ui.button(button.Primary, [], [text("Go")]),
        ui.theme_toggle([text("Toggle")], from: "light", to: "dark"),
      ])
      |> page.respond(ctx)
    })
    |> controller.get("/live", fn(ctx) {
      page.new("Live")
      |> page.live
      |> page.body([live.mount("/live/socket")])
      |> page.respond(ctx)
    })
    |> controller.get("/branded", fn(ctx) {
      page.new("Brand")
      |> page.themes(
        theme.themes(
          default: theme.named(theme.light(), "brand"),
          alternatives: [],
        ),
      )
      |> page.theme("brand")
      |> page.respond(ctx)
    }),
  )
}

pub fn page_is_a_full_html_document_test() {
  let res = testing.get("/") |> testing.send(app())
  let html = testing.text(res)

  assert res.status == 200
  assert response.get_header(res, "content-type")
    == Ok("text/html; charset=utf-8")
  assert string.starts_with(html, "<!doctype html>")
  assert string.contains(html, "<html lang=\"en\">")
  assert string.contains(html, "<title>Howdy UI</title>")
  assert string.contains(html, "<h1 class=\"")
  assert string.contains(html, ">Hello</h1>")
}

pub fn head_carries_theme_variables_and_component_css_test() {
  let html = testing.get("/") |> testing.send(app()) |> testing.text

  assert string.contains(
    html,
    ":root { color-scheme: light; --howdy-background",
  )
  assert string.contains(html, "[data-theme=\"dark\"]")
  // The button's class is declared in the head and used in the body.
  let assert Ok(#(_, after)) = string.split_once(html, "<button class=\"")
  let assert Ok(#(class_name, _)) = string.split_once(after, "\"")
  let assert Ok(#(head, _)) = string.split_once(html, "</head>")
  assert string.contains(head, "." <> class_name <> " {")
  assert string.contains(head, "background: var(--howdy-primary)")
}

pub fn unknown_theme_leaves_the_choice_to_the_browser_test() {
  let html = testing.get("/") |> testing.send(app()) |> testing.text
  assert string.contains(html, "<html lang=\"en\">")
}

pub fn theme_cookie_sets_the_data_theme_attribute_test() {
  let html =
    testing.get("/")
    |> testing.cookie("theme", "dark")
    |> testing.send(app())
    |> testing.text
  assert string.contains(html, "<html data-theme=\"dark\" lang=\"en\">")
}

pub fn theme_must_be_one_the_page_offers_test() {
  let html =
    testing.get("/")
    |> testing.cookie("theme", "brand")
    |> testing.send(app())
    |> testing.text
  assert string.contains(html, "<html lang=\"en\">")

  let branded = testing.get("/branded") |> testing.send(app()) |> testing.text
  assert string.contains(branded, "data-theme=\"brand\"")
  assert !string.contains(branded, "@media (prefers-color-scheme")
}

pub fn theme_toggle_flips_the_attribute_and_cookie_test() {
  let html = testing.get("/") |> testing.send(app()) |> testing.text
  // The toggle is a marker the behaviour script acts on, not inline JS.
  assert string.contains(html, "data-howdy-theme-toggle")
  assert string.contains(html, "data-howdy-theme-from=\"light\"")
  assert string.contains(html, "data-howdy-theme-to=\"dark\"")
  assert !string.contains(html, "onclick=")
}

pub fn untrusted_theme_names_never_change_the_event_handler_test() {
  let normal =
    ui.theme_toggle([], from: "light", to: "dark") |> element.to_string
  let malicious =
    ui.theme_toggle(
      [],
      from: "\\',0);globalThis.pwned=1;//",
      to: "\"<&\u{2028}\u{2029}",
    )
    |> element.to_string
  // There is no handler to poison: the names only ever land in escaped
  // attribute values the behaviour script reads back as data.
  assert !string.contains(normal, "onclick")
  assert !string.contains(malicious, "onclick")
  assert !string.contains(malicious, "<script")
  assert string.contains(malicious, "data-howdy-theme-from=\"")
  // Quotes and angle brackets are escaped, so the value cannot end the
  // attribute or open a tag.
  assert string.contains(malicious, "&#39;")
  assert string.contains(malicious, "&quot;&lt;&amp;")
  assert !string.contains(malicious, "\"<&")
}

pub fn live_pages_include_the_client_runtime_test() {
  let plain = testing.get("/") |> testing.send(app()) |> testing.text
  assert !string.contains(
    plain,
    "customElements.define(\"lustre-server-component\"",
  )

  let html = testing.get("/live") |> testing.send(app()) |> testing.text
  assert string.contains(html, "<script type=\"module\">")
  assert string.contains(
    html,
    "customElements.define(\"lustre-server-component\"",
  )
  assert string.contains(
    html,
    "<lustre-server-component route=\"/live/socket\"></lustre-server-component>",
  )
}

pub fn live_pages_include_the_live_link_script_unescaped_test() {
  let plain = testing.get("/") |> testing.send(app()) |> testing.text
  assert !string.contains(plain, "data-howdy-live-outlet")

  let html = testing.get("/live") |> testing.send(app()) |> testing.text
  let assert Ok(#(_, script)) =
    string.split_once(html, "lustre-server-component[data-howdy-live-outlet]")
  let assert Ok(#(script, _)) = string.split_once(script, "</script>")
  assert string.contains(script, "history.pushState")
  assert string.contains(script, "(node) => node instanceof HTMLAnchorElement")
  assert !string.contains(script, "&gt;")
  assert !string.contains(script, "&#39;")
}
