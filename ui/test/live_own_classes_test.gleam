//// A live view is styled by the CSS it carries, so a class of your own
//// that appears only in a live view works with no setup at all.

import gleam/erlang/process
import gleam/json
import gleam/string
import howdy/ui
import howdy/ui/live
import howdy/ui/theme/tokens
import lustre
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/server_component
import sketch/css

fn badge(content: String) -> Element(msg) {
  html.span(
    [
      ui.class(
        css.class([
          css.background(tokens.primary),
          css.property("--only-in-live-view", "yes"),
        ]),
      ),
    ],
    [text(content)],
  )
}

pub fn a_live_view_carries_the_css_for_its_own_classes_test() {
  let status =
    lustre.simple(
      init: fn(_) { Nil },
      update: fn(_, _: Nil) { Nil },
      view: fn(_) { badge("online") },
    )
  let assert Ok(runtime) = live.start(status, with: Nil)
  let inbox = process.new_subject()
  lustre.send(runtime, server_component.register_subject(inbox))

  let assert Ok(mount) = process.receive(inbox, 1000)
  let mount = json.to_string(server_component.client_message_to_json(mount))
  assert string.contains(mount, "--only-in-live-view: yes;")
  // Only what this view used: no built-in component CSS comes along.
  assert !string.contains(mount, "border-radius: var(--howdy-radius-large)")

  lustre.send(runtime, lustre.shutdown())
}
