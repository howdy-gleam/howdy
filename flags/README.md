# howdy_flags

Feature flags for [howdy](https://github.com/mikeyjones/howdy/blob/v2/README.md) apps, defined in code and switched
while the app runs: turned off for everyone at once, allowed or blocked for
users, organizations and groups, and rolled out gradually to a share of
users. Where the settings are kept is up to a store: the app's database,
one process's memory, or a service that manages them for you.

- In development the [admin area](https://github.com/mikeyjones/howdy/blob/v2/admin/README.md) shows them, with their
  kill switches, rules, groups and history.
- On your own servers, a task module gives you [command-line
  management](#the-command-line).
- Behind a hosting service, a read-only store takes the settings from it,
  and the app only checks them.

Add it to `[dependencies]` in `gleam.toml`, from the same release as your
app's other Howdy packages (`howdy add flags` does this for you):

```toml
howdy_flags = { git = "https://github.com/mikeyjones/howdy.git", ref = "v2.1.1", path = "flags" }
```

Put it in `[dependencies]` even when the admin, a dev dependency, already
brings it in. `gleam build` and `gleam test` would then compile the app,
but a production build such as `gleam export erlang-shipment` leaves dev
dependencies out, and fails. `howdy check` reports it.

## Defining and checking flags

A flag is a key, a description and a default. With nothing stored for it,
its default applies, so a flag works in tests, on a fresh deployment, and
before anyone has touched it.

```gleam
import howdy/flags

pub fn new_checkout() -> flags.Flag {
  flags.flag("new_checkout", description: "Stripe-hosted checkout")
}

// A finished feature kept behind a kill switch.
pub fn search_v2() -> flags.Flag {
  flags.flag("search_v2", description: "New search") |> flags.on_by_default
}
```

Keep every flag in one list, so startup and the command line agree. Run
the database store's schema with your other migrations, then start the flags
once at startup and hand them to your app:

```gleam
import howdy/flags/database as flags_database

pub fn all_flags() -> List(flags.Flag) {
  [new_checkout(), search_v2()]
}

let assert Ok(Nil) =
  migration.run(db, [auth.schema(), flags_database.schema()])
let assert Ok(store) = flags_database.store(db)
let assert Ok(features) =
  flags.new(store) |> flags.register(all_flags()) |> flags.start

case flags.enabled(features, new_checkout(), for: flags.user(user.id)) {
  True -> new_checkout_page(ctx)
  False -> checkout_page(ctx)
}
```

The actor is a user, an organization, both (`flags.user(id) |>
flags.in_organization(org)`), or `flags.anonymous()`. The ids are yours;
the package does not depend on `howdy_auth`.

Checks read an in-memory copy of the settings and never query the store.
A change made on a node applies there before the call that made it returns.
Other nodes ask the store for its version every two seconds
(`flags.check_every`) and reload when it has moved, so that is the longest a
kill switch takes to reach every node. If the store becomes unreachable,
checks keep the last settings they loaded.

## What decides a check

In this order, the first that applies wins:

1. Nothing stored for the flag: its default.
2. The kill switch is on: off.
3. A block rule names the user, their organization, or a group either is
   in: off.
4. An allow rule names one of them: on.
5. Their rollout position is below the rollout: on. Otherwise off.

`flags.explain` returns which of these decided, for support and debugging.

## Rolling out

Every user has a position from 0 to 99.99% for each flag, worked out from a
SHA-256 of the flag's key and their id: nothing is stored per user, and
the position never changes. A rollout of 20% is on for everyone below 20%,
so:

- raising a rollout only adds people;
- pausing is leaving it where it is;
- rolling back from 20% to 5% removes exactly the people added after 5%,
  and the first 5% keep it;
- each flag picks a different first 5%, because the key is hashed too.

Roll out by organization (`flags.set_bucketing(.., to: flags.ByOrganization)`)
to switch whole organizations at once, so colleagues see the same app.
Someone without the id the rollout is by only gets the flag at 100%.

Rollouts are in hundredths of a percent: `flags.percent(25)` is `2500`.

```gleam
flags.set_rollout(features, "new_checkout", to: flags.percent(5), by: "mike")
flags.kill(features, "new_checkout", by: "mike")
flags.revive(features, "new_checkout", by: "mike")
```

A ramp raises the rollout through steps on a schedule, such as 1%, 5%, 25%,
50%, 100% an hour apart:

```gleam
flags.start_ramp(
  features,
  "new_checkout",
  steps: [100, 500, 2500, 5000, 10_000],
  every: 3600,
  by: "mike",
)
```

Every running node checks for due steps; each flag's row is locked while a
step is taken, so a step is taken once. Killing the flag or changing the
rollout by hand pauses the ramp; `resume_ramp` carries on from the next step
above the current rollout.

Rolling back changes which code runs, not the data the new code already
wrote: the old path has to cope with it.

## Groups and rules

A group is a named set of users and organizations, such as staff or beta
testers. Rules allow or block a flag for a user, an organization or a group:

```gleam
flags.create_group(features, "beta", description: "Beta testers", by: "mike")
flags.add_member(features, "beta", flags.Organization("acme"), by: "mike")
flags.allow(features, "new_checkout", flags.Group("beta"), by: "mike")
flags.block(features, "new_checkout", flags.User("42"), by: "mike")
```

A group that a rule names cannot be deleted: remove the rule first, so no
flag changes without a record in its history.

## History and undo

Every change records who made it (`by`), when, a summary such as
`Rollout 5% → 20%`, and the setting before and after. `flags.history`
lists them, and `flags.undo(features, change: id, by:)` puts the flag back
as it was before a change, recorded as a change of its own, with any ramp
paused. `flags.forget` deletes what is stored for a flag, putting it back to
its default; it also tidies away keys the code no longer registers.

These operations are privileged: authorize the caller first. In
development the admin calls the kill switch, rule, group and undo operations
as `howdy_admin`.

## The command line

`howdy/flags/cli` manages the flags from a terminal, for servers without the
admin. Give it the app's flags and a way to open their store, in a task
module:

```gleam
// src/tasks/flags.gleam
import howdy/flags/cli
import howdy/flags/database as flags_database

pub fn main() -> Nil {
  cli.main(my_app.all_flags(), fn() {
    flags_database.store(my_app.database())
  })
}
```

```sh
$ gleam run -m tasks/flags list
new_checkout  5%, ramp paused, 2 rules  Stripe-hosted checkout
search_v2     default on                New search
$ gleam run -m tasks/flags rollout new_checkout 20 --by mike
new_checkout is rolled out to 20%.
$ gleam run -m tasks/flags check new_checkout --user 42 --org acme
on: allowed for group:beta
```

| Command | Does |
|---|---|
| `export` | the flags the code defines, as JSON; opens no store |
| `list [--json]` | every flag and its state; `--json` prints everything stored |
| `show KEY` | one flag in full |
| `check KEY [--user ID] [--org ID]` | whether someone gets it, and why |
| `history [KEY] [--limit N]` | the latest changes, numbered |
| `undo CHANGE` | put a flag back as it was before that change |
| `kill KEY`, `revive KEY` | the kill switch |
| `rollout KEY PERCENT` | such as `5` or `12.5` |
| `bucket KEY user\|organization` | what the rollout is by |
| `allow`, `block`, `unlist KEY TARGET` | rules for `user:ID`, `org:ID` or `group:NAME` |
| `ramp KEY STEPS EVERY` | such as `1,5,25,100 1h` |
| `pause`, `resume`, `cancel KEY` | the flag's ramp |
| `reset KEY` | delete what is stored: back to the default |
| `groups`, `group create\|delete\|add\|remove ...` | groups and their members |

Changes go straight to the store, and running nodes pick them up at their
next check. Each is recorded as made by `--by NAME`, or `cli:$USER`. Output
goes to standard output; errors go to standard error, with exit status 1
when a command fails and 2 when it was not understood.

In a release built with `gleam export erlang-shipment`, run it from the
release directory, with the arguments after `-extra`:

```sh
erl -pa */ebin -noshell -eval 'tasks@flags:main()' -extra kill new_checkout
```

`export` prints the flags as the code defines them, for a tool that prepares
somewhere to keep them before they are turned on:

```json
{"format":1,"flags":[{"key":"new_checkout","description":"Stripe-hosted checkout","default":false}]}
```

`format` changes only if a field changes meaning or goes away; new fields
may be added. `flags.to_json` returns the same JSON as a value, and
`flags.export` prints it on its own.

## Stores

A store loads a `Snapshot` of everything kept (settings, groups and a
version that rises with every change), reports its version cheaply, and
lists recent history. A store with a `Writer` can also be changed, through
the management functions, the admin and the command line.

- `howdy/flags/database` keeps them in a Gloo Repo, on PostgreSQL or SQLite.
  Nodes sharing the database share the flags, and a ramp step is taken
  once however many nodes see it due.
- `howdy/flags/memory` keeps them in one process: for tests, or an app on
  one node without a database. `memory.from(snapshot)` starts from a
  snapshot, such as one read from a file.
- `flags.store(named:, load:, version:, history:)` builds a read-only store
  over anything else, such as a service that manages the flags and pushes
  their settings to the app. `flags.with_writer` makes one writable.

`flags.snapshot_to_json` and `flags.snapshot_decoder` are the JSON form of
a snapshot, what `list --json` prints, for moving settings between systems:

```json
{"format":1,"version":12,
 "settings":{"new_checkout":{"killed":false,"rollout":500,"bucketing":"user",
   "allowed":["group:beta"],"blocked":[],
   "ramp":{"steps":[100,500,10000],"every":3600,"next":1790000000}}},
 "groups":[{"name":"beta","description":"Beta testers","members":["org:acme"]}]}
```

Whatever the store, a rollout position is the same SHA-256 of the flag's
key and the id, so anything that computes who is in a rollout agrees with
the app.

## Tests

`gleam test` runs every behaviour against the memory store and the database
store, on SQLite in memory. With
`HOWDY_FLAGS_TEST_POSTGRES_URL` set, such as
`postgres://howdy_flags_test@localhost/postgres`, the same tests run on
PostgreSQL, dropping the package's tables first.
