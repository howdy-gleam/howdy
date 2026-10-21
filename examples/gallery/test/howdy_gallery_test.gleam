import gleam/http/response
import gleam/list
import gleam/string
import gleeunit
import howdy/testing
import howdy_gallery

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn every_page_renders_test() {
  use path <- list.each([
    "/",
    "/chat",
    "/components",
    "/sign-in",
    "/sign-up",
    "/ui",
    "/ui/chat",
  ])
  let res = testing.get(path) |> testing.send(howdy_gallery.app())
  assert res.status == 200
  assert string.contains(testing.text(res), "window.howdyBehaviour")
}

pub fn dashboard_greets_after_sign_in_test() {
  let html =
    testing.get("/?welcome=ada")
    |> testing.send(howdy_gallery.app())
    |> testing.text
  assert string.contains(html, "Signed in as ada.")
}

pub fn sign_up_shows_every_problem_test() {
  let res =
    testing.post_form("/sign-up", [
      #("name", ""),
      #("email", "nope"),
      #("password", "short"),
      #("plan", ""),
    ])
    |> testing.send(howdy_gallery.app())
  assert res.status == 422
  let html = testing.text(res)
  assert string.contains(html, "Enter your name.")
  assert string.contains(html, "Enter an email address")
  assert string.contains(html, "Use at least 8 characters.")
  assert string.contains(html, "Choose a plan.")
  assert string.contains(html, "Accept the terms to continue.")
  assert string.contains(html, "aria-invalid=\"true\"")
}

pub fn sign_up_signs_in_test() {
  let res =
    testing.post_form("/sign-up", [
      #("name", "Ada"),
      #("email", "ada@example.com"),
      #("password", "correct horse"),
      #("plan", "team"),
      #("terms", "on"),
    ])
    |> testing.send(howdy_gallery.app())
  assert res.status == 303
  assert response.get_header(res, "location") == Ok("/?welcome=Ada")
}

pub fn components_sort_with_links_test() {
  let html =
    testing.get("/components?sort=seats&dir=desc")
    |> testing.send(howdy_gallery.app())
    |> testing.text
  let assert Ok(#(_, rest)) = string.split_once(html, "Umbrella")
  assert string.contains(rest, "Globex")
  assert string.contains(html, "aria-sort=\"descending\"")
}

pub fn the_chat_view_offers_a_composer_test() {
  let html =
    testing.get("/chat")
    |> testing.send(howdy_gallery.app())
    |> testing.text
  assert string.contains(html, "lustre-server-component")
  assert string.contains(html, "route=\"/live/chat\"")
}
