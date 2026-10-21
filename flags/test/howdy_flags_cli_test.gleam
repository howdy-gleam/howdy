import gleam/json
import gleam/option.{Some}
import gleam/string
import howdy/flags
import howdy/flags/cli.{Outcome}
import howdy/flags/memory
import howdy/service

fn checkout() -> flags.Flag {
  flags.flag("new_checkout", description: "Stripe-hosted checkout")
}

fn defined() -> List(flags.Flag) {
  [checkout(), flags.flag("search_v2", description: "New search")]
}

/// Commands run against one memory store, as a CLI runs against one
/// database.
fn with_cli(run: fn(fn(List(String)) -> cli.Outcome, flags.Store) -> a) -> a {
  let store = memory.new()
  run(
    fn(arguments) { cli.run(defined(), fn() { Ok(store) }, arguments) },
    store,
  )
}

fn ok(outcome: cli.Outcome) -> String {
  let assert Outcome(status: 0, output:) = outcome
    as { "command failed: " <> outcome.output }
  output
}

pub fn export_needs_no_store_test() {
  let outcome =
    cli.run(defined(), fn() { Error(service.Internal("no database here")) }, [
      "export",
    ])
  assert outcome.status == 0
  assert outcome.output == json.to_string(flags.to_json(defined())) <> "\n"
}

pub fn changes_are_recorded_as_made_by_the_cli_test() {
  use cli, store <- with_cli
  assert string.contains(ok(cli(["list"])), "new_checkout  default off")
  assert ok(cli(["rollout", "new_checkout", "12.5", "--by", "mike"]))
    == "new_checkout is rolled out to 12.5%.\n"
  assert ok(cli(["kill", "new_checkout"])) == "new_checkout is killed.\n"
  assert string.contains(ok(cli(["list"])), "new_checkout  killed, 12.5%")
  let show = ok(cli(["show", "new_checkout"]))
  assert string.contains(show, "killed:   yes")
  assert string.contains(show, "rollout:  12.5% by user")

  let history = ok(cli(["history", "new_checkout"]))
  assert string.contains(history, "Rollout 0% → 12.5%  (mike)")
  assert string.contains(history, "Killed  (cli")

  // Undo the kill, by the number history shows.
  let assert Ok(features) =
    flags.new(store) |> flags.register(defined()) |> flags.start
  let assert Ok([kill, ..]) =
    flags.history(features, of: Some("new_checkout"), limit: 1)
  flags.stop(features)
  assert ok(cli(["undo", string.inspect(kill.id)])) == "Undone.\n"
  assert string.contains(ok(cli(["show", "new_checkout"])), "killed:   no")
}

pub fn groups_rules_and_check_test() {
  use cli, _ <- with_cli
  let _ = ok(cli(["group", "create", "beta", "Beta", "testers"]))
  let _ = ok(cli(["group", "add", "beta", "org:acme"]))
  assert ok(cli(["groups"])) == "beta — Beta testers\n  org:acme\n"
  let _ = ok(cli(["allow", "new_checkout", "group:beta"]))
  assert ok(cli(["check", "new_checkout", "--user", "9", "--org", "acme"]))
    == "on: allowed for group:beta\n"
  assert string.starts_with(
    ok(cli(["check", "new_checkout", "--user", "9"])),
    "off: position ",
  )
  // The group is in use, so it stays.
  let refused = cli(["group", "delete", "beta"])
  assert refused.status == 1
  assert string.contains(refused.output, "new_checkout")
}

pub fn ramps_take_steps_and_durations_test() {
  use cli, _ <- with_cli
  assert ok(cli(["ramp", "new_checkout", "1,5,100", "2h"]))
    == "new_checkout is ramping.\n"
  let show = ok(cli(["show", "new_checkout"]))
  assert string.contains(show, "rollout:  1% by user")
  assert string.contains(show, "1% → 5% → 100% every 2h, next step ")
  let _ = ok(cli(["pause", "new_checkout"]))
  assert string.contains(ok(cli(["show", "new_checkout"])), ", paused")
}

pub fn mistakes_explain_themselves_test() {
  use cli, _ <- with_cli
  assert { cli([]) }.status == 0
  let unknown = cli(["frobnicate"])
  assert unknown.status == 2
  assert string.contains(unknown.output, "unknown command")
  assert { cli(["rollout", "new_checkout", "150"]) }.status == 2
  assert { cli(["allow", "new_checkout", "bob"]) }.status == 2
  assert { cli(["ramp", "new_checkout", "1,5", "soon"]) }.status == 2
  assert { cli(["list", "--colour"]) }.status == 2
  let missing = cli(["kill", "no_such_flag"])
  assert missing.status == 1
  assert string.contains(missing.output, "no flag named no_such_flag")
}

pub fn list_json_is_the_snapshot_test() {
  use cli, _ <- with_cli
  let _ = ok(cli(["rollout", "search_v2", "50"]))
  let output = ok(cli(["list", "--json"]))
  let assert Ok(snapshot) = json.parse(output, flags.snapshot_decoder())
  let assert [#("search_v2", setting)] = snapshot.settings
  assert setting.rollout == 5000
}
