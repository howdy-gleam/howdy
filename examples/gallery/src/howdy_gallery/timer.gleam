//// Messages delivered to a live view later, as timers on the runtime's
//// own mailbox rather than a process sleeping for each one. Ask for the
//// runtime's subject once with `subscribe`, keep it in the model, and
//// pass it to `after`.

import gleam/erlang/process.{type Subject}
import lustre/effect.{type Effect}
import lustre/server_component

/// Give the runtime a subject to hear timers on, and hear it as `ready`.
pub fn subscribe(ready: fn(Subject(msg)) -> msg) -> Effect(msg) {
  use dispatch, subject <- server_component.select
  dispatch(ready(subject))
  process.new_selector() |> process.select(subject)
}

/// Deliver `msg` to the runtime after `milliseconds`.
pub fn after(timers: Subject(msg), milliseconds: Int, msg: msg) -> Effect(msg) {
  use _dispatch <- effect.from
  process.send_after(timers, milliseconds, msg)
  Nil
}
