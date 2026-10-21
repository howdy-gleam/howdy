//// A task list built from howdy_ui components, running in the browser.
//// Its flags are the starting tasks' titles.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import howdy/ui/badge
import howdy/ui/button
import howdy/ui/card
import howdy/ui/dialog
import howdy/ui/input
import howdy/ui/island.{type Island}
import howdy/ui/tabs
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event

pub fn island() -> Island(List(String), Model, Msg) {
  island.simple(
    init:,
    update:,
    view:,
    flags: decode.list(decode.string),
    encode: json.array(_, json.string),
  )
}

pub type Task {
  Task(title: String, done: Bool)
}

pub type Model {
  Model(tasks: List(Task), draft: String)
}

pub type Msg {
  Typed(String)
  Added
  Toggled(Int)
  Cleared
}

fn init(titles: List(String)) -> Model {
  Model(tasks: list.map(titles, Task(_, done: False)), draft: "")
}

fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Typed(draft) -> Model(..model, draft:)
    Added if model.draft == "" -> model
    Added ->
      Model(
        tasks: list.append(model.tasks, [Task(model.draft, False)]),
        draft: "",
      )
    Toggled(index) ->
      Model(
        ..model,
        tasks: list.index_map(model.tasks, fn(task, i) {
          case i == index {
            True -> Task(..task, done: !task.done)
            False -> task
          }
        }),
      )
    Cleared -> Model(..model, tasks: [])
  }
}

fn view(model: Model) -> Element(Msg) {
  let open = list.count(model.tasks, fn(task) { !task.done })
  card.card([], [
    card.header([], [
      card.title([text("Tasks")]),
      card.description([text(int.to_string(open) <> " open")]),
    ]),
    card.content([], [
      html.form([event.on_submit(fn(_) { Added })], [
        input.input([
          attribute.placeholder("New task"),
          attribute.value(model.draft),
          event.on_input(Typed),
        ]),
        button.submit(button.Primary, [], [text("Add")]),
      ]),
      // The browser switches tabs itself; re-renders leave its choice alone.
      tabs.tabs("task-tabs", selected: "all", attributes: [], tabs: [
        tabs.tab("all", [], label: [text("All")], panel: [
          html.ul([], list.index_map(model.tasks, task)),
        ]),
        tabs.tab("done", [], label: [text("Done")], panel: [
          html.ul(
            [],
            list.index_map(model.tasks, fn(item, i) { #(item, i) })
              |> list.filter(fn(pair) { { pair.0 }.done })
              |> list.map(fn(pair) { task(pair.0, pair.1) }),
          ),
        ]),
      ]),
    ]),
    card.footer([], [
      button.button(button.Danger, dialog.trigger("clear-tasks"), [
        text("Clear all"),
      ]),
      dialog.alert_dialog("clear-tasks", [], [
        dialog.header([
          dialog.title("clear-tasks", [text("Clear every task?")]),
        ]),
        dialog.footer([
          button.button(button.Outline, dialog.close("clear-tasks"), [
            text("Keep them"),
          ]),
          button.button(
            button.Danger,
            [event.on_click(Cleared), ..dialog.close("clear-tasks")],
            [text("Clear")],
          ),
        ]),
      ]),
    ]),
  ])
}

fn task(task: Task, index: Int) -> Element(Msg) {
  let status = case task.done {
    True -> badge.badge(badge.Outline, [], [text("Done")])
    False -> badge.badge(badge.Secondary, [], [text("Open")])
  }
  html.li([], [
    status,
    text(" " <> task.title <> " "),
    button.button(button.Ghost, [event.on_click(Toggled(index))], [
      text(case task.done {
        True -> "Reopen"
        False -> "Done"
      }),
    ]),
  ])
}
