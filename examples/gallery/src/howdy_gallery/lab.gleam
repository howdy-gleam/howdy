//// A live view that puts the interactive components through their paces
//// inside a real shadow root, with the server's view of each one shown
//// beside it. The browser tests in `ui/browser_test` drive it.

import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import howdy/ui
import howdy/ui/button.{Outline}
import howdy/ui/chat.{Incoming}
import howdy/ui/command
import howdy/ui/live
import howdy/ui/questionnaire
import howdy/ui/rich_text
import howdy/ui/rich_text/document.{type Document}
import howdy/ui/toast
import howdy/ui/words
import howdy_gallery/timer
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event

pub type Model {
  Model(
    toppings: List(String),
    plan: String,
    tab: String,
    toasts: toast.Queue,
    oldest: Int,
    asked: questionnaire.Questionnaire,
    /// Added to the clock, so a test can skip ahead of the toasts.
    skipped: Int,
    /// Where the toasts' timers are delivered.
    timers: Option(Subject(Msg)),
    /// The rich text editor's document, as last heard, and how many times.
    note: Document,
    notes_heard: Int,
  )
}

pub type Msg {
  Timers(Subject(Msg))
  Toppings(List(String))
  Plan(String)
  Tab(String)
  Notify
  Save
  Saved(Int)
  Dismiss(Int)
  Held(Int, Bool)
  Remind
  Reminded(Int)
  Sweep
  SkipAhead
  Older
  Answered(List(#(String, String)))
  Note(String)
  ClearNote
}

pub fn app() -> lustre.App(Nil, Model, Msg) {
  lustre.application(init:, update:, view:)
}

fn init(_) -> #(Model, Effect(Msg)) {
  #(
    Model(
      toppings: ["basil"],
      plan: "",
      tab: "one",
      toasts: toast.queue(),
      oldest: 31,
      asked: questionnaire.start(questions()),
      skipped: 0,
      timers: None,
      note: document.from_text("Hello from the server"),
      notes_heard: 0,
    ),
    timer.subscribe(Timers),
  )
}

pub fn questions() -> List(questionnaire.Question) {
  [
    questionnaire.question(
      "role",
      "What do you mostly do?",
      questionnaire.Single([#("build", "Build software"), #("design", "Design")]),
    )
      |> questionnaire.required,
    questionnaire.question(
      "score",
      "How likely are you to recommend us?",
      questionnaire.Scale(from: 0, to: 5, low: "Not likely", high: "Very"),
    ),
  ]
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    // The sweep starts once there is somewhere to deliver it.
    Timers(timers) -> {
      let model = Model(..model, timers: Some(timers))
      #(model, later(model, Sweep, 1000))
    }
    Toppings(toppings) -> #(Model(..model, toppings:), effect.none())
    Plan(plan) -> #(Model(..model, plan:), effect.none())
    Note(json) ->
      case document.decode(json) {
        Ok(note) -> #(
          Model(..model, note:, notes_heard: model.notes_heard + 1),
          effect.none(),
        )
        Error(_) -> #(model, effect.none())
      }
    ClearNote -> #(Model(..model, note: document.empty()), effect.none())
    Tab(tab) -> #(Model(..model, tab:), effect.none())
    Notify -> {
      let #(toasts, _) =
        toast.push(model.toasts, toast.Info, "Hello", "", clock(model))
      #(Model(..model, toasts:), effect.none())
    }
    Save -> {
      let #(toasts, id) =
        toast.push(model.toasts, toast.Loading, "Saving…", "", clock(model))
      #(Model(..model, toasts:), later(model, Saved(id), 800))
    }
    Saved(id) -> #(
      Model(
        ..model,
        toasts: toast.update(
          model.toasts,
          id,
          toast.Success,
          "Saved",
          "",
          clock(model),
        ),
      ),
      effect.none(),
    )
    Remind -> {
      let #(toasts, id) =
        toast.push(model.toasts, toast.Success, "Reminder", "", clock(model))
      #(Model(..model, toasts:), later(model, Reminded(id), 2500))
    }
    Reminded(id) -> #(
      Model(
        ..model,
        toasts: toast.update(
          model.toasts,
          id,
          toast.Success,
          "Reminder again",
          "",
          clock(model),
        ),
      ),
      effect.none(),
    )
    Held(id, held) -> #(
      Model(..model, toasts: toast.hold(model.toasts, id, held, clock(model))),
      effect.none(),
    )
    // The fallback cleanup, run as an application would.
    Sweep -> #(
      Model(..model, toasts: toast.expire(model.toasts, clock(model))),
      later(model, Sweep, 1000),
    )
    SkipAhead -> {
      let model = Model(..model, skipped: model.skipped + 120_000)
      #(
        Model(..model, toasts: toast.expire(model.toasts, clock(model))),
        effect.none(),
      )
    }
    Dismiss(id) -> #(
      Model(..model, toasts: toast.dismiss(model.toasts, id)),
      effect.none(),
    )
    Older -> #(
      Model(..model, oldest: int.max(model.oldest - 10, 1)),
      effect.none(),
    )
    Answered(fields) -> #(
      Model(..model, asked: questionnaire.submit(questions(), fields)),
      effect.none(),
    )
  }
}

/// The toasts' clock, which a test can move ahead.
fn clock(model: Model) -> Int {
  now() + model.skipped
}

/// `msg`, `milliseconds` from now, as a timer on the runtime.
fn later(model: Model, msg: Msg, milliseconds: Int) -> Effect(Msg) {
  case model.timers {
    Some(timers) -> timer.after(timers, milliseconds, msg)
    None -> effect.none()
  }
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: atom.Atom) -> Int

fn now() -> Int {
  monotonic_time(atom.create("millisecond"))
}

fn view(model: Model) -> Element(Msg) {
  ui.stack([attribute.class("gallery-lab")], [
    ui.h2("Lab"),
    // Several values, heard as a list.
    html.section([live.on_values("toppings", Toppings)], [
      command.multiple_combobox(
        words: words.english(),
        id: "lab-toppings",
        name: "toppings",
        values: model.toppings,
        placeholder: "Add toppings",
        search: "Search toppings…",
        attributes: [],
        options: [
          #("basil", "Basil"),
          #("olives", "Olives"),
          #("chilli, sliced", "Chilli, sliced"),
        ],
      ),
      html.output([attribute.id("lab-toppings-heard")], [
        text(string.join(model.toppings, " | ")),
      ]),
    ]),
    // A rich text editor, heard when it loses focus and cleared from the
    // server.
    html.section([live.on_value("note", Note)], [
      rich_text.new(name: "note")
        |> rich_text.value(model.note)
        |> rich_text.mentions(
          trigger: "@",
          kind: "person",
          search: "/people/search",
        )
        |> rich_text.view,
      html.output([attribute.id("lab-note-heard")], [
        text(
          int.to_string(model.notes_heard)
          <> ": "
          <> document.to_plain_text(model.note),
        ),
      ]),
      ui.button(
        Outline,
        [attribute.id("lab-note-clear"), event.on_click(ClearNote)],
        [text("Clear")],
      ),
    ]),
    // A select, heard by name; and one disabled and invalid.
    html.section([live.on_value("plan", Plan)], [
      ui.select(
        id: "lab-plan",
        name: "plan",
        value: model.plan,
        placeholder: "Choose a plan",
        attributes: [],
        items: [ui.select_item("free", "Free"), ui.select_item("pro", "Pro")],
      ),
      html.output([attribute.id("lab-plan-heard")], [text(model.plan)]),
      ui.select(
        id: "lab-locked",
        name: "locked",
        value: "",
        placeholder: "Locked",
        attributes: [attribute.disabled(True), attribute.aria_invalid("true")],
        items: [ui.select_item("a", "A")],
      ),
    ]),
    // Tabs changed by keyboard are heard as clicks.
    ui.tabs("lab-tabs", selected: model.tab, attributes: [], tabs: [
      ui.tab("one", [event.on_click(Tab("one"))], label: [text("One")], panel: [
        text("First"),
      ]),
      ui.tab("two", [event.on_click(Tab("two"))], label: [text("Two")], panel: [
        text("Second"),
      ]),
    ]),
    html.output([attribute.id("lab-tab-heard")], [text(model.tab)]),
    // Toasts kept in the model, closed by the browser when they fade.
    ui.row([], [
      ui.button(Outline, [attribute.id("lab-notify"), event.on_click(Notify)], [
        text("Notify"),
      ]),
      ui.button(Outline, [attribute.id("lab-save"), event.on_click(Save)], [
        text("Save"),
      ]),
    ]),
    html.output([attribute.id("lab-toast-count")], [
      text(int.to_string(list.length(toast.items(model.toasts)))),
    ]),
    ui.row([], [
      ui.button(Outline, [attribute.id("lab-remind"), event.on_click(Remind)], [
        text("Remind"),
      ]),
      ui.button(Outline, [attribute.id("lab-skip"), event.on_click(SkipAhead)], [
        text("Skip ahead two minutes"),
      ]),
    ]),
    toast.view(
      words.english(),
      model.toasts,
      on_close: fn(id) { [event.on_click(Dismiss(id))] },
      on_hold: Held,
    ),
    // History loaded as the reader scrolls back.
    chat.conversation(
      words.english(),
      [
        attribute.id("lab-conversation"),
        attribute.aria_label("History"),
        attribute.style("height", "12rem"),
        chat.remember("lab"),
        chat.on_older(Older),
      ],
      list.map(
        int.range(from: 40, to: model.oldest - 1, with: [], run: list.prepend),
        fn(n) {
          let n = int.to_string(n)
          chat.message(
            Incoming,
            attributes: [attribute.id("lab-message-" <> n)],
            avatar: element.none(),
            header: [],
            content: [chat.bubble(Incoming, [text("Message " <> n)])],
            footer: [],
          )
        },
      ),
    ),
    html.output([attribute.id("lab-oldest")], [
      text(int.to_string(model.oldest)),
    ]),
    // A questionnaire answered without leaving the page.
    case questionnaire.is_complete(model.asked) {
      True ->
        html.output([attribute.id("lab-answers")], [
          text(
            questionnaire.answers(model.asked)
            |> list.map(fn(pair) { pair.0 <> "=" <> string.join(pair.1, ",") })
            |> string.join(" "),
          ),
        ])
      False ->
        questionnaire.view(words.english(), model.asked, [
          attribute.id("lab-questionnaire"),
          event.on_submit(Answered),
        ])
    },
  ])
}
