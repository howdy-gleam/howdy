import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/static_supervisor
import gleam/result
import gleam/string
import gleeunit
import gloo/adapter/sqlite
import gloo/repo.{type Repo}
import gloo/sql as gloo_sql
import howdy/database
import howdy/database/postgres
import howdy/flags.{
  Allowed, Blocked, ByOrganization, ByUser, Default, Group, InRollout, Killed,
  NoPosition, Organization, OutsideRollout, Ramp, Setting, User,
}
import howdy/flags/database as flags_database
import howdy/flags/memory
import howdy/migration
import howdy/service

pub fn main() {
  gleeunit.main()
}

fn checkout() -> flags.Flag {
  flags.flag("new_checkout", description: "Stripe-hosted checkout")
}

fn search() -> flags.Flag {
  flags.flag("search_v2", description: "New search") |> flags.on_by_default
}

@external(erlang, "howdy_flags_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

/// SQLite in memory, or a PostgreSQL database emptied of the package's
/// tables when `HOWDY_FLAGS_TEST_POSTGRES_URL` is set.
fn open() -> Repo {
  case getenv("HOWDY_FLAGS_TEST_POSTGRES_URL") {
    Error(Nil) -> {
      let assert Ok(db) = sqlite.start(sqlite.memory())
      let assert Ok(Nil) = database.sqlite_defaults(db)
      db
    }
    Ok(url) -> {
      let assert Ok(db) = postgres.from_url(url) |> result.try(postgres.start)
      let assert Ok(Nil) =
        database.exec(
          db,
          "DROP TABLE IF EXISTS howdy_flags_rules, howdy_flags_settings,
            howdy_flags_members, howdy_flags_groups, howdy_flags_changes,
            howdy_flags_version;
          CREATE TABLE IF NOT EXISTS howdy_migrations (package TEXT NOT NULL, version BIGINT NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(package, version));
          CREATE TABLE IF NOT EXISTS howdy_migration_schemas (package TEXT PRIMARY KEY NOT NULL, fingerprint TEXT NOT NULL);
          DELETE FROM howdy_migrations WHERE package = 'howdy_flags';
          DELETE FROM howdy_migration_schemas WHERE package = 'howdy_flags'",
        )
      db
    }
  }
}

/// Run against the memory store, then the database store.
fn each_store(run: fn(flags.Store) -> a) -> Nil {
  let _ = run(memory.new())
  let db = open()
  let assert Ok(Nil) = migration.run(db, [flags_database.schema()])
  let assert Ok(store) = flags_database.store(db)
  let _ = run(store)
  let assert Ok(_) = repo.close(db)
  Nil
}

fn with_flags(run: fn(flags.Flags) -> a) -> Nil {
  use store <- each_store
  let assert Ok(features) = start(store)
  let _ = run(features)
  flags.stop(features)
}

fn start(store: flags.Store) -> service.Result(flags.Flags) {
  flags.new(store)
  |> flags.register([checkout(), search()])
  |> flags.check_every(milliseconds: 100)
  |> flags.start
}

/// How many of `ids` users have the flag.
fn share(features: flags.Flags, flag: flags.Flag, users: Int) -> Int {
  ids(users)
  |> list.count(fn(i) {
    flags.enabled(features, flag, for: flags.user(int.to_string(i)))
  })
}

fn setting(rollout: Int) -> flags.Setting {
  Setting(
    killed: False,
    rollout:,
    bucketing: ByUser,
    allowed: [],
    blocked: [],
    ramp: None,
  )
}

// -- Checking, without a database ---------------------------------------------

pub fn position_is_stable_and_spread_test() {
  assert flags.position("new_checkout", User("42"))
    == flags.position("new_checkout", User("42"))
  // A user and an organization with the same id are different people.
  assert flags.position("new_checkout", User("42"))
    != flags.position("new_checkout", Organization("42"))
  let positions =
    ids(2000)
    |> list.map(fn(i) { flags.position("new_checkout", User(int.to_string(i))) })
  assert list.all(positions, fn(p) { p >= 0 && p < 10_000 })
  let below_half = list.count(positions, fn(p) { p < 5000 })
  assert below_half > 900 && below_half < 1100
}

pub fn different_flags_pick_different_early_users_test() {
  let early = fn(key) {
    ids(1000)
    |> list.filter(fn(i) { flags.position(key, User(int.to_string(i))) < 1000 })
  }
  assert early("a") != early("b")
}

pub fn order_is_kill_block_allow_rollout_test() {
  let groups = dict.from_list([#("user:1", ["beta"]), #("org:9", ["staff"])])
  let alice = flags.user("1")
  let everyone = setting(10_000)

  assert flags.decide("f", Setting(..everyone, killed: True), alice, groups)
    == Killed
  assert flags.decide(
      "f",
      Setting(..everyone, allowed: [User("1")], killed: True),
      alice,
      groups,
    )
    == Killed
  assert flags.decide(
      "f",
      Setting(..everyone, blocked: [Group("beta")], allowed: [User("1")]),
      alice,
      groups,
    )
    == Blocked(Group("beta"))
  assert flags.decide(
      "f",
      Setting(..setting(0), allowed: [Group("beta")]),
      alice,
      groups,
    )
    == Allowed(Group("beta"))
  // Membership through the organization the user acts in.
  assert flags.decide(
      "f",
      Setting(..setting(0), allowed: [Group("staff")]),
      flags.user("2") |> flags.in_organization("9"),
      groups,
    )
    == Allowed(Group("staff"))
  assert flags.decide("f", setting(0), alice, groups)
    == OutsideRollout(flags.position("f", User("1")), 0)
}

pub fn rollouts_need_the_id_they_are_by_except_at_everyone_test() {
  let groups = dict.new()
  assert flags.decide("f", setting(9999), flags.anonymous(), groups)
    == NoPosition(ByUser)
  assert flags.decide("f", setting(10_000), flags.anonymous(), groups)
    == InRollout(0, 10_000)
  let by_org = Setting(..setting(5000), bucketing: ByOrganization)
  assert flags.decide("f", by_org, flags.user("1"), groups)
    == NoPosition(ByOrganization)
  // Everyone in an organization gets the same answer.
  let answers =
    ids(50)
    |> list.map(fn(i) {
      flags.is_on(flags.decide(
        "f",
        by_org,
        flags.user(int.to_string(i)) |> flags.in_organization("acme"),
        groups,
      ))
    })
    |> list.unique
  assert list.length(answers) == 1
}

pub fn percent_text_test() {
  assert flags.percent_to_string(0) == "0%"
  assert flags.percent_to_string(flags.percent(25)) == "25%"
  assert flags.percent_to_string(50) == "0.5%"
  assert flags.percent_to_string(5) == "0.05%"
  assert flags.percent_to_string(1250) == "12.5%"
  assert flags.percent_to_string(10_000) == "100%"
  // Every shape of the fraction: one hundredth, tenths, both digits, and
  // the digits either side of a whole number.
  assert flags.percent_to_string(1) == "0.01%"
  assert flags.percent_to_string(10) == "0.1%"
  assert flags.percent_to_string(99) == "0.99%"
  assert flags.percent_to_string(101) == "1.01%"
  assert flags.percent_to_string(110) == "1.1%"
  assert flags.percent_to_string(1234) == "12.34%"
  assert flags.percent_to_string(9999) == "99.99%"
  assert flags.percent_to_string(9990) == "99.9%"
}

@external(erlang, "howdy_flags_ffi", "attempt")
fn attempt(run: fn() -> a) -> Result(a, String)

pub fn check_every_takes_a_tenth_of_a_second_to_a_minute_test() {
  let config = flags.new(memory.new()) |> flags.register([checkout()])
  let assert Ok(_) = attempt(fn() { flags.check_every(config, 100) })
  let assert Ok(_) = attempt(fn() { flags.check_every(config, 60_000) })
  let assert Error(reason) = attempt(fn() { flags.check_every(config, 99) })
  assert string.contains(reason, "100 to 60000")
  let assert Error(_) = attempt(fn() { flags.check_every(config, 60_001) })
  let assert Error(_) = attempt(fn() { flags.check_every(config, -1) })
}

pub fn targets_round_trip_test() {
  assert flags.target_from_string("user:4:2") == Ok(User("4:2"))
  assert flags.target_from_string(" org:7 ") == Ok(Organization("7"))
  assert flags.target_from_string("group:beta") == Ok(Group("beta"))
  assert flags.target_from_string("user:") == Error(Nil)
  assert flags.target_from_string("team:x") == Error(Nil)
}

// -- Through the database -----------------------------------------------------

pub fn defaults_apply_with_nothing_stored_test() {
  use features <- with_flags
  assert flags.explain(features, checkout(), for: flags.user("1"))
    == Default(False)
  assert flags.enabled(features, search(), for: flags.anonymous())
  assert flags.settings(features) == Ok([])
}

pub fn first_change_starts_from_the_default_test() {
  use features <- with_flags
  let assert Ok(Nil) = flags.allow(features, "search_v2", User("1"), by: "t")
  // On by default means a full rollout once stored.
  assert flags.enabled(features, search(), for: flags.user("2"))
  assert flags.explain(features, search(), for: flags.user("1"))
    == Allowed(User("1"))
}

pub fn rollout_only_adds_people_as_it_grows_test() {
  use features <- with_flags
  let in_at = fn(rollout) {
    let assert Ok(Nil) =
      flags.set_rollout(features, "new_checkout", to: rollout, by: "t")
    ids(1000)
    |> list.filter(fn(i) {
      flags.enabled(features, checkout(), for: flags.user(int.to_string(i)))
    })
  }
  let five = in_at(flags.percent(5))
  let twenty = in_at(flags.percent(20))
  assert list.all(five, list.contains(twenty, _))
  assert list.length(twenty) > list.length(five)
  // Rolling back returns exactly the first 5%.
  assert in_at(flags.percent(5)) == five
  assert in_at(0) == []
}

pub fn kill_switch_beats_everything_and_revive_restores_test() {
  use features <- with_flags
  let assert Ok(Nil) =
    flags.set_rollout(features, "new_checkout", to: 10_000, by: "t")
  let assert Ok(Nil) = flags.allow(features, "new_checkout", User("1"), by: "t")
  let assert Ok(Nil) = flags.kill(features, "new_checkout", by: "t")
  assert flags.explain(features, checkout(), for: flags.user("1")) == Killed
  assert share(features, checkout(), 100) == 0
  let assert Ok(Nil) = flags.revive(features, "new_checkout", by: "t")
  assert share(features, checkout(), 100) == 100
}

pub fn groups_grant_and_block_test() {
  use features <- with_flags
  let assert Ok(Nil) =
    flags.create_group(features, "beta", description: "Beta testers", by: "t")
  let assert Ok(Nil) = flags.add_member(features, "beta", User("7"), by: "t")
  let assert Ok(Nil) =
    flags.add_member(features, "beta", Organization("acme"), by: "t")
  let assert Ok(Nil) =
    flags.allow(features, "new_checkout", Group("beta"), by: "t")

  assert flags.enabled(features, checkout(), for: flags.user("7"))
  assert flags.enabled(
    features,
    checkout(),
    for: flags.user("8") |> flags.in_organization("acme"),
  )
  assert !flags.enabled(features, checkout(), for: flags.user("8"))

  let assert Ok(Nil) = flags.block(features, "new_checkout", User("7"), by: "t")
  assert flags.explain(features, checkout(), for: flags.user("7"))
    == Blocked(User("7"))

  let assert Ok(Nil) =
    flags.remove_member(features, "beta", Organization("acme"), by: "t")
  assert !flags.enabled(
    features,
    checkout(),
    for: flags.user("8") |> flags.in_organization("acme"),
  )

  let assert Ok([group]) = flags.groups(features)
  assert group.members == [User("7")]
  // A group a rule names cannot be deleted from under the flag.
  let assert Error(service.Conflict(_)) =
    flags.delete_group(features, "beta", by: "t")
  let assert Ok(Nil) =
    flags.unlist(features, "new_checkout", Group("beta"), by: "t")
  let assert Ok(Nil) = flags.delete_group(features, "beta", by: "t")
  assert flags.groups(features) == Ok([])
}

pub fn unknown_keys_and_bad_input_are_refused_test() {
  use features <- with_flags
  let assert Error(service.NotFound(_)) =
    flags.kill(features, "no_such_flag", by: "t")
  let assert Error(service.Invalid(_)) =
    flags.set_rollout(features, "new_checkout", to: 10_001, by: "t")
  let assert Error(service.Invalid(_)) =
    flags.add_member(features, "beta", Group("x"), by: "t")
  let assert Error(service.NotFound(_)) =
    flags.add_member(features, "beta", User("1"), by: "t")
  let assert Error(service.Invalid(_)) =
    flags.start_ramp(
      features,
      "new_checkout",
      steps: [500, 100],
      every: 60,
      by: "t",
    )
}

pub fn ramp_steps_pause_and_finish_test() {
  use features <- with_flags
  let assert Ok(Nil) =
    flags.start_ramp(
      features,
      "new_checkout",
      steps: [100, 2500, 10_000],
      every: 3600,
      by: "t",
    )
  let assert Ok(Some(started)) = flags.setting(features, "new_checkout")
  assert started.rollout == 100
  let assert Some(Ramp(next: Some(next), ..)) = started.ramp

  // Nothing is due yet.
  assert flags.advance_ramps(features, next - 1) == Ok(0)
  assert flags.advance_ramps(features, next) == Ok(1)
  // A second node looking at the same moment takes no step.
  assert flags.advance_ramps(features, next) == Ok(0)
  let assert Ok(Some(stepped)) = flags.setting(features, "new_checkout")
  assert stepped.rollout == 2500

  // Paused, no step is taken however late it gets.
  let assert Ok(Nil) = flags.pause_ramp(features, "new_checkout", by: "t")
  assert flags.advance_ramps(features, next + 1_000_000) == Ok(0)

  let assert Ok(Nil) = flags.resume_ramp(features, "new_checkout", by: "t")
  assert flags.advance_ramps(features, next + 1_000_000) == Ok(1)
  let assert Ok(Some(done)) = flags.setting(features, "new_checkout")
  assert done.rollout == 10_000
  assert done.ramp == None
  let assert Ok([last, ..]) =
    flags.history(features, of: Some("new_checkout"), limit: 1)
  assert last.by == "ramp"
  assert last.summary == "Ramp step 25% → 100%"
}

pub fn rolling_back_or_killing_pauses_the_ramp_test() {
  use features <- with_flags
  let assert Ok(Nil) =
    flags.start_ramp(
      features,
      "new_checkout",
      steps: [100, 5000],
      every: 60,
      by: "t",
    )
  let assert Ok(Nil) =
    flags.set_rollout(features, "new_checkout", to: 0, by: "t")
  let assert Ok(Some(rolled_back)) = flags.setting(features, "new_checkout")
  assert rolled_back.ramp == Some(Ramp([100, 5000], 60, None))
  assert flags.advance_ramps(features, 9_999_999_999) == Ok(0)

  let assert Ok(Nil) = flags.resume_ramp(features, "new_checkout", by: "t")
  let assert Ok(Nil) = flags.kill(features, "new_checkout", by: "t")
  assert flags.advance_ramps(features, 9_999_999_999) == Ok(0)
  let assert Error(service.Conflict(_)) =
    flags.resume_ramp(features, "new_checkout", by: "t")
}

pub fn history_records_and_undo_restores_test() {
  use features <- with_flags
  let assert Ok(Nil) =
    flags.set_rollout(
      features,
      "new_checkout",
      to: flags.percent(5),
      by: "mike",
    )
  let assert Ok(Nil) =
    flags.set_rollout(
      features,
      "new_checkout",
      to: flags.percent(50),
      by: "mike",
    )
  // Setting what is already there records nothing.
  let assert Ok(Nil) =
    flags.set_rollout(
      features,
      "new_checkout",
      to: flags.percent(50),
      by: "mike",
    )

  let assert Ok([latest, first]) =
    flags.history(features, of: Some("new_checkout"), limit: 10)
  assert latest.summary == "Rollout 5% → 50%"
  assert latest.by == "mike"
  assert first.before == None
  assert latest.id > first.id

  let assert Ok(Nil) = flags.undo(features, change: latest.id, by: "ops")
  let assert Ok(Some(restored)) = flags.setting(features, "new_checkout")
  assert restored.rollout == flags.percent(5)
  assert share(features, checkout(), 1000) < 100

  // Undoing the first change forgets the flag again.
  let assert Ok(Nil) = flags.undo(features, change: first.id, by: "ops")
  assert flags.setting(features, "new_checkout") == Ok(None)
  assert flags.explain(features, checkout(), for: flags.user("1"))
    == Default(False)
}

pub fn forget_tidies_unregistered_keys_test() {
  use store <- each_store
  let assert Ok(features) = start(store)
  let assert Ok(Nil) = flags.kill(features, "new_checkout", by: "t")
  flags.stop(features)
  // A later deployment drops the flag from the code.
  let assert Ok(later) =
    flags.new(store) |> flags.register([search()]) |> flags.start
  let assert Ok([#("new_checkout", _)]) = flags.settings(later)
  let assert Ok(Nil) = flags.forget(later, "new_checkout", by: "t")
  assert flags.settings(later) == Ok([])
  let assert Error(service.NotFound(_)) =
    flags.forget(later, "new_checkout", by: "t")
  flags.stop(later)
}

pub fn other_nodes_pick_up_changes_test() {
  use store <- each_store
  let assert Ok(features) = start(store)
  let assert Ok(other) = start(store)
  assert !flags.enabled(other, checkout(), for: flags.user("1"))
  let assert Ok(Nil) =
    flags.set_rollout(features, "new_checkout", to: 10_000, by: "t")
  // This node sees it at once.
  assert flags.enabled(features, checkout(), for: flags.user("1"))
  // The other within its check interval.
  process.sleep(300)
  assert flags.enabled(other, checkout(), for: flags.user("1"))
  flags.stop(other)
  flags.stop(features)
}

pub fn refresh_reloads_at_once_and_answers_without_a_keeper_test() {
  let store = memory.new()
  let assert Ok(features) =
    flags.new(store)
    |> flags.register([checkout(), search()])
    |> flags.check_every(milliseconds: 60_000)
    |> flags.start
  let assert Ok(other) = start(store)
  let assert Ok(Nil) =
    flags.set_rollout(other, "new_checkout", to: 10_000, by: "ops")
  // A change from elsewhere waits for the next check, unless asked for.
  assert !flags.enabled(features, checkout(), for: flags.user("1"))
  let assert Ok(Nil) = flags.refresh(features)
  assert flags.enabled(features, checkout(), for: flags.user("1"))
  flags.stop(other)

  // Once stopped, the keeper is gone and both messages say so without
  // crashing: refresh with an error, stop by doing nothing.
  let assert Ok(pid) = flags.keeper(features)
  flags.stop(features)
  assert !process.is_alive(pid)
  assert flags.keeper(features) == Error(Nil)
  let assert Error(service.Internal(reason)) = flags.refresh(features)
  assert string.contains(reason, "not running")
  flags.stop(features)
  assert flags.enabled(features, search(), for: flags.anonymous())
}

pub fn stopped_flags_answer_with_defaults_test() {
  let assert Ok(features) = start(memory.new())
  let assert Ok(Nil) = flags.kill(features, "search_v2", by: "ops")
  assert !flags.enabled(features, search(), for: flags.anonymous())
  flags.stop(features)
  assert flags.enabled(features, search(), for: flags.anonymous())
  assert flags.explain(features, checkout(), for: flags.user("1"))
    == Default(False)
}

pub fn supervised_keeper_starts_and_stops_with_its_supervisor_test() {
  let #(features, keeper) =
    flags.new(memory.new())
    |> flags.register([checkout(), search()])
    |> flags.supervised
  // Nothing is published until the keeper starts.
  assert flags.enabled(features, search(), for: flags.anonymous())
  let assert Ok(supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(keeper)
    |> static_supervisor.start
  let assert Ok(pid) = flags.keeper(features)
  let assert Ok(Nil) = flags.kill(features, "search_v2", by: "ops")
  assert !flags.enabled(features, search(), for: flags.anonymous())
  // Shutting the supervisor down takes the keeper, and its settings, with it.
  process.unlink(supervisor.pid)
  process.send_exit(supervisor.pid)
  process.sleep(100)
  assert !process.is_alive(pid)
  assert flags.keeper(features) == Error(Nil)
  assert flags.enabled(features, search(), for: flags.anonymous())
}

pub fn supervised_keeper_is_restarted_and_reloads_test() {
  let store = memory.new()
  let #(features, keeper) =
    flags.new(store)
    |> flags.register([checkout(), search()])
    |> flags.check_every(milliseconds: 60_000)
    |> flags.supervised
  let assert Ok(supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(keeper)
    |> static_supervisor.start
  let assert Ok(first) = flags.keeper(features)
  assert !flags.enabled(features, checkout(), for: flags.user("1"))
  // A change made elsewhere, that this keeper has not looked for yet.
  let assert Ok(other) = start(store)
  let assert Ok(Nil) =
    flags.set_rollout(other, "new_checkout", 10_000, by: "ops")
  assert !flags.enabled(features, checkout(), for: flags.user("1"))
  process.kill(first)
  process.sleep(100)
  // The same handle answers, from settings the new keeper loaded afresh.
  let assert Ok(second) = flags.keeper(features)
  assert second != first
  assert flags.enabled(features, checkout(), for: flags.user("1"))
  let assert Ok(Nil) = flags.kill(features, "new_checkout", by: "ops")
  assert flags.explain(features, checkout(), for: flags.user("1")) == Killed
  flags.stop(other)
  process.unlink(supervisor.pid)
  process.send_exit(supervisor.pid)
}

pub fn a_store_that_crashes_does_not_take_the_keeper_test() {
  let store =
    flags.store(
      named: "flaky",
      load: fn() {
        Ok(
          flags.Snapshot(
            version: 1,
            settings: [#("new_checkout", setting(10_000))],
            groups: [],
          ),
        )
      },
      version: fn() { panic as "the store is away" },
      history: fn(_, _) { Ok([]) },
    )
  let assert Ok(features) =
    flags.new(store)
    |> flags.register([checkout()])
    |> flags.check_every(milliseconds: 100)
    |> flags.start
  let assert Ok(pid) = flags.keeper(features)
  process.sleep(250)
  assert process.is_alive(pid)
  assert flags.enabled(features, checkout(), for: flags.user("1"))
  flags.stop(features)
}

pub fn a_store_that_errors_leaves_the_last_settings_in_force_test() {
  // The store answers once, then fails every call without crashing.
  let loads = counter()
  let store =
    flags.store(
      named: "failing",
      load: fn() {
        case count(loads) {
          0 ->
            Ok(
              flags.Snapshot(
                version: 1,
                settings: [#("new_checkout", setting(10_000))],
                groups: [],
              ),
            )
          _ -> Error(service.Internal("the store is away"))
        }
      },
      version: fn() { Ok(2) },
      history: fn(_, _) { Ok([]) },
    )
  let assert Ok(features) =
    flags.new(store)
    |> flags.register([checkout()])
    |> flags.check_every(milliseconds: 100)
    |> flags.start
  let assert Ok(pid) = flags.keeper(features)
  assert flags.enabled(features, checkout(), for: flags.user("1"))
  // Every check finds a new version, tries to reload, and logs the
  // failure; the settings loaded first stay in force.
  process.sleep(250)
  assert process.is_alive(pid)
  assert flags.enabled(features, checkout(), for: flags.user("1"))
  let assert Error(service.Internal(reason)) = flags.refresh(features)
  assert string.contains(reason, "the store is away")
  assert flags.enabled(features, checkout(), for: flags.user("1"))
  flags.stop(features)
}

/// A count shared between processes, as the keeper calls the store.
type Counter

@external(erlang, "counters", "new")
fn counters_new(size: Int, options: List(Nil)) -> Counter

@external(erlang, "counters", "add")
fn counters_add(counter: Counter, index: Int, by: Int) -> Nil

@external(erlang, "counters", "get")
fn counters_get(counter: Counter, index: Int) -> Int

fn counter() -> Counter {
  counters_new(1, [])
}

/// The count so far, then one more.
fn count(counter: Counter) -> Int {
  let seen = counters_get(counter, 1)
  counters_add(counter, 1, 1)
  seen
}

pub fn duplicate_keys_and_missing_schema_are_refused_test() {
  let db = open()
  let assert Error(service.Internal(_)) = flags_database.store(db)
  let assert Ok(Nil) = migration.run(db, [flags_database.schema()])
  let assert Ok(store) = flags_database.store(db)
  let assert Error(service.Invalid(_)) =
    flags.new(store) |> flags.register([checkout(), checkout()]) |> flags.start
  let assert Ok(_) = repo.close(db)
}

pub fn read_only_stores_check_but_refuse_changes_test() {
  let snapshot =
    flags.Snapshot(
      version: 3,
      settings: [#("new_checkout", setting(10_000))],
      groups: [],
    )
  let store =
    flags.store(
      named: "hosting",
      load: fn() { Ok(snapshot) },
      version: fn() { Ok(3) },
      history: fn(_, _) { Ok([]) },
    )
  let assert Ok(features) = start(store)
  assert !flags.writable(features)
  assert flags.store_name(features) == "hosting"
  assert flags.enabled(features, checkout(), for: flags.user("1"))
  let assert Error(service.Invalid(message)) =
    flags.kill(features, "new_checkout", by: "t")
  assert string.contains(message, "hosting")
  // A read-only store takes no ramp steps.
  assert flags.advance_ramps(features, 9_999_999_999) == Ok(0)
  flags.stop(features)
}

pub fn snapshots_round_trip_as_json_test() {
  use features <- with_flags
  let assert Ok(Nil) =
    flags.create_group(features, "beta", description: "Beta testers", by: "t")
  let assert Ok(Nil) =
    flags.add_member(features, "beta", Organization("acme"), by: "t")
  let assert Ok(Nil) =
    flags.allow(features, "new_checkout", Group("beta"), by: "t")
  let assert Ok(Nil) =
    flags.start_ramp(
      features,
      "new_checkout",
      steps: [100, 10_000],
      every: 60,
      by: "t",
    )
  let assert Ok(snapshot) = flags.snapshot(features)
  let text = json.to_string(flags.snapshot_to_json(snapshot))
  assert json.parse(text, flags.snapshot_decoder()) == Ok(snapshot)
  // A memory store started from it answers the same.
  let assert Ok(copy) = start(memory.from(snapshot))
  assert flags.enabled(
    copy,
    checkout(),
    for: flags.user("9") |> flags.in_organization("acme"),
  )
  flags.stop(copy)
}

pub fn a_stopped_memory_store_answers_with_errors_test() {
  let store = memory.new()
  let assert Ok(features) = start(store)
  let assert Ok(Nil) =
    flags.set_rollout(features, "new_checkout", to: 500, by: "mike")
  memory.stop(store)
  // Nothing crashes: the keeper is still up, and every call to the store
  // is an error, so is a refresh and a change.
  let assert Ok(pid) = flags.keeper(features)
  let assert Error(service.Internal(reason)) = flags.refresh(features)
  assert string.contains(reason, "stopped")
  let assert Error(service.Internal(_)) =
    flags.set_rollout(features, "new_checkout", to: 600, by: "mike")
  assert process.is_alive(pid)
  // Checks carry on from the settings loaded before.
  assert share(features, checkout(), 1000) > 0
  assert share(features, checkout(), 1000) < 100
  // Stopping again is fine, and new flags cannot start on it.
  memory.stop(store)
  let assert Error(service.Internal(_)) = start(store)
  flags.stop(features)
}

pub fn calling_stopped_flags_does_not_crash_test() {
  let assert Ok(features) = start(memory.new())
  flags.stop(features)
  let assert Error(service.Internal(reason)) = flags.refresh(features)
  assert string.contains(reason, "not running")
  let assert Error(service.Internal(_)) =
    flags.set_rollout(features, "new_checkout", to: 500, by: "mike")
  flags.stop(features)
}

pub fn refresh_gives_up_on_a_slow_store_test() {
  let store =
    flags.store(
      named: "slow",
      load: fn() {
        process.sleep(300)
        Ok(flags.Snapshot(version: 1, settings: [], groups: []))
      },
      version: fn() { Ok(1) },
      history: fn(_, _) { Ok([]) },
    )
  let assert Ok(features) =
    flags.new(store)
    |> flags.register([checkout()])
    |> flags.start
  let assert Error(service.Internal(reason)) =
    flags.refresh_within(features, 50)
  assert string.contains(reason, "did not answer within 50ms")
  // The keeper finishes the reload on its own and is still there.
  let assert Ok(pid) = flags.keeper(features)
  process.sleep(400)
  assert process.is_alive(pid)
  assert flags.enabled(features, search(), for: flags.user("1"))
  flags.stop(features)
}

pub fn a_change_whose_stored_setting_is_unreadable_cannot_be_undone_test() {
  let db = open()
  let assert Ok(Nil) = migration.run(db, [flags_database.schema()])
  let assert Ok(store) = flags_database.store(db)
  let assert Ok(features) = start(store)
  let assert Ok(Nil) =
    flags.set_rollout(features, "new_checkout", to: 500, by: "mike")
  let assert Ok(Nil) =
    flags.set_rollout(features, "new_checkout", to: 5000, by: "mike")
  let assert Ok([latest, ..]) =
    flags.history(features, of: Some("new_checkout"), limit: 10)
  let assert Ok(Nil) =
    database.execute(
      db,
      "UPDATE howdy_flags_changes SET before = 'not json' WHERE id = $1",
      [gloo_sql.int(latest.id)],
    )

  // Undo refuses rather than treating the unreadable setting as nothing
  // stored, which would have deleted the flag's setting.
  let assert Error(service.Internal(reason)) =
    flags.undo(features, change: latest.id, by: "ops")
  assert string.contains(reason, "before change " <> int.to_string(latest.id))
  assert string.contains(reason, "cannot be read")
  let assert Ok(Some(setting)) = flags.setting(features, "new_checkout")
  assert setting.rollout == 5000
  // The history says so too, rather than showing the change as a first one.
  let assert Error(service.Internal(_)) =
    flags.history(features, of: Some("new_checkout"), limit: 10)

  // A rule with a target that cannot be read stops the settings loading,
  // rather than dropping the rule and letting the flag reach more people.
  let assert Ok(Nil) =
    database.execute(
      db,
      "INSERT INTO howdy_flags_rules (flag, target, effect) VALUES ('new_checkout', 'nonsense', 'block')",
      [],
    )
  let assert Error(service.Internal(reason)) = flags.refresh(features)
  assert string.contains(reason, "nonsense")
  flags.stop(features)
  let assert Ok(_) = repo.close(db)
}

pub fn unreadable_targets_fail_the_json_decoders_test() {
  let text =
    "{\"version\": 1, \"settings\": {}, \"groups\": [{\"name\": \"beta\", \"description\": \"\", \"members\": [\"bogus\"]}]}"
  let assert Error(_) = json.parse(text, flags.snapshot_decoder())
  let text =
    "{\"killed\": false, \"rollout\": 0, \"bucketing\": \"user\", \"allowed\": [\"user:\"], \"blocked\": [], \"ramp\": null}"
  let assert Error(_) = json.parse(text, flags.setting_decoder())
}

pub fn percentages_parse_to_hundredths_test() {
  assert flags.parse_percent("5") == Ok(500)
  assert flags.parse_percent("12.5%") == Ok(1250)
  assert flags.parse_percent(".25") == Ok(25)
  assert flags.parse_percent("100") == Ok(10_000)
  assert flags.parse_percent("100.01") == Error(Nil)
  assert flags.parse_percent("1.234") == Error(Nil)
  assert flags.parse_percent("-1") == Error(Nil)
  assert flags.parse_percent("five") == Error(Nil)
}

fn ids(to: Int) -> List(Int) {
  int.range(from: 1, to: to + 1, with: [], run: fn(acc, i) { [i, ..acc] })
  |> list.reverse
}

pub fn lists_the_code_flags_as_json_test() {
  assert json.to_string(flags.to_json([checkout(), search()]))
    == "{\"format\":1,\"flags\":["
    <> "{\"key\":\"new_checkout\",\"description\":\"Stripe-hosted checkout\",\"default\":false},"
    <> "{\"key\":\"search_v2\",\"description\":\"New search\",\"default\":true}]}"
  assert json.to_string(flags.to_json([])) == "{\"format\":1,\"flags\":[]}"
}
