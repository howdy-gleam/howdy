import gleam/string
import howdy/ui/bell
import lustre/element

fn render(bell: bell.Bell) -> String {
  element.to_string(bell.view(bell))
}

pub fn a_bell_tells_the_script_where_its_inbox_is_test() {
  let html =
    bell.new(id: "inbox", source: "/notifications")
    |> bell.unread(3)
    |> bell.inbox("/all")
    |> bell.push(at: "/push")
    |> render
  assert string.contains(html, "data-howdy-bell")
  assert string.contains(html, "data-source=\"/notifications\"")
  assert string.contains(html, "data-unread=\"3\"")
  assert string.contains(html, "aria-label=\"Notifications, 3 unread\"")
  assert string.contains(html, "popovertarget=\"inbox\"")
  assert string.contains(html, "id=\"inbox\"")
  assert string.contains(html, "href=\"/all\"")
  assert string.contains(html, "data-howdy-bell-push=\"/push\"")
  // Markup the script copies for new entries and toasts.
  assert string.contains(html, "<template data-howdy-bell-item")
  assert string.contains(html, "<template data-howdy-bell-toast")
  assert string.contains(html, "data-howdy-toast-region")
}

pub fn an_empty_bell_hides_its_count_test() {
  let html = bell.new(id: "inbox", source: "/n") |> render
  assert string.contains(html, "aria-label=\"Notifications\"")
  assert string.contains(html, "data-howdy-bell-count hidden>0<")
  assert !string.contains(html, "data-howdy-bell-push")
  assert !string.contains(html, "See all")
}

pub fn counts_and_words_test() {
  let words =
    bell.Words(..bell.english(), title: "Avisos", unread: "{count} sin leer")
  assert bell.unread_label(words, 0) == "Avisos"
  assert bell.unread_label(words, 4) == "Avisos, 4 sin leer"
  let html =
    bell.new(id: "b", source: "/n")
    |> bell.unread(250)
    |> bell.words(words)
    |> render
  assert string.contains(html, ">99+<")
  assert string.contains(html, "Avisos, 250 sin leer")
}
