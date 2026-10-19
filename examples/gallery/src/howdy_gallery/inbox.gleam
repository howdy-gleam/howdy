//// A pretend inbox for the notification bell example, answering the way
//// `howdy_notifications` routes do. It keeps nothing: the list is always
//// the same three, and the event stream announces a new notification every
//// few seconds.

import gleam/erlang/atom.{type Atom}
import gleam/erlang/process
import gleam/int
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import howdy/controller.{type Controller}
import howdy/sse

pub fn controller() -> Controller {
  controller.new("/notifications")
  |> controller.get("/", fn(ctx) {
    controller.json(
      ctx,
      json.object([
        #(
          "notifications",
          json.preprocessed_array([
            notification(
              "n3",
              "Ana commented on your post",
              "Looks good!",
              None,
            ),
            notification("n2", "Your export is ready", "", None),
            notification("n1", "Bo joined the team", "", Some(1)),
          ]),
        ),
        #("unread", json.int(2)),
      ]),
    )
  })
  |> controller.get("/events", fn(ctx) {
    sse.new(fn(stream) {
      let _ = sse.send(stream, unread(2))
      process.send_after(sse.subject(stream), 5000, 3)
      Nil
    })
    |> sse.on_message(fn(stream, state, count) {
      let id = "live" <> int.to_string(count)
      let _ =
        sse.send(
          stream,
          sse.json(notification(
            id,
            "Order #" <> int.to_string(count) <> " was placed",
            "",
            None,
          ))
            |> sse.name("notification"),
        )
      let _ = sse.send(stream, unread(count))
      process.send_after(sse.subject(stream), 8000, count + 1)
      sse.continue(state)
    })
    |> sse.start(ctx)
  })
  |> controller.post("/read", fn(ctx) { count(ctx, 0) })
  |> controller.post("/:id/read", fn(ctx) { count(ctx, 1) })
  |> controller.post("/:id/unread", fn(ctx) { count(ctx, 2) })
}

fn notification(
  id: String,
  title: String,
  body: String,
  read_at: Option(Int),
) -> Json {
  json.object([
    #("id", json.string(id)),
    #("kind", json.string("demo")),
    #("title", json.string(title)),
    #("body", json.string(body)),
    #("link", json.string("#" <> id)),
    #("data", json.object([])),
    #("created_at", json.int(now() - 120_000)),
    #("read_at", json.nullable(read_at, json.int)),
  ])
}

fn unread(count: Int) -> sse.Event {
  sse.json(json.object([#("count", json.int(count))])) |> sse.name("unread")
}

fn count(ctx, count: Int) {
  controller.json(ctx, json.object([#("unread", json.int(count))]))
}

fn now() -> Int {
  system_time(atom.create("millisecond"))
}

@external(erlang, "os", "system_time")
fn system_time(unit: Atom) -> Int
