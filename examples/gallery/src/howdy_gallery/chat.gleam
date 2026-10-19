//// A live chat with a bot whose replies stream in a word at a time. The
//// conversation stays on the newest message while the reply grows, and
//// keeps its place if you scroll back to read.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import howdy/ui
import howdy/ui/button.{Primary}
import howdy/ui/chat.{Incoming, Outgoing}
import howdy/ui/words
import howdy_gallery/timer
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event

pub type Author {
  Me
  Bot
}

pub type Message {
  Message(id: Int, author: Author, text: String, streaming: Bool)
}

pub type Model {
  Model(
    messages: List(Message),
    draft: String,
    next_id: Int,
    /// Where the words of a reply are timed to arrive.
    timers: Option(Subject(Msg)),
  )
}

pub type Msg {
  Timers(Subject(Msg))
  Draft(String)
  Send
  Stream(Int, String)
  Done(Int)
}

pub fn app() -> lustre.App(Nil, Model, Msg) {
  lustre.application(init:, update:, view:)
}

fn init(_) -> #(Model, Effect(Msg)) {
  #(
    Model(
      messages: [
        Message(
          1,
          Bot,
          "Hello! Ask me anything; my answers take a moment to arrive.",
          False,
        ),
      ],
      draft: "",
      next_id: 2,
      timers: None,
    ),
    timer.subscribe(Timers),
  )
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Timers(timers) -> #(Model(..model, timers: Some(timers)), effect.none())
    Draft(draft) -> #(Model(..model, draft:), effect.none())
    Send ->
      case string.trim(model.draft) {
        "" -> #(model, effect.none())
        said -> {
          let question = Message(model.next_id, Me, said, False)
          let reply = Message(model.next_id + 1, Bot, "", True)
          #(
            Model(
              ..model,
              messages: list.append(model.messages, [question, reply]),
              draft: "",
              next_id: model.next_id + 2,
            ),
            stream(model.timers, reply.id, answer(said)),
          )
        }
      }
    Stream(id, word) -> #(
      Model(
        ..model,
        messages: list.map(model.messages, fn(message) {
          case message.id == id {
            True -> Message(..message, text: message.text <> word)
            False -> message
          }
        }),
      ),
      effect.none(),
    )
    Done(id) -> #(
      Model(
        ..model,
        messages: list.map(model.messages, fn(message) {
          case message.id == id {
            True -> Message(..message, streaming: False)
            False -> message
          }
        }),
      ),
      effect.none(),
    )
  }
}

/// Send the reply a word at a time, as a model streaming its answer would:
/// each word is a timer on the runtime, so nothing sleeps. Without timers
/// yet, the whole reply arrives at once.
fn stream(timers: Option(Subject(Msg)), id: Int, reply: String) -> Effect(Msg) {
  let words = string.split(reply, " ")
  case timers {
    Some(timers) ->
      words
      |> list.index_map(fn(word, index) {
        timer.after(timers, 600 + 90 * index, Stream(id, word <> " "))
      })
      |> list.append([
        timer.after(timers, 600 + 90 * list.length(words), Done(id)),
      ])
      |> effect.batch
    None -> {
      use dispatch <- effect.from
      dispatch(Stream(id, reply))
      dispatch(Done(id))
    }
  }
}

fn answer(question: String) -> String {
  "You asked: \""
  <> question
  <> "\". I am a very small bot, so here is a long answer instead of a good one. "
  <> string.repeat(
    "Each word arrives on its own, and the conversation stays on the newest line while you watch. Scroll up and it stays where you left it. ",
    3,
  )
  <> "That is all I know."
}

fn view(model: Model) -> Element(Msg) {
  ui.card([attribute.class("gallery-chat")], [
    ui.card_header([], [
      ui.card_title([html.h2([], [text("Chat")])]),
      ui.card_description([text("A live view. Replies stream in.")]),
    ]),
    ui.chat_conversation(
      words.english(),
      [attribute.aria_label("Messages"), attribute.style("height", "24rem")],
      [ui.chat_note([text("Today")]), ..list.map(model.messages, message)],
    ),
    html.form(
      [
        attribute.class("gallery-composer"),
        event.on_submit(fn(_) { Send }) |> event.prevent_default,
      ],
      [
        ui.input([
          attribute.aria_label("Message"),
          attribute.placeholder("Write a message…"),
          attribute.value(model.draft),
          attribute.autocomplete("off"),
          event.on_input(Draft),
        ]),
        ui.submit_button(Primary, [], [text("Send")]),
      ],
    ),
  ])
}

fn message(message: Message) -> Element(Msg) {
  let id = attribute.id("message-" <> int.to_string(message.id))
  case message.author {
    Me ->
      html.div([id], [
        ui.chat_message(
          Outgoing,
          attributes: [],
          avatar: element.none(),
          header: [],
          content: [
            ui.chat_bubble(Outgoing, [text(message.text)]),
          ],
          footer: [],
        ),
      ])
    Bot ->
      html.div([id], [
        ui.chat_message(
          Incoming,
          attributes: [],
          avatar: ui.avatar_initials("HB"),
          header: [text("Howdy bot")],
          content: [
            ui.chat_bubble(Incoming, [
              case message.text, message.streaming {
                "", _ -> ui.shimmer([text("Thinking…")])
                said, _ -> text(said)
              },
            ]),
          ],
          footer: [],
        ),
      ])
  }
}
