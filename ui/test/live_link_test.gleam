import gleam/string
import howdy/ui/live
import lustre/element.{text}
import lustre/element/html

pub fn outlet_is_a_marked_focusable_mount_test() {
  assert element.to_string(live.outlet("/live/orders"))
    == "<lustre-server-component data-howdy-live-outlet route=\"/live/orders\" tabindex=\"-1\"></lustre-server-component>"
}

pub fn link_is_a_styled_anchor_to_the_page_test() {
  let html =
    live.link(to: "/orders", mount: "/live/orders", children: [text("Orders")])
    |> element.to_string

  assert string.starts_with(html, "<a class=\"")
  assert string.contains(html, "href=\"/orders\"")
  assert string.contains(html, "data-howdy-live-mount=\"/live/orders\"")
  assert string.ends_with(html, ">Orders</a>")
}

pub fn navigate_makes_any_anchor_a_live_link_test() {
  assert element.to_string(
      html.a(live.navigate(to: "/about", mount: "/live/about"), [text("About")]),
    )
    == "<a data-howdy-live-mount=\"/live/about\" href=\"/about\">About</a>"
}

pub fn title_is_a_title_element_test() {
  assert element.to_string(live.title("Orders")) == "<title>Orders</title>"
}
