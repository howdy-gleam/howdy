//// A chat server. Run with `gleam run` from `examples/chat`; it listens on
//// 127.0.0.1:8789. Open http://localhost:8789 in two browser tabs.
////
//// Every room is a channel topic. A socket joins its room on open and
//// leaves when it closes; anything with the room name can broadcast to it,
//// including the plain HTTP route below.
////
//// Who is in each room comes from `howdy/websocket/presence`: every socket
//// tracks its person in the room and watches the room's presence, which the
//// page keeps as a list with the client script served at
//// `/howdy/presence.js`. Someone with two tabs open is listed once, and is
//// typing while either tab is.
////
//// ```sh
//// curl http://localhost:8789/rooms/lobby                                   # {"room":"lobby","members":2}
//// curl -X POST http://localhost:8789/rooms/lobby/announce -d '{"text":"Server restarting soon"}'
//// websocat 'ws://localhost:8789/chat/lobby?name=Ada'                      # then type JSON lines: {"text":"hi"} or {"typing":true}
//// ```

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/otp/static_supervisor as supervisor
import howdy
import howdy/body
import howdy/controller.{type Context}
import howdy/logger
import howdy/param
import howdy/query
import howdy/static
import howdy/websocket
import howdy/websocket/channel
import howdy/websocket/presence.{type Presence}
import logging

pub fn app() -> howdy.App {
  howdy.new()
  |> howdy.middleware(logger.log)
  |> howdy.controller(chat_controller())
  |> howdy.controller(rooms_controller())
  |> howdy.controller(presence.client(at: "/howdy/presence.js"))
  |> howdy.controller(static.serve("/", from: "priv/public"))
}

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Info)

  // Under a supervisor inside an OTP application: a crash restarts the
  // server, and SIGTERM sends every socket a going-away frame before exit.
  // A local demo, so it listens on 127.0.0.1:8789 only.
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(howdy.supervised(
      app() |> howdy.bind(to: "127.0.0.1") |> howdy.listening(on: 8789),
    ))
    |> howdy.start_application(name: "howdy_chat_server")

  process.sleep_forever()
}

// -- WebSocket ---------------------------------------------------------------

/// What one connection knows about itself.
type Member {
  Member(name: String, room: String)
}

/// What the room shows for a person: their name and whether they are
/// typing. Each of their tabs has its own.
pub type Here {
  Here(name: String, typing: Bool)
}

/// The people in each room, keyed by name.
pub fn people() -> Presence(Here) {
  presence.new(
    "people",
    encode: fn(here: Here) {
      json.object([
        #("name", json.string(here.name)),
        #("typing", json.bool(here.typing)),
      ])
    },
    decoder: {
      use name <- decode.field("name", decode.string)
      use typing <- decode.field("typing", decode.bool)
      decode.success(Here(name:, typing:))
    },
  )
}

/// A message from the client: `{"text": "..."}` to say something, or
/// `{"typing": true}` while typing.
type Inbound {
  Say(text: String)
  Typing(Bool)
}

fn inbound_decoder() -> decode.Decoder(Inbound) {
  decode.one_of(
    decode.field("text", decode.string, fn(text) { decode.success(Say(text)) }),
    [
      decode.field("typing", decode.bool, fn(typing) {
        decode.success(Typing(typing))
      }),
    ],
  )
}

fn text_decoder() -> decode.Decoder(String) {
  use text <- decode.field("text", decode.string)
  decode.success(text)
}

fn topic(room: String) -> String {
  "room:" <> room
}

/// `GET /chat/:room?name=Ada` upgrades to a WebSocket. Query parsing runs
/// before the upgrade, so a missing name is a plain `400` and never a socket.
fn chat_controller() {
  controller.new("chat")
  |> controller.get("/:room", fn(ctx: Context) {
    use room <- param.string(ctx, "room")
    use name <- query.string(ctx, "name")

    websocket.new(fn(socket) {
      channel.join(socket, topic(room))
      // Callbacks run in the socket's own process, so it tracks itself and
      // leaves the room when the connection ends, however it ends.
      let here = Here(name:, typing: False)
      presence.track(
        people(),
        process.self(),
        topic(room),
        key: name,
        meta: here,
      )
      presence.watch(people(), socket, topic(room))
      Member(name:, room:)
    })
    |> websocket.on_json(inbound_decoder(), fn(_socket, member, inbound) {
      case inbound {
        Say(text) ->
          channel.broadcast_json(
            topic(member.room),
            json.object([
              #("kind", json.string("message")),
              #("from", json.string(member.name)),
              #("text", json.string(text)),
            ]),
          )
        // Tracking again replaces this tab's meta.
        Typing(typing) ->
          presence.track(
            people(),
            process.self(),
            topic(member.room),
            key: member.name,
            meta: Here(name: member.name, typing:),
          )
      }
      websocket.continue(member)
    })
    |> websocket.upgrade(ctx)
  })
}

fn notice(room: String, text: String) -> Nil {
  channel.broadcast_json(
    topic(room),
    json.object([#("kind", json.string("notice")), #("text", json.string(text))]),
  )
}

// -- HTTP --------------------------------------------------------------------

/// Plain routes that read and write the same channels the sockets use.
fn rooms_controller() {
  controller.new("rooms")
  |> controller.get("/:room", fn(ctx: Context) {
    use room <- param.string(ctx, "room")
    controller.json(
      ctx,
      json.object([
        #("room", json.string(room)),
        #("members", json.int(presence.count(people(), topic(room)))),
      ]),
    )
  })
  |> controller.post("/:room/announce", fn(ctx: Context) {
    use room <- param.string(ctx, "room")
    use text <- body.json(ctx, text_decoder())
    notice(room, text)
    controller.status(ctx, 202)
  })
}
