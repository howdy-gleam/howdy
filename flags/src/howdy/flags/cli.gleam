//// Command-line management of an app's flags, for servers without the
//// admin. Give it the app's flags and a way to open their store, in a task
//// module:
////
//// ```gleam
//// // src/tasks/flags.gleam
//// import howdy/flags/cli
//// import howdy/flags/database as flags_database
////
//// pub fn main() -> Nil {
////   cli.main(my_app.all_flags(), fn() {
////     flags_database.store(my_app.database())
////   })
//// }
//// ```
////
//// ```sh
//// gleam run -m tasks/flags list
//// gleam run -m tasks/flags rollout new_checkout 5
//// ```
////
//// In a release built with `gleam export erlang-shipment`, run it from the
//// release directory, with the arguments after `-extra`:
////
//// ```sh
//// erl -pa */ebin -noshell -eval 'tasks@flags:main()' -extra list
//// ```
////
//// Changes go straight to the store and running nodes pick them up at
//// their next check. Each is recorded as made by `--by`, or `cli:$USER`.
//// `export` needs no store: it prints the flags the code defines.

import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import howdy/flags.{type Flag, type Flags, type Setting, type Store}
import howdy/flags/internal/time
import howdy/service

const usage = "Manage feature flags.

Flags:
  export                       the flags the code defines, as JSON
  list [--json]                every flag and its state; --json prints
                               everything stored
  show KEY                     one flag in full
  check KEY [--user ID] [--org ID]
                               whether someone gets the flag, and why
  history [KEY] [--limit N]    the latest changes, newest first
  undo CHANGE                  put a flag back as it was before a change

Changing a flag:
  kill KEY                     turn it off for everyone
  revive KEY                   turn the kill switch off
  rollout KEY PERCENT          such as 5 or 12.5; pauses any ramp
  bucket KEY user|organization roll out by user or by organization
  allow KEY TARGET             TARGET is user:ID, org:ID or group:NAME
  block KEY TARGET
  unlist KEY TARGET            remove the rule for TARGET
  ramp KEY STEPS EVERY         such as 1,5,25,100 1h (s, m, h or d)
  pause KEY | resume KEY | cancel KEY
                               the flag's ramp
  reset KEY                    delete what is stored: back to the default

Groups:
  groups                       every group and its members
  group create NAME [DESCRIPTION...]
  group delete NAME
  group add NAME TARGET        TARGET is user:ID or org:ID
  group remove NAME TARGET

Options:
  --by NAME                    who the change is recorded as made by
"

/// What a command printed, and its exit status: 0 for success, 1 when the
/// command failed, 2 when it was not understood.
pub type Outcome {
  Outcome(status: Int, output: String)
}

/// Run the command the process was started with, print what it says, and
/// exit with its status.
pub fn main(defined: List(Flag), open: fn() -> service.Result(Store)) -> Nil {
  let Outcome(status:, output:) = run(defined, open, arguments())
  case status {
    0 -> io.print(output)
    _ -> io.print_error(output)
  }
  halt(status)
}

@external(erlang, "howdy_flags_ffi", "arguments")
fn arguments() -> List(String)

@external(erlang, "howdy_flags_ffi", "halt")
fn halt(status: Int) -> Nil

@external(erlang, "howdy_flags_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

type Options {
  Options(
    by: String,
    json: Bool,
    user: Option(String),
    organization: Option(String),
    limit: Int,
  )
}

/// Run one command without printing or exiting.
pub fn run(
  defined: List(Flag),
  open: fn() -> service.Result(Store),
  arguments: List(String),
) -> Outcome {
  let by = case getenv("USER") {
    Ok(user) if user != "" -> "cli:" <> user
    _ -> "cli"
  }
  case
    parse_options(
      arguments,
      [],
      Options(by:, json: False, user: None, organization: None, limit: 20),
    )
  {
    Error(message) -> misunderstood(message)
    Ok(#(words, options)) -> command(defined, open, words, options)
  }
}

fn parse_options(
  arguments: List(String),
  words: List(String),
  options: Options,
) -> Result(#(List(String), Options), String) {
  case arguments {
    [] -> Ok(#(list.reverse(words), options))
    ["--json", ..rest] ->
      parse_options(rest, words, Options(..options, json: True))
    ["--by", by, ..rest] -> parse_options(rest, words, Options(..options, by:))
    ["--user", id, ..rest] ->
      parse_options(rest, words, Options(..options, user: Some(id)))
    ["--org", id, ..rest] ->
      parse_options(rest, words, Options(..options, organization: Some(id)))
    ["--limit", n, ..rest] ->
      case int.parse(n) {
        Ok(limit) if limit > 0 ->
          parse_options(rest, words, Options(..options, limit:))
        _ -> Error("--limit takes a positive number")
      }
    ["--help", ..] | ["-h", ..] -> Ok(#(["help"], options))
    ["--" <> option, ..] -> Error("unknown option --" <> option)
    [word, ..rest] -> parse_options(rest, [word, ..words], options)
  }
}

fn command(
  defined: List(Flag),
  open: fn() -> service.Result(Store),
  words: List(String),
  options: Options,
) -> Outcome {
  let by = options.by
  case words {
    [] | ["help"] -> Outcome(0, usage)
    ["export"] -> {
      case flags.unique_keys(defined) {
        Ok(Nil) -> done(json.to_string(flags.to_json(defined)))
        Error(_) -> failed("two flags share a key")
      }
    }
    ["list"] -> {
      use features <- running(defined, open)
      use snapshot <- attempt(flags.snapshot(features))
      case options.json {
        True -> done(json.to_string(flags.snapshot_to_json(snapshot)))
        False -> done(list_flags(defined, snapshot.settings))
      }
    }
    ["show", key] -> {
      use features <- running(defined, open)
      use setting <- attempt(flags.setting(features, key))
      case find(defined, key), setting {
        None, None -> failed("no flag named " <> key)
        flag, setting -> done(show(key, flag, setting))
      }
    }
    ["check", key] -> {
      use features <- running(defined, open)
      case find(defined, key) {
        None -> failed("no flag named " <> key <> " is registered")
        Some(flag) -> {
          let actor = case options.user {
            Some(id) -> flags.user(id)
            None -> flags.anonymous()
          }
          let actor = case options.organization {
            Some(id) -> flags.in_organization(actor, id)
            None -> actor
          }
          let decision = flags.explain(features, flag, for: actor)
          done(
            case flags.is_on(decision) {
              True -> "on: "
              False -> "off: "
            }
            <> explanation(decision),
          )
        }
      }
    }
    ["history"] -> history(defined, open, None, options.limit)
    ["history", key] -> history(defined, open, Some(key), options.limit)
    ["undo", id] ->
      case int.parse(id) {
        Error(Nil) -> misunderstood("undo takes a change number from history")
        Ok(id) ->
          changing(defined, open, "Undone.", fn(features) {
            flags.undo(features, change: id, by:)
          })
      }
    ["kill", key] ->
      changing(defined, open, key <> " is killed.", flags.kill(_, key, by:))
    ["revive", key] ->
      changing(defined, open, key <> " is revived.", flags.revive(_, key, by:))
    ["rollout", key, percent] ->
      case flags.parse_percent(percent) {
        Error(Nil) -> misunderstood("a rollout is a percentage from 0 to 100")
        Ok(rollout) ->
          changing(
            defined,
            open,
            key
              <> " is rolled out to "
              <> flags.percent_to_string(rollout)
              <> ".",
            flags.set_rollout(_, key, to: rollout, by:),
          )
      }
    ["bucket", key, by_what] ->
      case by_what {
        "user" | "organization" ->
          changing(
            defined,
            open,
            key <> " is rolled out by " <> by_what <> ".",
            flags.set_bucketing(
              _,
              key,
              to: flags.bucketing_from_string(by_what),
              by:,
            ),
          )
        _ -> misunderstood("bucket takes user or organization")
      }
    ["allow", key, target] ->
      with_target(target, fn(target) {
        changing(defined, open, "Allowed.", flags.allow(_, key, target, by:))
      })
    ["block", key, target] ->
      with_target(target, fn(target) {
        changing(defined, open, "Blocked.", flags.block(_, key, target, by:))
      })
    ["unlist", key, target] ->
      with_target(target, fn(target) {
        changing(defined, open, "Removed.", flags.unlist(_, key, target, by:))
      })
    ["ramp", key, steps, every] -> {
      let steps =
        string.split(steps, ",")
        |> list.map(string.trim)
        |> list.filter(fn(step) { step != "" })
        |> list.try_map(flags.parse_percent)
      case steps, parse_duration(every) {
        Ok(steps), Ok(every) ->
          changing(defined, open, key <> " is ramping.", flags.start_ramp(
            _,
            key,
            steps:,
            every:,
            by:,
          ))
        Error(Nil), _ ->
          misunderstood("steps are percentages, such as 1,5,25,100")
        _, Error(Nil) ->
          misunderstood("EVERY is a duration such as 30m, 1h or 2d")
      }
    }
    ["pause", key] ->
      changing(defined, open, "Paused.", flags.pause_ramp(_, key, by:))
    ["resume", key] ->
      changing(defined, open, "Resumed.", flags.resume_ramp(_, key, by:))
    ["cancel", key] ->
      changing(defined, open, "Cancelled.", flags.cancel_ramp(_, key, by:))
    ["reset", key] ->
      changing(defined, open, key <> " is back to its default.", flags.forget(
        _,
        key,
        by:,
      ))
    ["groups"] -> {
      use features <- running(defined, open)
      use groups <- attempt(flags.groups(features))
      case groups {
        [] -> done("No groups.")
        _ ->
          done(
            list.map(groups, fn(group) {
              group.name
              <> case group.description {
                "" -> ""
                description -> " — " <> description
              }
              <> "\n  "
              <> case group.members {
                [] -> "(no members)"
                members ->
                  list.map(members, flags.target_to_string)
                  |> string.join(", ")
              }
            })
            |> string.join("\n"),
          )
      }
    }
    ["group", "create", name, ..description] ->
      changing(
        defined,
        open,
        "Created group:" <> name <> ".",
        flags.create_group(
          _,
          name,
          description: string.join(description, " "),
          by:,
        ),
      )
    ["group", "delete", name] ->
      changing(
        defined,
        open,
        "Deleted group:" <> name <> ".",
        flags.delete_group(_, name, by:),
      )
    ["group", "add", name, target] ->
      with_target(target, fn(target) {
        changing(defined, open, "Added.", flags.add_member(_, name, target, by:))
      })
    ["group", "remove", name, target] ->
      with_target(target, fn(target) {
        changing(defined, open, "Removed.", flags.remove_member(
          _,
          name,
          target,
          by:,
        ))
      })
    [word, ..] -> misunderstood("unknown command or arguments: " <> word)
  }
}

// -- Pieces ------------------------------------------------------------------

fn done(text: String) -> Outcome {
  Outcome(0, text <> "\n")
}

fn failed(message: String) -> Outcome {
  Outcome(1, "error: " <> message <> "\n")
}

fn misunderstood(message: String) -> Outcome {
  Outcome(2, "error: " <> message <> "\n\n" <> usage)
}

fn attempt(outcome: service.Result(a), next: fn(a) -> Outcome) -> Outcome {
  case outcome {
    Ok(value) -> next(value)
    Error(error) -> failed(service.message(error))
  }
}

/// Open the store and start the flags for the length of one command.
fn running(
  defined: List(Flag),
  open: fn() -> service.Result(Store),
  next: fn(Flags) -> Outcome,
) -> Outcome {
  use store <- attempt(open())
  use features <- attempt(
    flags.new(store) |> flags.register(defined) |> flags.start,
  )
  let outcome = next(features)
  flags.stop(features)
  outcome
}

fn changing(
  defined: List(Flag),
  open: fn() -> service.Result(Store),
  success: String,
  change: fn(Flags) -> service.Result(Nil),
) -> Outcome {
  use features <- running(defined, open)
  use _ <- attempt(change(features))
  done(success)
}

fn with_target(text: String, next: fn(flags.Target) -> Outcome) -> Outcome {
  case flags.target_from_string(text) {
    Ok(target) -> next(target)
    Error(Nil) -> misunderstood("a target is user:ID, org:ID or group:NAME")
  }
}

fn history(
  defined: List(Flag),
  open: fn() -> service.Result(Store),
  key: Option(String),
  limit: Int,
) -> Outcome {
  use features <- running(defined, open)
  use changes <- attempt(flags.history(features, of: key, limit:))
  case changes {
    [] -> done("No changes.")
    _ ->
      done(
        list.map(changes, fn(change) {
          string.pad_start(int.to_string(change.id), 5, " ")
          <> "  "
          <> when(change.at)
          <> "  "
          <> string.pad_end(option.unwrap(change.flag, "(groups)"), 24, " ")
          <> "  "
          <> change.summary
          <> "  ("
          <> change.by
          <> ")"
        })
        |> string.join("\n"),
      )
  }
}

fn list_flags(
  defined: List(Flag),
  settings: List(#(String, Setting)),
) -> String {
  let registered =
    list.map(defined, fn(flag) {
      let key = flags.key(flag)
      #(key, Some(flag), list.key_find(settings, key) |> option.from_result)
    })
  let orphans =
    list.filter_map(settings, fn(row) {
      case find(defined, row.0) {
        Some(_) -> Error(Nil)
        None -> Ok(#(row.0, None, Some(row.1)))
      }
    })
  case list.append(registered, orphans) {
    [] -> "No flags are registered."
    rows -> {
      let width =
        list.fold(rows, 0, fn(width, row) {
          int.max(width, string.length(row.0))
        })
      list.map(rows, fn(row) {
        let #(key, flag, setting) = row
        string.pad_end(key, width, " ")
        <> "  "
        <> state(flag, setting)
        <> case flag {
          Some(flag) -> "  " <> flags.description(flag)
          None -> "  (not in the code)"
        }
      })
      |> string.join("\n")
    }
  }
}

/// A flag's state in a few words, such as `killed, 5%, ramping`.
fn state(flag: Option(Flag), setting: Option(Setting)) -> String {
  case setting, flag {
    None, Some(flag) ->
      case flags.default(flag) {
        True -> "default on"
        False -> "default off"
      }
    None, None -> ""
    Some(setting), _ ->
      list.flatten([
        case setting.killed {
          True -> ["killed"]
          False -> []
        },
        [flags.percent_to_string(setting.rollout)],
        case setting.ramp {
          Some(flags.Ramp(next: Some(_), ..)) -> ["ramping"]
          Some(flags.Ramp(next: None, ..)) -> ["ramp paused"]
          None -> []
        },
        case list.length(setting.allowed) + list.length(setting.blocked) {
          0 -> []
          1 -> ["1 rule"]
          n -> [int.to_string(n) <> " rules"]
        },
      ])
      |> string.join(", ")
  }
}

fn show(key: String, flag: Option(Flag), setting: Option(Setting)) -> String {
  let line = fn(label, value) {
    "  " <> string.pad_end(label <> ":", 10, " ") <> value
  }
  let targets = fn(targets) {
    case targets {
      [] -> "none"
      _ -> list.map(targets, flags.target_to_string) |> string.join(", ")
    }
  }
  [
    key
      <> case flag {
      Some(flag) -> " — " <> flags.description(flag)
      None -> " — not in the code"
    },
    ..case flag {
      Some(flag) -> [
        line("default", case flags.default(flag) {
          True -> "on"
          False -> "off"
        }),
      ]
      None -> []
    }
  ]
  |> list.append(case setting {
    None -> [line("stored", "nothing: the default applies")]
    Some(setting) -> [
      line("killed", case setting.killed {
        True -> "yes"
        False -> "no"
      }),
      line(
        "rollout",
        flags.percent_to_string(setting.rollout)
          <> " by "
          <> flags.bucketing_to_string(setting.bucketing),
      ),
      line("ramp", case setting.ramp {
        None -> "none"
        Some(ramp) ->
          string.join(list.map(ramp.steps, flags.percent_to_string), " → ")
          <> " every "
          <> time.duration(ramp.every)
          <> case ramp.next {
            Some(next) -> ", next step " <> when(next)
            None -> ", paused"
          }
      }),
      line("allowed", targets(setting.allowed)),
      line("blocked", targets(setting.blocked)),
    ]
  })
  |> string.join("\n")
}

fn explanation(decision: flags.Decision) -> String {
  case decision {
    flags.Default(on:) ->
      "nothing is stored, so the default applies ("
      <> case on {
        True -> "on"
        False -> "off"
      }
      <> ")"
    flags.Killed -> "the kill switch is on"
    flags.Blocked(target) -> "blocked for " <> flags.target_to_string(target)
    flags.Allowed(target) -> "allowed for " <> flags.target_to_string(target)
    flags.InRollout(position:, rollout:) ->
      "position "
      <> flags.percent_to_string(position)
      <> " is inside the rollout of "
      <> flags.percent_to_string(rollout)
    flags.OutsideRollout(position:, rollout:) ->
      "position "
      <> flags.percent_to_string(position)
      <> " is outside the rollout of "
      <> flags.percent_to_string(rollout)
    flags.NoPosition(bucketing) ->
      "no "
      <> flags.bucketing_to_string(bucketing)
      <> " was given and the rollout is by "
      <> flags.bucketing_to_string(bucketing)
      <> ", so only 100% includes them"
  }
}

fn find(defined: List(Flag), key: String) -> Option(Flag) {
  list.find(defined, fn(flag) { flags.key(flag) == key })
  |> option.from_result
}

/// Seconds from `90s`, `30m`, `1h`, `2d` or a bare number of seconds.
fn parse_duration(text: String) -> Result(Int, Nil) {
  let text = string.trim(text)
  let #(number, unit) = case string.last(text) {
    Ok("s") -> #(string.drop_end(text, 1), 1)
    Ok("m") -> #(string.drop_end(text, 1), 60)
    Ok("h") -> #(string.drop_end(text, 1), 3600)
    Ok("d") -> #(string.drop_end(text, 1), 86_400)
    _ -> #(text, 1)
  }
  case int.parse(number) {
    Ok(n) if n > 0 -> Ok(n * unit)
    _ -> Error(Nil)
  }
}

fn when(seconds: Int) -> String {
  timestamp.from_unix_seconds(seconds)
  |> timestamp.to_rfc3339(calendar.utc_offset)
}
