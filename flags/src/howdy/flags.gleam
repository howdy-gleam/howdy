//// Feature flags, defined in code and switched while the app runs.
////
//// A flag is declared in code with its default, so it works with nothing
//// stored: in tests, on a fresh deployment, and on any node that has not
//// heard of a change yet. A store keeps only what someone changed:
////
//// - a kill switch, which turns the flag off for everyone at once;
//// - users, organizations and groups it is blocked for, or allowed for;
//// - a rollout: the share of users (or organizations) who get it, from 0
////   to 100%, optionally raised step by step on a schedule.
////
//// ```gleam
//// pub fn new_checkout() -> flags.Flag {
////   flags.flag("new_checkout", description: "Stripe-hosted checkout")
//// }
////
//// let assert Ok(store) = flags_database.store(db)
//// let assert Ok(features) =
////   flags.new(store) |> flags.register([new_checkout()]) |> flags.start
////
//// case flags.enabled(features, new_checkout(), for: flags.user(user.id)) {
////   True -> new_checkout_page(ctx)
////   False -> checkout_page(ctx)
//// }
//// ```
////
//// Checks read an in-memory copy of the settings and never touch the
//// store. Changes made on this node apply before the call that made them
//// returns; other nodes pick them up the next time they check for changes,
//// every two seconds unless `check_every` says otherwise.
////
//// In an app, put the keeper under a supervisor with `supervised`: the
//// handle it returns keeps working across restarts.
////
//// ## Stores
////
//// Where the settings are kept is up to a `Store`:
//// `howdy/flags/database` keeps them in a Gloo Repo, `howdy/flags/memory`
//// in one process, and `store` builds one over anything else, such as a
//// service that manages the flags for you. A store without a writer is
//// read-only: the flags are changed wherever it gets them from.
////
//// ## Rollouts
////
//// Everyone has a position from 0 to 99.99% for each flag, worked out from
//// the flag's key and their id, so it never changes and needs nothing
//// stored. A rollout of 20% is on for everyone below 20%. Raising it only
//// adds people; lowering it takes away the most recently added first, so
//// rolling back from 20% to 5% leaves the first 5% as they were. Because the
//// key is part of it, a different 5% go first for each flag.
////
//// Rolling back a flag changes which code runs, not the data the new code
//// already wrote: the old path has to cope with it.
////
//// Management operations such as `set_rollout` are privileged: authorize
//// the caller first. Each is recorded in the flag's history under the name
//// given as `by`, and can be undone.

import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/erlang/reference.{type Reference}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import howdy/flags/internal/time
import howdy/service
import logging

// -- Defining flags ----------------------------------------------------------

/// A flag as the code knows it: its key, what it is for, and whether it is
/// on when nothing has been stored for it.
pub opaque type Flag {
  Flag(key: String, description: String, default: Bool)
}

/// A flag that is off until someone turns it on. The key is 1 to 100 of
/// `a-z`, `0-9`, `_`, `.` and `-`; it is how the flag is stored, so renaming
/// it starts the flag afresh.
pub fn flag(key: String, description description: String) -> Flag {
  let assert True = valid_name(key)
    as "howdy/flags: a flag key is 1 to 100 of a-z, 0-9, _, . and -"
  Flag(key:, description:, default: False)
}

/// A flag that is on until someone changes it, such as a finished feature
/// kept behind a kill switch.
pub fn on_by_default(flag: Flag) -> Flag {
  Flag(..flag, default: True)
}

pub fn key(flag: Flag) -> String {
  flag.key
}

pub fn description(flag: Flag) -> String {
  flag.description
}

pub fn default(flag: Flag) -> Bool {
  flag.default
}

fn valid_name(name: String) -> Bool {
  let length = string.length(name)
  length >= 1
  && length <= 100
  && list.all(string.to_graphemes(name), fn(c) {
    string.contains("abcdefghijklmnopqrstuvwxyz0123456789_.-", c)
  })
}

// -- Who is asking -----------------------------------------------------------

/// Who a flag is being checked for: a user, the organization they are
/// acting in, both, or neither. The ids are yours, such as a
/// `howdy_auth` user id.
pub opaque type Actor {
  Actor(user: Option(String), organization: Option(String))
}

pub fn user(id: String) -> Actor {
  Actor(user: Some(id), organization: None)
}

/// An organization on its own, such as for a background job run for it.
pub fn organization(id: String) -> Actor {
  Actor(user: None, organization: Some(id))
}

/// Someone signed out. Only a flag's default, its kill switch and a
/// rollout of 100% apply to them.
pub fn anonymous() -> Actor {
  Actor(user: None, organization: None)
}

/// The organization the actor is acting in, for groups and rules that name
/// it and for rollouts by organization.
pub fn in_organization(actor: Actor, id: String) -> Actor {
  Actor(..actor, organization: Some(id))
}

// -- Settings ----------------------------------------------------------------

/// Who a rule or a group membership is about.
pub type Target {
  User(String)
  Organization(String)
  Group(String)
}

/// How a target is stored and shown: `user:<id>`, `org:<id>` or
/// `group:<name>`.
pub fn target_to_string(target: Target) -> String {
  case target {
    User(id) -> "user:" <> id
    Organization(id) -> "org:" <> id
    Group(name) -> "group:" <> name
  }
}

/// Parse what `target_to_string` produced.
pub fn target_from_string(text: String) -> Result(Target, Nil) {
  case string.split_once(string.trim(text), ":") {
    Ok(#("user", id)) if id != "" -> Ok(User(id))
    Ok(#("org", id)) if id != "" -> Ok(Organization(id))
    Ok(#("group", name)) if name != "" -> Ok(Group(name))
    _ -> Error(Nil)
  }
}

fn valid_target(target: Target) -> service.Result(Nil) {
  case target {
    Group(name) ->
      case valid_name(name) {
        True -> Ok(Nil)
        False -> Error(service.Invalid("no group can be named " <> name))
      }
    User(id) | Organization(id) ->
      case id != "" && string.length(id) <= 200 {
        True -> Ok(Nil)
        False -> Error(service.Invalid("an id is 1 to 200 characters"))
      }
  }
}

/// What a rollout's positions are worked out from. By organization, everyone
/// in an organization is in or out together.
pub type Bucketing {
  ByUser
  ByOrganization
}

/// A rollout raised a step at a time. `steps` are rollouts in hundredths of
/// a percent, rising; the next one is taken `every` seconds, at `next` (unix
/// seconds). A paused ramp has no `next`.
pub type Ramp {
  Ramp(steps: List(Int), every: Int, next: Option(Int))
}

/// What is stored for a flag. `rollout` is in hundredths of a percent: 0 is
/// nobody, 2500 a quarter, 10000 everyone.
pub type Setting {
  Setting(
    killed: Bool,
    rollout: Int,
    bucketing: Bucketing,
    allowed: List(Target),
    blocked: List(Target),
    ramp: Option(Ramp),
  )
}

/// The setting a flag starts from the first time it is changed: what its
/// default already did.
fn initial(flag: Flag) -> Setting {
  Setting(
    killed: False,
    rollout: case flag.default {
      True -> 10_000
      False -> 0
    },
    bucketing: ByUser,
    allowed: [],
    blocked: [],
    ramp: None,
  )
}

/// A rollout from a whole percentage, such as `percent(25)`.
pub fn percent(whole: Int) -> Int {
  whole * 100
}

/// A rollout as people read it, such as `25%` or `0.5%`.
pub fn percent_to_string(rollout: Int) -> String {
  let whole = int.to_string(rollout / 100)
  // Tenths and hundredths, with a trailing zero dropped: 50 is 0.5%, 5 is
  // 0.05%, 1250 is 12.5%.
  case rollout % 100 {
    0 -> whole <> "%"
    part if part % 10 == 0 -> whole <> "." <> int.to_string(part / 10) <> "%"
    part if part < 10 -> whole <> ".0" <> int.to_string(part) <> "%"
    part -> whole <> "." <> int.to_string(part) <> "%"
  }
}

// -- Checking ----------------------------------------------------------------

/// Why a flag is on or off for someone.
pub type Decision {
  /// Nothing is stored for the flag; its default applies.
  Default(on: Bool)
  /// The kill switch is on.
  Killed
  /// A block rule matched, for this target.
  Blocked(Target)
  /// An allow rule matched, for this target.
  Allowed(Target)
  /// Their position is below the rollout. Both are in hundredths of a
  /// percent.
  InRollout(position: Int, rollout: Int)
  /// Their position is at or above the rollout.
  OutsideRollout(position: Int, rollout: Int)
  /// The rollout is by user or organization, and they have none, so they
  /// only get the flag at 100%.
  NoPosition(Bucketing)
}

pub fn is_on(decision: Decision) -> Bool {
  case decision {
    Default(on:) -> on
    Allowed(_) | InRollout(..) -> True
    Killed | Blocked(_) | OutsideRollout(..) | NoPosition(_) -> False
  }
}

/// Whether the flag is on for this actor. Never touches the store.
pub fn enabled(flags: Flags, flag: Flag, for actor: Actor) -> Bool {
  is_on(explain(flags, flag, for: actor))
}

/// Whether the flag is on for this actor, and why, checked in this order:
/// the kill switch, block rules, allow rules, then the rollout.
pub fn explain(flags: Flags, flag: Flag, for actor: Actor) -> Decision {
  // Nothing is published between `stop` and a restart: the default applies.
  case current(flags.key) {
    Error(Nil) -> Default(flag.default)
    Ok(snapshot) ->
      case dict.get(snapshot.settings, flag.key) {
        Error(Nil) -> Default(flag.default)
        Ok(setting) -> decide(flag.key, setting, actor, snapshot.groups)
      }
  }
}

/// `groups` maps a stored user or organization target to the groups it is
/// in.
@internal
pub fn decide(
  key: String,
  setting: Setting,
  actor: Actor,
  groups: Dict(String, List(String)),
) -> Decision {
  let direct =
    option.values([
      option.map(actor.user, User),
      option.map(actor.organization, Organization),
    ])
  let targets =
    list.append(
      direct,
      list.flat_map(direct, fn(target) {
        dict.get(groups, target_to_string(target))
        |> result.unwrap([])
        |> list.map(Group)
      }),
    )
  let matching = fn(rules: List(Target)) {
    list.find(rules, list.contains(targets, _))
  }
  use <- bool_guard(setting.killed, Killed)
  case matching(setting.blocked), matching(setting.allowed) {
    Ok(target), _ -> Blocked(target)
    _, Ok(target) -> Allowed(target)
    Error(Nil), Error(Nil) -> {
      let by = case setting.bucketing {
        ByUser -> option.map(actor.user, User)
        ByOrganization -> option.map(actor.organization, Organization)
      }
      case by, setting.rollout {
        // Everyone means everyone, signed in or not.
        _, 10_000 -> InRollout(position: 0, rollout: 10_000)
        None, _ -> NoPosition(setting.bucketing)
        Some(target), rollout -> {
          let position = position(key, target)
          case position < rollout {
            True -> InRollout(position:, rollout:)
            False -> OutsideRollout(position:, rollout:)
          }
        }
      }
    }
  }
}

fn bool_guard(when: Bool, then: a, otherwise: fn() -> a) -> a {
  case when {
    True -> then
    False -> otherwise()
  }
}

/// A target's position for a flag, from 0 to 9999: the first 32 bits of a
/// SHA-256 of both. It must never change, or a rollout would move people in
/// and out of it.
@internal
pub fn position(key: String, target: Target) -> Int {
  let assert <<n:32, _:bits>> =
    crypto.hash(crypto.Sha256, <<
      key:utf8,
      "\n":utf8,
      target_to_string(target):utf8,
    >>)
  n % 10_000
}

// -- Listing flags for other tools -------------------------------------------

/// The flags as JSON, for tools outside the app, such as one that prepares
/// a database before the flags are turned on. Nothing is read from a
/// database: this is what the code defines.
///
/// ```json
/// {"format": 1, "flags": [
///   {"key": "new_checkout", "description": "Stripe-hosted checkout", "default": false}
/// ]}
/// ```
///
/// `format` changes only if a field changes meaning or goes away; new
/// fields may be added.
pub fn to_json(flags: List(Flag)) -> json.Json {
  json.object([
    #("format", json.int(1)),
    #(
      "flags",
      json.array(flags, fn(flag) {
        json.object([
          #("key", json.string(flag.key)),
          #("description", json.string(flag.description)),
          #("default", json.bool(flag.default)),
        ])
      }),
    ),
  ])
}

/// Print `to_json` on standard output, from a task module that lists the
/// app's flags:
///
/// ```gleam
/// // src/tasks/flags.gleam, run with `gleam run -m tasks/flags`
/// pub fn main() -> Nil {
///   flags.export(my_app.flags())
/// }
/// ```
///
/// Panics, so the command fails, when two flags share a key.
pub fn export(flags: List(Flag)) -> Nil {
  let assert Ok(Nil) = unique_keys(flags)
    as "howdy/flags: two flags share a key"
  io.println(json.to_string(to_json(flags)))
}

/// `Invalid` when two of the flags share a key. The CLI checks the same.
@internal
pub fn unique_keys(flags: List(Flag)) -> service.Result(Nil) {
  let keys = list.map(flags, fn(flag) { flag.key })
  case list.unique(keys) == keys {
    True -> Ok(Nil)
    False -> Error(service.Invalid("two registered flags share a key"))
  }
}

// -- Changing a flag ---------------------------------------------------------

/// Turn the flag off for everyone, whatever else it says, and pause any
/// ramp. Its other settings are kept for when it is revived.
pub fn kill(flags: Flags, key: String, by by: String) -> service.Result(Nil) {
  use setting <- change(flags, key, by)
  Ok(#(Setting(..setting, killed: True, ramp: pause(setting.ramp)), "Killed"))
}

/// Turn the kill switch off again. A paused ramp stays paused.
pub fn revive(flags: Flags, key: String, by by: String) -> service.Result(Nil) {
  use setting <- change(flags, key, by)
  Ok(#(Setting(..setting, killed: False), "Revived"))
}

/// Set the rollout, in hundredths of a percent (see `percent`). A ramp is
/// paused, so it does not undo a rollback at its next step.
pub fn set_rollout(
  flags: Flags,
  key: String,
  to rollout: Int,
  by by: String,
) -> service.Result(Nil) {
  use <- valid_rollout(rollout)
  use setting <- change(flags, key, by)
  Ok(#(
    Setting(..setting, rollout:, ramp: pause(setting.ramp)),
    "Rollout "
      <> percent_to_string(setting.rollout)
      <> " → "
      <> percent_to_string(rollout),
  ))
}

fn valid_rollout(
  rollout: Int,
  next: fn() -> service.Result(Nil),
) -> service.Result(Nil) {
  case rollout >= 0 && rollout <= 10_000 {
    True -> next()
    False ->
      Error(service.Invalid("a rollout is 0 to 10000 hundredths of a percent"))
  }
}

/// Work out rollout positions by user or by organization. Changing it
/// reshuffles who is in the rollout.
pub fn set_bucketing(
  flags: Flags,
  key: String,
  to bucketing: Bucketing,
  by by: String,
) -> service.Result(Nil) {
  use setting <- change(flags, key, by)
  Ok(
    #(Setting(..setting, bucketing:), case bucketing {
      ByUser -> "Rollout by user"
      ByOrganization -> "Rollout by organization"
    }),
  )
}

/// Turn the flag on for a target whatever the rollout, unless the kill
/// switch is on or it is blocked. Replaces a block rule for the same target.
pub fn allow(
  flags: Flags,
  key: String,
  target: Target,
  by by: String,
) -> service.Result(Nil) {
  use _ <- result.try(valid_target(target))
  use setting <- change(flags, key, by)
  Ok(#(
    Setting(
      ..setting,
      allowed: [target, ..list.filter(setting.allowed, fn(t) { t != target })],
      blocked: list.filter(setting.blocked, fn(t) { t != target }),
    ),
    "Allowed " <> target_to_string(target),
  ))
}

/// Turn the flag off for a target whatever else applies. Replaces an allow
/// rule for the same target.
pub fn block(
  flags: Flags,
  key: String,
  target: Target,
  by by: String,
) -> service.Result(Nil) {
  use _ <- result.try(valid_target(target))
  use setting <- change(flags, key, by)
  Ok(#(
    Setting(
      ..setting,
      allowed: list.filter(setting.allowed, fn(t) { t != target }),
      blocked: [target, ..list.filter(setting.blocked, fn(t) { t != target })],
    ),
    "Blocked " <> target_to_string(target),
  ))
}

/// Remove the allow or block rule for a target.
pub fn unlist(
  flags: Flags,
  key: String,
  target: Target,
  by by: String,
) -> service.Result(Nil) {
  use setting <- change(flags, key, by)
  Ok(#(
    Setting(
      ..setting,
      allowed: list.filter(setting.allowed, fn(t) { t != target }),
      blocked: list.filter(setting.blocked, fn(t) { t != target }),
    ),
    "Removed the rule for " <> target_to_string(target),
  ))
}

/// Raise the rollout through `steps` (hundredths of a percent, rising),
/// taking the first step above the current rollout now and the next every
/// `every` seconds. Pause it, or roll back, at any point.
pub fn start_ramp(
  flags: Flags,
  key: String,
  steps steps: List(Int),
  every every: Int,
  by by: String,
) -> service.Result(Nil) {
  use _ <- result.try(
    case
      steps != []
      && list.all(steps, fn(step) { step > 0 && step <= 10_000 })
      && list.sort(steps, int.compare) == steps
      && list.unique(steps) == steps
    {
      True -> Ok(Nil)
      False ->
        Error(service.Invalid(
          "ramp steps are rising rollouts from 1 to 10000 hundredths of a percent",
        ))
    },
  )
  use _ <- result.try(case every >= 1 {
    True -> Ok(Nil)
    False -> Error(service.Invalid("a ramp takes a step at most every second"))
  })
  let now = time.now()
  use setting <- change(flags, key, by)
  use <- refuse_killed(setting)
  let ramp = Ramp(steps:, every:, next: None)
  case step(setting, ramp, now) {
    Error(Nil) ->
      Error(service.Conflict("the rollout is already at the ramp's last step"))
    Ok(after) ->
      Ok(#(
        after,
        "Ramp "
          <> string.join(list.map(steps, percent_to_string), " → ")
          <> " every "
          <> time.duration(every)
          <> ", now at "
          <> percent_to_string(after.rollout),
      ))
  }
}

/// Stop a ramp where it is. Nobody gains or loses the flag until it is
/// resumed or the rollout is changed.
pub fn pause_ramp(
  flags: Flags,
  key: String,
  by by: String,
) -> service.Result(Nil) {
  use setting <- change(flags, key, by)
  case setting.ramp {
    Some(Ramp(next: Some(_), ..)) ->
      Ok(#(Setting(..setting, ramp: pause(setting.ramp)), "Ramp paused"))
    _ -> Error(service.Conflict("the flag has no running ramp"))
  }
}

/// Carry on with a paused ramp: its next step is `every` seconds from now.
pub fn resume_ramp(
  flags: Flags,
  key: String,
  by by: String,
) -> service.Result(Nil) {
  let now = time.now()
  use setting <- change(flags, key, by)
  use <- refuse_killed(setting)
  case setting.ramp {
    Some(Ramp(next: None, ..) as ramp) ->
      Ok(#(
        Setting(
          ..setting,
          ramp: Some(Ramp(..ramp, next: Some(now + ramp.every))),
        ),
        "Ramp resumed",
      ))
    _ -> Error(service.Conflict("the flag has no paused ramp"))
  }
}

/// Drop the ramp, leaving the rollout where it is.
pub fn cancel_ramp(
  flags: Flags,
  key: String,
  by by: String,
) -> service.Result(Nil) {
  use setting <- change(flags, key, by)
  case setting.ramp {
    Some(_) -> Ok(#(Setting(..setting, ramp: None), "Ramp cancelled"))
    None -> Error(service.Conflict("the flag has no ramp"))
  }
}

fn refuse_killed(
  setting: Setting,
  next: fn() -> service.Result(a),
) -> service.Result(a) {
  case setting.killed {
    True -> Error(service.Conflict("revive the flag first"))
    False -> next()
  }
}

fn pause(ramp: Option(Ramp)) -> Option(Ramp) {
  option.map(ramp, fn(ramp) { Ramp(..ramp, next: None) })
}

/// Take the ramp's next step above the rollout. The ramp ends at its last
/// step. `Error` when there is no step left.
fn step(setting: Setting, ramp: Ramp, now: Int) -> Result(Setting, Nil) {
  use rollout <- result.map(
    list.find(ramp.steps, fn(step) { step > setting.rollout }),
  )
  let ramp = case list.any(ramp.steps, fn(step) { step > rollout }) {
    True -> Some(Ramp(..ramp, next: Some(now + ramp.every)))
    False -> None
  }
  Setting(..setting, rollout:, ramp:)
}

/// Delete what is stored for a flag, putting it back to its default. Works
/// for keys that are no longer registered, to tidy them away.
pub fn forget(flags: Flags, key: String, by by: String) -> service.Result(Nil) {
  use writer <- writing(flags)
  use <- refreshing(flags)
  writer.update(key, by, fn(stored) {
    case stored {
      None -> Error(service.NotFound("nothing is stored for " <> key))
      Some(_) -> Ok(Delete("Reset to the default"))
    }
  })
  |> result.replace(Nil)
}

/// Take the flag back to how it was before a change: the change's `before`,
/// with any ramp paused so it does not step straight away. Recorded as a
/// change of its own.
pub fn undo(
  flags: Flags,
  change id: Int,
  by by: String,
) -> service.Result(Nil) {
  use writer <- writing(flags)
  use change <- result.try(writer.find_change(id))
  case change.flag {
    None -> Error(service.Invalid("only changes to a flag can be undone"))
    Some(key) -> {
      let restored =
        option.map(change.before, fn(setting) {
          Setting(..setting, ramp: pause(setting.ramp))
        })
      let summary = "Undid “" <> change.summary <> "”"
      use <- refreshing(flags)
      writer.update(key, by, fn(stored) {
        Ok(case restored {
          _ if restored == stored -> Unchanged
          Some(setting) -> Save(setting, summary)
          None -> Delete(summary)
        })
      })
      |> result.replace(Nil)
    }
  }
}

/// Apply `update` to a registered flag's setting, or to what its default
/// did when nothing is stored, and reload this node. An update that changes
/// nothing records nothing.
fn change(
  flags: Flags,
  key: String,
  by: String,
  update: fn(Setting) -> service.Result(#(Setting, String)),
) -> service.Result(Nil) {
  use writer <- writing(flags)
  use flag <- result.try(
    list.find(flags.defined, fn(flag) { flag.key == key })
    |> result.replace_error(service.NotFound(
      "no flag named " <> key <> " is registered",
    )),
  )
  use <- refreshing(flags)
  writer.update(key, by, fn(stored) {
    let current = option.unwrap(stored, initial(flag))
    use #(after, summary) <- result.map(update(current))
    case after == current {
      True -> Unchanged
      False -> Save(after, summary)
    }
  })
  |> result.replace(Nil)
}

/// The store's writer, or an error saying the flags are managed elsewhere.
fn writing(
  flags: Flags,
  next: fn(Writer) -> service.Result(a),
) -> service.Result(a) {
  case flags.store.writer {
    Some(writer) -> next(writer)
    None ->
      Error(service.Invalid(
        "these flags are read-only here: change them where they are kept ("
        <> flags.store.name
        <> ")",
      ))
  }
}

fn refreshing(
  flags: Flags,
  run: fn() -> service.Result(Nil),
) -> service.Result(Nil) {
  use _ <- result.try(run())
  refresh(flags)
}

// -- Ramps -------------------------------------------------------------------

/// Take every ramp step due at `now`. Several nodes may try the same step:
/// the store's `update` sees the setting as it is stored, and a step that
/// is no longer due changes nothing. Returns how many steps were taken.
@internal
pub fn advance_ramps(flags: Flags, now: Int) -> service.Result(Int) {
  advance(flags.store, result.unwrap(current(flags.key), empty()), now)
}

fn advance(store: Store, index: Index, now: Int) -> service.Result(Int) {
  case store.writer {
    None -> Ok(0)
    Some(writer) -> {
      let keys =
        dict.to_list(index.settings)
        |> list.filter_map(fn(row) {
          case due(row.1, now) {
            True -> Ok(row.0)
            False -> Error(Nil)
          }
        })
      list.try_fold(keys, 0, fn(taken, key) {
        use stepped <- result.map(
          writer.update(key, "ramp", fn(stored) {
            Ok(case stored {
              Some(Setting(ramp: Some(ramp), ..) as setting) ->
                case due(setting, now) {
                  False -> Unchanged
                  True ->
                    case step(setting, ramp, now) {
                      Ok(after) ->
                        Save(
                          after,
                          "Ramp step "
                            <> percent_to_string(setting.rollout)
                            <> " → "
                            <> percent_to_string(after.rollout),
                        )
                      Error(Nil) ->
                        Save(Setting(..setting, ramp: None), "Ramp finished")
                    }
                }
              // Paused, cancelled or reset meanwhile.
              _ -> Unchanged
            })
          }),
        )
        case stepped {
          True -> taken + 1
          False -> taken
        }
      })
    }
  }
}

fn due(setting: Setting, now: Int) -> Bool {
  case setting.ramp {
    Some(Ramp(next: Some(next), ..)) -> next <= now && !setting.killed
    _ -> False
  }
}

// -- Groups ------------------------------------------------------------------

pub fn create_group(
  flags: Flags,
  name: String,
  description description: String,
  by by: String,
) -> service.Result(Nil) {
  use _ <- result.try(valid_target(Group(name)))
  use writer <- writing(flags)
  use <- refreshing(flags)
  writer.create_group(name, string.trim(description), by)
}

/// Delete a group and its memberships. Refused while a flag's rule names
/// it, so a flag cannot change behind its history's back.
pub fn delete_group(
  flags: Flags,
  name: String,
  by by: String,
) -> service.Result(Nil) {
  use writer <- writing(flags)
  use <- refreshing(flags)
  writer.delete_group(name, by)
}

/// Add a user or organization to a group.
pub fn add_member(
  flags: Flags,
  group: String,
  member: Target,
  by by: String,
) -> service.Result(Nil) {
  use _ <- result.try(case member {
    Group(_) -> Error(service.Invalid("groups hold users and organizations"))
    _ -> valid_target(member)
  })
  use writer <- writing(flags)
  use <- refreshing(flags)
  writer.add_member(group, member, by)
}

pub fn remove_member(
  flags: Flags,
  group: String,
  member: Target,
  by by: String,
) -> service.Result(Nil) {
  use writer <- writing(flags)
  use <- refreshing(flags)
  writer.remove_member(group, member, by)
}

// -- Reading what is stored --------------------------------------------------

/// Everything the store keeps, read from it rather than the in-memory copy.
pub fn snapshot(flags: Flags) -> service.Result(Snapshot) {
  flags.store.load()
}

/// Every stored setting, by flag key, including keys no longer registered.
/// Read from the store, not the in-memory copy.
pub fn settings(flags: Flags) -> service.Result(List(#(String, Setting))) {
  use snapshot <- result.map(flags.store.load())
  snapshot.settings
}

/// What is stored for one flag, if anything.
pub fn setting(flags: Flags, key: String) -> service.Result(Option(Setting)) {
  use settings <- result.map(settings(flags))
  list.key_find(settings, key) |> option.from_result
}

/// Every group, by name, with its members.
pub fn groups(flags: Flags) -> service.Result(List(GroupSummary)) {
  use snapshot <- result.map(flags.store.load())
  snapshot.groups
}

/// The latest changes, newest first: every change, or only one flag's.
pub fn history(
  flags: Flags,
  of flag: Option(String),
  limit limit: Int,
) -> service.Result(List(Change)) {
  flags.store.history(flag, int.clamp(limit, 1, 1000))
}

// -- Stores ------------------------------------------------------------------

/// A named set of users and organizations that rules can target.
pub type GroupSummary {
  GroupSummary(name: String, description: String, members: List(Target))
}

/// One recorded change. A change to a flag keeps the setting before and
/// after it (`None` when nothing was stored) and can be undone; group
/// changes have no flag. `at` is in unix seconds; ids rise in the order
/// changes were made.
pub type Change {
  Change(
    id: Int,
    flag: Option(String),
    at: Int,
    by: String,
    summary: String,
    before: Option(Setting),
    after: Option(Setting),
  )
}

/// Everything a store keeps for the flags at one moment. `version` rises
/// with every change.
pub type Snapshot {
  Snapshot(
    version: Int,
    settings: List(#(String, Setting)),
    groups: List(GroupSummary),
  )
}

/// What a change to one flag does to what is stored for it.
pub type Update {
  /// Nothing changes and nothing is recorded.
  Unchanged
  /// Store this setting, recorded with this summary.
  Save(setting: Setting, summary: String)
  /// Delete what is stored, recorded with this summary.
  Delete(summary: String)
}

/// How a store changes what it keeps. Every change is recorded as a
/// `Change` made by the name given (`by`) and raises the snapshot's
/// version, together with the change itself. The arguments are validated
/// before a store sees them.
///
/// - `update(key, by, decide)`: in one atomic step, read what is stored for
///   `key`, pass it to `decide`, and store and record what it returns.
///   `Ok(True)` when something changed. Two updates to a flag must not
///   interleave; a store used by several nodes must serialize them itself.
/// - `find_change(id)`: one recorded change, or `NotFound`.
/// - `create_group(name, description, by)`: `Conflict` if it exists.
/// - `delete_group(name, by)`: `NotFound` if missing; `Conflict`, naming
///   the flags, while a flag's rule names the group.
/// - `add_member(group, member, by)`, `remove_member(group, member, by)`:
///   `NotFound` for a missing group or member, `Conflict` for a member
///   already there.
pub type Writer {
  Writer(
    update: fn(String, String, fn(Option(Setting)) -> service.Result(Update)) ->
      service.Result(Bool),
    find_change: fn(Int) -> service.Result(Change),
    create_group: fn(String, String, String) -> service.Result(Nil),
    delete_group: fn(String, String) -> service.Result(Nil),
    add_member: fn(String, Target, String) -> service.Result(Nil),
    remove_member: fn(String, Target, String) -> service.Result(Nil),
  )
}

/// Where the settings are kept: `howdy/flags/database` for a Gloo Repo,
/// `howdy/flags/memory` for one process, or your own.
pub opaque type Store {
  Store(
    name: String,
    load: fn() -> service.Result(Snapshot),
    version: fn() -> service.Result(Int),
    history: fn(Option(String), Int) -> service.Result(List(Change)),
    writer: Option(Writer),
    /// Let go of whatever the store runs, such as `howdy/flags/memory`'s
    /// process. Nothing, for stores that run nothing of their own.
    stop: fn() -> Nil,
  )
}

/// A read-only store, such as one fed by a service that manages the flags
/// elsewhere. `load` returns everything; `version` is cheap, and is called
/// every check interval to decide whether to load again; `history(flag,
/// limit)` returns the latest changes, newest first, or `[]` if it keeps
/// none. `name` says where the flags are kept, in messages.
pub fn store(
  named name: String,
  load load: fn() -> service.Result(Snapshot),
  version version: fn() -> service.Result(Int),
  history history: fn(Option(String), Int) -> service.Result(List(Change)),
) -> Store {
  Store(name:, load:, version:, history:, writer: None, stop: fn() { Nil })
}

/// A store that can also be changed through this package: by the
/// management functions, the admin, and `howdy/flags/cli`.
pub fn with_writer(store: Store, writer: Writer) -> Store {
  Store(..store, writer: Some(writer))
}

/// A store with something to end when it is no longer wanted. Stores that
/// own a process, such as `howdy/flags/memory`, register it here so their
/// own `stop` can reach it through the opaque handle.
@internal
pub fn with_stop(store: Store, stop: fn() -> Nil) -> Store {
  Store(..store, stop:)
}

/// Run the store's `stop`. `howdy/flags/memory.stop` is the public face.
@internal
pub fn stop_store(store: Store) -> Nil {
  store.stop()
}

/// Where the flags are kept, such as `database`.
pub fn store_name(flags: Flags) -> String {
  flags.store.name
}

/// Whether the flags can be changed from here. Read-only flags are managed
/// wherever their store gets them from.
pub fn writable(flags: Flags) -> Bool {
  option.is_some(flags.store.writer)
}

// -- Starting ----------------------------------------------------------------

/// Flags being configured, before `start`.
pub opaque type Config {
  Config(store: Store, defined: List(Flag), interval: Int)
}

/// Flags kept in this store.
pub fn new(store: Store) -> Config {
  Config(store:, defined: [], interval: 2000)
}

/// The flags the app defines, so management can list them and refuse
/// changes to keys that do not exist. Checks work for any flag.
pub fn register(config: Config, flags: List(Flag)) -> Config {
  Config(..config, defined: list.append(config.defined, flags))
}

/// How often to look for changes made elsewhere and take due ramp steps:
/// the longest a kill switch can take to reach this node. 100 ms to a
/// minute; the check asks the store for its version.
pub fn check_every(config: Config, milliseconds milliseconds: Int) -> Config {
  let assert True = milliseconds >= 100 && milliseconds <= 60_000
    as "howdy/flags: check_every takes 100 to 60000 milliseconds"
  Config(..config, interval: milliseconds)
}

/// Running flags: the settings in memory, and a process, the keeper, that
/// keeps them current. Both are found by names chosen when the handle is
/// made, not by the keeper's pid, so the handle outlives any one keeper:
/// a keeper restarted by a supervisor publishes under the same key and
/// registers the same name, and checks, `refresh` and `stop` carry on.
pub opaque type Flags {
  Flags(
    store: Store,
    defined: List(Flag),
    key: #(String, Reference),
    name: process.Name(Message),
  )
}

/// Load the settings and start keeping them current, in a process linked
/// to the caller. Prefer `supervised` in an app, so a keeper that crashes
/// is restarted rather than taking the caller with it.
pub fn start(config: Config) -> service.Result(Flags) {
  use _ <- result.try(unique_keys(config.defined))
  let flags = handle(config)
  case launch(config, flags) {
    Ok(_) -> Ok(flags)
    Error(actor.InitFailed(message)) -> Error(service.Internal(message))
    Error(_) -> {
      withdraw(flags.key)
      Error(service.Internal("the flags process did not start"))
    }
  }
}

/// The flags as a child of a supervisor, with the handle to check them by.
/// The handle is made here, before the keeper starts, so it can be given
/// to the app while the supervisor owns the keeper.
///
/// ```gleam
/// let #(features, keeper) = flags.supervised(config)
/// static_supervisor.new(static_supervisor.OneForOne)
/// |> static_supervisor.add(keeper)
/// |> static_supervisor.start
/// ```
///
/// The keeper loads the settings when it starts, so a restart after a crash
/// replaces whatever it had published with fresh settings, and every check
/// keeps working meanwhile from the last ones. It is restarted after a
/// crash and not after `stop`, which lets go of the settings for good.
/// While the supervisor's shutdown takes the keeper down, it lets go of
/// them too, so checks answer with the flags' defaults rather than settings
/// nobody keeps current.
pub fn supervised(
  config: Config,
) -> #(Flags, supervision.ChildSpecification(Flags)) {
  let flags = handle(config)
  let child =
    supervision.worker(fn() { launch(config, flags) })
    |> supervision.restart(supervision.Transient)
  #(flags, child)
}

fn handle(config: Config) -> Flags {
  Flags(
    store: config.store,
    defined: config.defined,
    key: #("howdy_flags", reference.new()),
    name: process.new_name("howdy_flags"),
  )
}

/// Start the keeper for this handle: load the settings, publish them under
/// the handle's key and register under its name.
fn launch(config: Config, flags: Flags) -> actor.StartResult(Flags) {
  actor.new_with_initialiser(5000, fn(subject) {
    use _ <- result.try(
      unique_keys(config.defined) |> result.map_error(service.message),
    )
    use snapshot <- result.try(
      guard(config.store.load) |> result.map_error(service.message),
    )
    publish(flags.key, index(snapshot))
    // An exit from the parent, such as the supervisor shutting down, lets
    // go of the settings on the way out.
    process.trap_exits(True)
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_trapped_exits(Exit)
    process.send_after(subject, config.interval, Tick)
    actor.initialised(Keeper(
      store: config.store,
      key: flags.key,
      version: snapshot.version,
      interval: config.interval,
      self: subject,
    ))
    |> actor.selecting(selector)
    |> actor.returning(flags)
    |> Ok
  })
  |> actor.named(flags.name)
  |> actor.on_message(keep)
  |> actor.start
}

/// Stop keeping the settings current and let go of them. Checks on these
/// flags answer with the flags' defaults afterwards. Stopping flags whose
/// keeper is not running does nothing.
pub fn stop(flags: Flags) -> Nil {
  let _ = ask(flags, refresh_timeout_ms, Stop)
  Nil
}

/// The flags registered with `register`, in order.
pub fn defined(flags: Flags) -> List(Flag) {
  flags.defined
}

/// How long `refresh` waits for the keeper to reload.
const refresh_timeout_ms = 5000

/// Reload the settings now rather than at the next check, and wait for the
/// reload so a change made here is in force when this returns. The wait
/// is bounded: after five seconds this returns `Error(service.Internal)`
/// while the keeper carries on and publishes the settings when the store
/// answers, and the same error comes back at once when no keeper is
/// running. Neither crashes the caller.
pub fn refresh(flags: Flags) -> service.Result(Nil) {
  refresh_within(flags, refresh_timeout_ms)
}

@internal
pub fn refresh_within(flags: Flags, milliseconds: Int) -> service.Result(Nil) {
  ask(flags, milliseconds, Refresh) |> result.flatten
}

/// Ask the keeper and wait for its answer, without crashing the caller
/// when there is none: the keeper may not be running, may exit while
/// answering, or may be held up by the store.
fn ask(
  flags: Flags,
  milliseconds: Int,
  make: fn(Subject(a)) -> Message,
) -> service.Result(a) {
  case process.named(flags.name) {
    Error(Nil) -> Error(not_running())
    Ok(pid) -> {
      let reply = process.new_subject()
      let monitor = process.monitor(pid)
      send_to(pid, flags.name, make(reply))
      let outcome =
        process.new_selector()
        |> process.select_map(reply, Ok)
        |> process.select_specific_monitor(monitor, fn(_) {
          Error(not_running())
        })
        |> process.selector_receive(within: milliseconds)
      process.demonitor_process(monitor)
      case outcome {
        Ok(answer) -> answer
        Error(Nil) ->
          Error(service.Internal(
            "the flags keeper did not answer within "
            <> int.to_string(milliseconds)
            <> "ms; the store may be slow or away",
          ))
      }
    }
  }
}

fn not_running() -> service.Error {
  service.Internal("the flags keeper is not running")
}

/// The keeper's process, while one is running.
@internal
pub fn keeper(flags: Flags) -> Result(process.Pid, Nil) {
  process.named(flags.name)
}

// -- Keeping settings current ------------------------------------------------

/// The settings as checks read them: by flag key, and the groups each
/// stored user or organization is in.
type Index {
  Index(settings: Dict(String, Setting), groups: Dict(String, List(String)))
}

fn empty() -> Index {
  Index(settings: dict.new(), groups: dict.new())
}

fn index(snapshot: Snapshot) -> Index {
  let groups =
    list.fold(snapshot.groups, dict.new(), fn(index, group) {
      list.fold(group.members, index, fn(index, member) {
        dict.upsert(index, target_to_string(member), fn(names) {
          [group.name, ..option.unwrap(names, [])]
        })
      })
    })
  Index(settings: dict.from_list(snapshot.settings), groups:)
}

@external(erlang, "howdy_flags_ffi", "publish")
fn publish(key: #(String, Reference), index: Index) -> Nil

@external(erlang, "howdy_flags_ffi", "current")
fn current(key: #(String, Reference)) -> Result(Index, Nil)

@external(erlang, "howdy_flags_ffi", "withdraw")
fn withdraw(key: #(String, Reference)) -> Nil

@external(erlang, "howdy_flags_ffi", "attempt")
fn attempt(run: fn() -> a) -> Result(a, String)

/// Send to `pid`, looked up as `name`, without looking it up again: if it
/// has exited since, the message is dropped instead of crashing the caller.
@external(erlang, "howdy_flags_ffi", "send_to")
fn send_to(
  pid: process.Pid,
  name: process.Name(message),
  message: message,
) -> Nil

/// A store call that raises, rather than returning an error, is an error
/// like any other: the keeper survives it.
fn guard(run: fn() -> service.Result(a)) -> service.Result(a) {
  case attempt(run) {
    Ok(outcome) -> outcome
    Error(crash) -> Error(service.Internal("the store crashed: " <> crash))
  }
}

type Message {
  Tick
  Refresh(reply: Subject(service.Result(Nil)))
  Stop(reply: Subject(Nil))
  Exit(process.ExitMessage)
}

type Keeper {
  Keeper(
    store: Store,
    key: #(String, Reference),
    version: Int,
    interval: Int,
    self: Subject(Message),
  )
}

/// Reloads go through this one process, so an older snapshot can never
/// replace a newer one.
fn keep(state: Keeper, message: Message) -> actor.Next(Keeper, Message) {
  case message {
    Stop(reply) -> {
      withdraw(state.key)
      process.send(reply, Nil)
      actor.stop()
    }
    Exit(_) -> {
      withdraw(state.key)
      actor.stop()
    }
    Refresh(reply) -> {
      let #(state, outcome) = reload(state)
      process.send(reply, outcome)
      actor.continue(state)
    }
    Tick -> {
      let index = result.unwrap(current(state.key), empty())
      case guard(fn() { advance(state.store, index, time.now()) }) {
        Ok(_) -> Nil
        Error(error) -> warn("taking due ramp steps failed", error)
      }
      let state = case guard(state.store.version) {
        Ok(version) if version == state.version -> state
        Ok(_) -> {
          let #(state, outcome) = reload(state)
          case outcome {
            Ok(Nil) -> Nil
            Error(error) -> warn("reloading settings failed", error)
          }
          state
        }
        Error(error) -> {
          warn("checking for changes failed", error)
          state
        }
      }
      process.send_after(state.self, state.interval, Tick)
      actor.continue(state)
    }
  }
}

fn reload(state: Keeper) -> #(Keeper, service.Result(Nil)) {
  case guard(state.store.load) {
    Ok(snapshot) -> {
      publish(state.key, index(snapshot))
      #(Keeper(..state, version: snapshot.version), Ok(Nil))
    }
    Error(error) -> #(state, Error(error))
  }
}

/// Checks keep using the last settings loaded while the store is away.
fn warn(what: String, error: service.Error) -> Nil {
  logging.log(
    logging.Warning,
    "howdy/flags: " <> what <> ": " <> service.message(error),
  )
}

// -- JSON --------------------------------------------------------------------

/// A snapshot as JSON, the form a store can fetch from or hand to another
/// system. `snapshot_decoder` reads it back.
///
/// ```json
/// {"format": 1, "version": 12,
///  "settings": {"new_checkout": {"killed": false, "rollout": 500,
///    "bucketing": "user", "allowed": ["group:beta"], "blocked": [],
///    "ramp": {"steps": [100, 500, 10000], "every": 3600, "next": 1790000000}}},
///  "groups": [{"name": "beta", "description": "Beta testers",
///    "members": ["org:acme"]}]}
/// ```
pub fn snapshot_to_json(snapshot: Snapshot) -> json.Json {
  json.object([
    #("format", json.int(1)),
    #("version", json.int(snapshot.version)),
    #(
      "settings",
      json.object(
        list.map(snapshot.settings, fn(row) { #(row.0, setting_to_json(row.1)) }),
      ),
    ),
    #(
      "groups",
      json.array(snapshot.groups, fn(group) {
        json.object([
          #("name", json.string(group.name)),
          #("description", json.string(group.description)),
          #("members", targets_to_json(group.members)),
        ])
      }),
    ),
  ])
}

pub fn snapshot_decoder() -> decode.Decoder(Snapshot) {
  let group = {
    use name <- decode.field("name", decode.string)
    use description <- decode.field("description", decode.string)
    use members <- decode.field("members", targets_decoder())
    decode.success(GroupSummary(name:, description:, members:))
  }
  use version <- decode.field("version", decode.int)
  use settings <- decode.field(
    "settings",
    decode.dict(decode.string, setting_decoder()),
  )
  use groups <- decode.field("groups", decode.list(group))
  decode.success(Snapshot(
    version:,
    settings: dict.to_list(settings)
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) }),
    groups:,
  ))
}

/// A setting as JSON, as `snapshot_to_json` writes each one.
pub fn setting_to_json(setting: Setting) -> json.Json {
  json.object([
    #("killed", json.bool(setting.killed)),
    #("rollout", json.int(setting.rollout)),
    #("bucketing", json.string(bucketing_to_string(setting.bucketing))),
    #("allowed", targets_to_json(setting.allowed)),
    #("blocked", targets_to_json(setting.blocked)),
    #(
      "ramp",
      json.nullable(setting.ramp, fn(ramp: Ramp) {
        json.object([
          #("steps", json.array(ramp.steps, json.int)),
          #("every", json.int(ramp.every)),
          #("next", json.nullable(ramp.next, json.int)),
        ])
      }),
    ),
  ])
}

pub fn setting_decoder() -> decode.Decoder(Setting) {
  let ramp = {
    use steps <- decode.field("steps", decode.list(decode.int))
    use every <- decode.field("every", decode.int)
    use next <- decode.field("next", decode.optional(decode.int))
    decode.success(Ramp(steps:, every:, next:))
  }
  use killed <- decode.field("killed", decode.bool)
  use rollout <- decode.field("rollout", decode.int)
  use bucketing <- decode.field("bucketing", decode.string)
  use allowed <- decode.field("allowed", targets_decoder())
  use blocked <- decode.field("blocked", targets_decoder())
  use ramp <- decode.field("ramp", decode.optional(ramp))
  decode.success(Setting(
    killed:,
    rollout:,
    bucketing: bucketing_from_string(bucketing),
    allowed:,
    blocked:,
    ramp:,
  ))
}

fn targets_to_json(targets: List(Target)) -> json.Json {
  json.array(targets, fn(target) { json.string(target_to_string(target)) })
}

/// Every target must parse: a member or rule that cannot be read is an
/// error, not something to drop, or a flag would quietly reach fewer or
/// more people than it was set to.
fn targets_decoder() -> decode.Decoder(List(Target)) {
  use texts <- decode.then(decode.list(decode.string))
  case list.try_map(texts, target_from_string) {
    Ok(targets) -> decode.success(targets)
    Error(Nil) ->
      decode.failure([], "a target such as user:1, org:acme or group:beta")
  }
}

/// `user` or `organization`, as stores keep it.
pub fn bucketing_to_string(bucketing: Bucketing) -> String {
  case bucketing {
    ByUser -> "user"
    ByOrganization -> "organization"
  }
}

pub fn bucketing_from_string(text: String) -> Bucketing {
  case text {
    "organization" -> ByOrganization
    _ -> ByUser
  }
}

// -- Reading input -----------------------------------------------------------

/// A percentage such as `12.5` or `5%`, in hundredths of a percent.
pub fn parse_percent(text: String) -> Result(Int, Nil) {
  let text = string.trim(text) |> string.replace("%", "")
  let #(whole, part) = case string.split_once(text, ".") {
    Ok(#(whole, part)) -> #(whole, part)
    Error(Nil) -> #(text, "")
  }
  let whole = case whole {
    "" -> "0"
    _ -> whole
  }
  use whole <- result.try(int.parse(whole))
  use part <- result.try(case string.length(part) {
    0 -> Ok(0)
    1 | 2 -> int.parse(string.pad_end(part, 2, "0"))
    _ -> Error(Nil)
  })
  let rollout = whole * 100 + part
  case whole >= 0 && part >= 0 && rollout <= 10_000 {
    True -> Ok(rollout)
    False -> Error(Nil)
  }
}
