//// A live view that hears the signed-in user's notifications as they
//// arrive, through `notifications.subscribe`. The bell in the page header
//// keeps up by itself; this shows how any live view can do the same.

import gleam/erlang/process
import gleam/int
import gleam/list
import howdy/notifications.{type Notification, Received, Unread}
import howdy/ui
import lustre
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/server_component

pub type Model {
  Model(unread: Int, recent: List(Notification))
}

pub type Msg {
  Notified(notifications.Event)
}

/// Started with the user's ID and how many notifications they have unread.
pub fn app() -> lustre.App(#(String, Int), Model, Msg) {
  lustre.application(init, update, view)
}

fn init(args: #(String, Int)) -> #(Model, Effect(Msg)) {
  let #(user, unread) = args
  #(
    Model(unread:, recent: []),
    // The subscription lasts as long as this live view's runtime.
    server_component.select(fn(_dispatch, subject) {
      notifications.subscribe(user, subject)
      process.new_selector() |> process.select_map(subject, Notified)
    }),
  )
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Notified(Received(notification)) -> #(
      Model(..model, recent: list.take([notification, ..model.recent], 5)),
      effect.none(),
    )
    Notified(Unread(count)) -> #(Model(..model, unread: count), effect.none())
  }
}

fn view(model: Model) -> Element(Msg) {
  ui.stack([], [
    ui.p([text("Unread: " <> int.to_string(model.unread))]),
    case model.recent {
      [] -> ui.muted("Nothing new since this page opened.")
      recent ->
        html.ul(
          [],
          list.map(recent, fn(notification) {
            html.li([], [text(notification.title)])
          }),
        )
    },
  ])
}
