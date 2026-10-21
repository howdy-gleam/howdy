//// Flag settings kept in one process, for tests and for an app on a single
//// node without a database. Everything is lost when the process stops, and
//// other nodes do not see it.
////
//// ```gleam
//// let store = memory.new()
//// let assert Ok(features) =
////   flags.new(store) |> flags.register(my_app.all_flags()) |> flags.start
//// ```
////
//// `stop` ends the process. Every call to the store, from then on or from
//// a store that stops answering, returns `Error(service.Internal)` rather
//// than crashing the caller.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import howdy/flags.{
  type Change, type Setting, type Snapshot, type Target, type Update, Change,
  Delete, GroupSummary, Save, Snapshot, Unchanged,
}
import howdy/flags/internal/time
import howdy/service

/// An empty store, in a process linked to the caller.
pub fn new() -> flags.Store {
  from(Snapshot(version: 0, settings: [], groups: []))
}

/// A store holding a snapshot to start with, such as one read with
/// `flags.snapshot_decoder` from a file.
pub fn from(snapshot: Snapshot) -> flags.Store {
  let assert Ok(started) =
    actor.new(
      State(
        version: snapshot.version,
        settings: dict.from_list(snapshot.settings),
        groups: list.map(snapshot.groups, fn(group) {
          #(group.name, #(group.description, group.members))
        })
          |> dict.from_list,
        changes: [],
      ),
    )
    |> actor.on_message(handle)
    |> actor.start
    as "howdy/flags/memory: the store process did not start"
  let subject = started.data
  flags.store(
    named: "memory",
    load: fn() { ask(subject, Load) },
    version: fn() { ask(subject, Version) },
    history: fn(flag, limit) { ask(subject, History(flag, limit, _)) },
  )
  |> flags.with_writer(
    flags.Writer(
      update: fn(key, by, decide) {
        ask(subject, UpdateFlag(key, by, decide, _)) |> result.flatten
      },
      find_change: fn(id) { ask(subject, FindChange(id, _)) |> result.flatten },
      create_group: fn(name, description, by) {
        ask(subject, CreateGroup(name, description, by, _)) |> result.flatten
      },
      delete_group: fn(name, by) {
        ask(subject, DeleteGroup(name, by, _)) |> result.flatten
      },
      add_member: fn(group, member, by) {
        ask(subject, AddMember(group, member, by, _)) |> result.flatten
      },
      remove_member: fn(group, member, by) {
        ask(subject, RemoveMember(group, member, by, _)) |> result.flatten
      },
    ),
  )
  |> flags.with_stop(fn() { stop_process(subject) })
}

/// End the store's process. Everything it held is gone, and every later
/// call to it, including from flags still running on it, returns an error.
/// Stopping a store that has already stopped does nothing.
pub fn stop(store: flags.Store) -> Nil {
  flags.stop_store(store)
}

fn stop_process(subject: Subject(Message)) -> Nil {
  case process.subject_owner(subject) {
    Ok(pid) ->
      case process.is_alive(pid) {
        True -> {
          let _ = ask(subject, Stop)
          Nil
        }
        False -> Nil
      }
    Error(Nil) -> Nil
  }
}

/// How long a call to the store waits before giving up. Its work is a
/// dictionary lookup, so this is only ever reached by a store that is
/// wedged or gone.
const timeout_ms = 5000

/// Ask the store's process and wait for the answer, without crashing the
/// caller when there is none: a store that has stopped, exits while
/// answering, or does not answer in time is an error to whoever asked.
fn ask(
  subject: Subject(Message),
  make: fn(Subject(a)) -> Message,
) -> service.Result(a) {
  case process.subject_owner(subject) {
    Error(Nil) -> Error(gone())
    Ok(pid) -> {
      let reply = process.new_subject()
      let monitor = process.monitor(pid)
      process.send(subject, make(reply))
      let outcome =
        process.new_selector()
        |> process.select_map(reply, Ok)
        |> process.select_specific_monitor(monitor, fn(_) { Error(gone()) })
        |> process.selector_receive(within: timeout_ms)
      process.demonitor_process(monitor)
      case outcome {
        Ok(answer) -> answer
        Error(Nil) ->
          Error(service.Internal(
            "the memory flag store did not answer within "
            <> int.to_string(timeout_ms)
            <> "ms",
          ))
      }
    }
  }
}

fn gone() -> service.Error {
  service.Internal("the memory flag store has stopped")
}

type State {
  State(
    version: Int,
    settings: Dict(String, Setting),
    groups: Dict(String, #(String, List(Target))),
    /// Newest first.
    changes: List(Change),
  )
}

type Message {
  Stop(reply: Subject(Nil))
  Load(reply: Subject(Snapshot))
  Version(reply: Subject(Int))
  History(flag: Option(String), limit: Int, reply: Subject(List(Change)))
  FindChange(id: Int, reply: Subject(service.Result(Change)))
  UpdateFlag(
    key: String,
    by: String,
    decide: fn(Option(Setting)) -> service.Result(Update),
    reply: Subject(service.Result(Bool)),
  )
  CreateGroup(
    name: String,
    description: String,
    by: String,
    reply: Subject(service.Result(Nil)),
  )
  DeleteGroup(name: String, by: String, reply: Subject(service.Result(Nil)))
  AddMember(
    group: String,
    member: Target,
    by: String,
    reply: Subject(service.Result(Nil)),
  )
  RemoveMember(
    group: String,
    member: Target,
    by: String,
    reply: Subject(service.Result(Nil)),
  )
}

/// Every change runs here, one at a time, which is what makes `update`
/// atomic.
fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Stop(reply) -> {
      process.send(reply, Nil)
      actor.stop()
    }
    Load(reply) -> {
      process.send(reply, snapshot(state))
      actor.continue(state)
    }
    Version(reply) -> {
      process.send(reply, state.version)
      actor.continue(state)
    }
    History(flag:, limit:, reply:) -> {
      state.changes
      |> list.filter(fn(change) { flag == None || change.flag == flag })
      |> list.take(limit)
      |> process.send(reply, _)
      actor.continue(state)
    }
    FindChange(id:, reply:) -> {
      list.find(state.changes, fn(change) { change.id == id })
      |> result.replace_error(service.NotFound("no such change"))
      |> process.send(reply, _)
      actor.continue(state)
    }
    UpdateFlag(key:, by:, decide:, reply:) -> {
      let before = dict.get(state.settings, key) |> option.from_result
      let #(state, outcome) = case decide(before) {
        Error(error) -> #(state, Error(error))
        Ok(Unchanged) -> #(state, Ok(False))
        Ok(Save(setting:, summary:)) -> #(
          State(..state, settings: dict.insert(state.settings, key, setting))
            |> record(Some(key), by, summary, before, Some(setting)),
          Ok(True),
        )
        Ok(Delete(summary:)) -> #(
          State(..state, settings: dict.delete(state.settings, key))
            |> record(Some(key), by, summary, before, None),
          Ok(True),
        )
      }
      process.send(reply, outcome)
      actor.continue(state)
    }
    CreateGroup(name:, description:, by:, reply:) ->
      answer(state, reply, case dict.has_key(state.groups, name) {
        True ->
          Error(service.Conflict("there is already a group named " <> name))
        False ->
          Ok(
            State(
              ..state,
              groups: dict.insert(state.groups, name, #(description, [])),
            )
            |> record(None, by, "Created group:" <> name, None, None),
          )
      })
    DeleteGroup(name:, by:, reply:) -> {
      let group = flags.Group(name)
      let using =
        dict.to_list(state.settings)
        |> list.filter_map(fn(row) {
          case
            list.contains({ row.1 }.allowed, group)
            || list.contains({ row.1 }.blocked, group)
          {
            True -> Ok(row.0)
            False -> Error(Nil)
          }
        })
        |> list.sort(string.compare)
      answer(state, reply, case using, dict.has_key(state.groups, name) {
        [_, ..], _ ->
          Error(service.Conflict(
            "remove the group from these flags first: "
            <> string.join(using, ", "),
          ))
        [], False -> Error(service.NotFound("no group named " <> name))
        [], True ->
          Ok(
            State(..state, groups: dict.delete(state.groups, name))
            |> record(None, by, "Deleted group:" <> name, None, None),
          )
      })
    }
    AddMember(group:, member:, by:, reply:) ->
      answer(state, reply, case dict.get(state.groups, group) {
        Error(Nil) -> Error(service.NotFound("no group named " <> group))
        Ok(#(_, members)) ->
          case list.contains(members, member) {
            True -> Error(service.Conflict("already in the group"))
            False ->
              Ok(
                members_of(state, group, list.append(members, [member]))
                |> record(
                  None,
                  by,
                  "Added "
                    <> flags.target_to_string(member)
                    <> " to group:"
                    <> group,
                  None,
                  None,
                ),
              )
          }
      })
    RemoveMember(group:, member:, by:, reply:) ->
      answer(state, reply, case dict.get(state.groups, group) {
        Ok(#(_, members)) ->
          case list.contains(members, member) {
            False -> Error(service.NotFound("not in the group"))
            True ->
              Ok(
                members_of(
                  state,
                  group,
                  list.filter(members, fn(m) { m != member }),
                )
                |> record(
                  None,
                  by,
                  "Removed "
                    <> flags.target_to_string(member)
                    <> " from group:"
                    <> group,
                  None,
                  None,
                ),
              )
          }
        Error(Nil) -> Error(service.NotFound("not in the group"))
      })
  }
}

fn answer(
  state: State,
  reply: Subject(service.Result(Nil)),
  outcome: service.Result(State),
) -> actor.Next(State, Message) {
  case outcome {
    Ok(changed) -> {
      process.send(reply, Ok(Nil))
      actor.continue(changed)
    }
    Error(error) -> {
      process.send(reply, Error(error))
      actor.continue(state)
    }
  }
}

fn members_of(state: State, group: String, members: List(Target)) -> State {
  State(
    ..state,
    groups: dict.upsert(state.groups, group, fn(existing) {
      case existing {
        Some(#(description, _)) -> #(description, members)
        None -> #("", members)
      }
    }),
  )
}

fn record(
  state: State,
  flag: Option(String),
  by: String,
  summary: String,
  before: Option(Setting),
  after: Option(Setting),
) -> State {
  let version = state.version + 1
  let at = time.now()
  State(..state, version:, changes: [
    Change(id: version, flag:, at:, by:, summary:, before:, after:),
    ..state.changes
  ])
}

fn snapshot(state: State) -> Snapshot {
  Snapshot(
    version: state.version,
    settings: dict.to_list(state.settings)
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) }),
    groups: dict.to_list(state.groups)
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
      |> list.map(fn(row) {
        let #(name, #(description, members)) = row
        GroupSummary(name:, description:, members:)
      }),
  )
}
