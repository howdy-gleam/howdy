import gleam/erlang/process
import howdy/dev

pub fn tasks_run_in_order_with_the_changes_test() {
  let seen = process.new_subject()
  let task = fn(name) {
    fn(changed) {
      process.send(seen, #(name, changed))
      Ok("")
    }
  }
  assert dev.run_tasks([task("first"), task("second")], ["locales/de.json"])
    == Ok(Nil)
  assert process.receive(seen, 0) == Ok(#("first", ["locales/de.json"]))
  assert process.receive(seen, 0) == Ok(#("second", ["locales/de.json"]))
}

pub fn a_failing_task_stops_the_rest_test() {
  let seen = process.new_subject()
  let fail = fn(_) { Error("bad catalogue") }
  let after = fn(_) {
    process.send(seen, "ran")
    Ok("")
  }
  assert dev.run_tasks([fail, after], []) == Error("bad catalogue")
  assert process.receive(seen, 0) == Error(Nil)
}
