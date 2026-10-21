//// Flag settings kept in a Gloo Repo, on PostgreSQL or SQLite, through
//// `howdy/database`. Every node reading the same database shares them.
////
//// ```gleam
//// import howdy/flags
//// import howdy/flags/database as flags_database
////
//// let assert Ok(Nil) = migration.run(db, [flags_database.schema()])
//// let assert Ok(store) = flags_database.store(db)
//// let assert Ok(features) =
////   flags.new(store) |> flags.register(my_app.all_flags()) |> flags.start
//// ```

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gloo/migration as gloo_migration
import gloo/repo.{type Repo}
import gloo/sql
import gloo/value.{type GlooValue}
import howdy/database
import howdy/flags.{
  type Change, type Setting, type Snapshot, type Target, type Update, Change,
  Delete, GroupSummary, Ramp, Save, Setting, Snapshot, Unchanged,
}
import howdy/flags/internal/time
import howdy/migration
import howdy/service
import logging

/// The `howdy_flags_` tables. Run with `howdy/migration` during deployment.
pub fn schema() -> migration.Package {
  migration.Package("howdy_flags", [
    gloo_migration.new(1, "create_flags", "CREATE TABLE howdy_flags_settings (
         flag TEXT PRIMARY KEY,
         killed BIGINT NOT NULL CHECK (killed IN (0, 1)),
         rollout BIGINT NOT NULL CHECK (rollout BETWEEN 0 AND 10000),
         bucketing TEXT NOT NULL CHECK (bucketing IN ('user', 'organization')),
         ramp_steps TEXT,
         ramp_every BIGINT
       );
       CREATE TABLE howdy_flags_rules (
         flag TEXT NOT NULL REFERENCES howdy_flags_settings(flag) ON DELETE CASCADE,
         target TEXT NOT NULL,
         effect TEXT NOT NULL CHECK (effect IN ('allow', 'block')),
         PRIMARY KEY (flag, target)
       );
       CREATE TABLE howdy_flags_groups (
         name TEXT PRIMARY KEY,
         description TEXT NOT NULL
       );
       CREATE TABLE howdy_flags_members (
         group_name TEXT NOT NULL REFERENCES howdy_flags_groups(name) ON DELETE CASCADE,
         member TEXT NOT NULL,
         PRIMARY KEY (group_name, member)
       );
       CREATE TABLE howdy_flags_changes (
         id BIGINT PRIMARY KEY,
         flag TEXT,
         actor TEXT NOT NULL,
         summary TEXT NOT NULL,
         before TEXT,
         after TEXT
       );
       CREATE INDEX howdy_flags_changes_flag ON howdy_flags_changes (flag, id);
       CREATE TABLE howdy_flags_version (
         id BIGINT PRIMARY KEY CHECK (id = 1),
         version BIGINT NOT NULL
       );
       INSERT INTO howdy_flags_version (id, version) VALUES (1, 0)" <> migration.per_database(
      postgres: "; ALTER TABLE howdy_flags_settings ADD COLUMN ramp_next TIMESTAMPTZ;
          ALTER TABLE howdy_flags_changes ADD COLUMN at TIMESTAMPTZ NOT NULL",
      sqlite: "; ALTER TABLE howdy_flags_settings ADD COLUMN ramp_next BIGINT;
          ALTER TABLE howdy_flags_changes ADD COLUMN at BIGINT NOT NULL DEFAULT 0",
    )),
  ])
}

/// A store over this Repo, once its schema is checked: the flags refuse to
/// start on a database that has not been migrated.
pub fn store(repo: Repo) -> service.Result(flags.Store) {
  use _ <- result.try(migration.check(repo, schema()))
  flags.store(
    named: "database",
    load: fn() { load(repo) },
    version: fn() {
      use conn <- database.connect(repo)
      latest_version(conn)
    },
    history: fn(flag, limit) { history(repo, flag, limit) },
  )
  |> flags.with_writer(
    flags.Writer(
      update: fn(key, by, decide) { update(repo, key, by, decide) },
      find_change: fn(id) {
        use conn <- database.connect(repo)
        read_change(conn, id)
      },
      create_group: fn(name, description, by) {
        create_group(repo, name, description, by)
      },
      delete_group: fn(name, by) { delete_group(repo, name, by) },
      add_member: fn(group, member, by) { add_member(repo, group, member, by) },
      remove_member: fn(group, member, by) {
        remove_member(repo, group, member, by)
      },
    ),
  )
  |> Ok
}

// -- Reading -----------------------------------------------------------------

fn latest_version(conn: Repo) -> service.Result(Int) {
  database.one(
    conn,
    "SELECT version FROM howdy_flags_version WHERE id = 1",
    [],
    decode.field(0, decode.int, decode.success),
    or: service.Internal("the flags version row is missing"),
  )
}

/// The version is read first: a change committed while the rest is read
/// raises it again, so the next check reloads.
fn load(repo: Repo) -> service.Result(Snapshot) {
  use conn <- database.connect(repo)
  use version <- result.try(latest_version(conn))
  use settings <- result.try(read_settings(conn, None))
  use groups <- result.try(read_groups(conn))
  Ok(Snapshot(version:, settings:, groups:))
}

/// Every stored setting, or only `only`'s. Rows are locked for update when
/// `only` is given, inside a transaction.
fn read_settings(
  conn: Repo,
  only: Option(String),
) -> service.Result(List(#(String, Setting))) {
  let #(filter, args, lock) = case only {
    Some(key) -> #(
      " WHERE s.flag = $1",
      [sql.string(key)],
      database.for_update(conn, "s"),
    )
    None -> #("", [], "")
  }
  use rows <- result.try(
    database.query(
      conn,
      "SELECT s.flag, s.killed, s.rollout, s.bucketing, s.ramp_steps, s.ramp_every, "
        <> database.read_time(conn, "s.ramp_next")
        <> " FROM howdy_flags_settings s"
        <> filter
        <> " ORDER BY s.flag"
        <> lock,
      args,
      {
        use flag <- decode.field(0, decode.string)
        use killed <- decode.field(1, decode.int)
        use rollout <- decode.field(2, decode.int)
        use bucketing <- decode.field(3, decode.string)
        use steps <- decode.field(4, decode.optional(decode.string))
        use every <- decode.field(5, decode.optional(decode.int))
        use next <- decode.field(6, decode.optional(decode.int))
        decode.success(#(flag, killed, rollout, bucketing, steps, every, next))
      },
    ),
  )
  use rows <- result.try(
    list.try_map(rows, fn(row) {
      let #(flag, killed, rollout, bucketing, steps, every, next) = row
      use ramp <- result.map(case steps, every {
        Some(steps), Some(every) ->
          string.split(steps, ",")
          |> list.try_map(int.parse)
          |> result.map(fn(steps) { Some(Ramp(steps:, every:, next:)) })
          |> result.map_error(fn(_) {
            unreadable("the ramp steps stored for " <> flag, steps)
          })
        _, _ -> Ok(None)
      })
      #(
        flag,
        Setting(
          killed: killed == 1,
          rollout:,
          bucketing: flags.bucketing_from_string(bucketing),
          allowed: [],
          blocked: [],
          ramp:,
        ),
      )
    }),
  )
  use rules <- result.try(
    database.query(
      conn,
      "SELECT s.flag, s.target, s.effect FROM howdy_flags_rules s"
        <> filter
        <> " ORDER BY s.flag, s.target",
      args,
      {
        use flag <- decode.field(0, decode.string)
        use target <- decode.field(1, decode.string)
        use effect <- decode.field(2, decode.string)
        decode.success(#(flag, target, effect))
      },
    ),
  )
  use rules <- result.try(
    list.try_map(rules, fn(rule) {
      flags.target_from_string(rule.1)
      |> result.map(fn(target) { #(rule.0, target, rule.2) })
      |> result.map_error(fn(_) {
        unreadable("a rule stored for " <> rule.0, rule.1)
      })
    }),
  )
  Ok(
    list.map(rows, fn(row) {
      let #(key, setting) = row
      let pick = fn(effect) {
        list.filter_map(rules, fn(rule) {
          case rule.0 == key && rule.2 == effect {
            True -> Ok(rule.1)
            False -> Error(Nil)
          }
        })
      }
      #(key, Setting(..setting, allowed: pick("allow"), blocked: pick("block")))
    }),
  )
}

/// Something stored cannot be read back. Nothing in this package writes
/// such a row, so it was changed by hand or by another version; say so
/// in the log and refuse, rather than carry on with part of the settings.
fn unreadable(what: String, text: String) -> service.Error {
  let message = what <> " cannot be read: " <> string.inspect(text)
  logging.log(logging.Error, "howdy/flags/database: " <> message)
  service.Internal(message)
}

fn read_groups(conn: Repo) -> service.Result(List(flags.GroupSummary)) {
  use groups <- result.try(
    database.query(
      conn,
      "SELECT name, description FROM howdy_flags_groups ORDER BY name",
      [],
      {
        use name <- decode.field(0, decode.string)
        use description <- decode.field(1, decode.string)
        decode.success(#(name, description))
      },
    ),
  )
  use members <- result.try(
    database.query(
      conn,
      "SELECT group_name, member FROM howdy_flags_members ORDER BY group_name, member",
      [],
      {
        use group <- decode.field(0, decode.string)
        use member <- decode.field(1, decode.string)
        decode.success(#(group, member))
      },
    ),
  )
  Ok(
    list.map(groups, fn(group) {
      GroupSummary(
        name: group.0,
        description: group.1,
        members: list.filter_map(members, fn(member) {
          case member.0 == group.0 {
            True -> flags.target_from_string(member.1)
            False -> Error(Nil)
          }
        }),
      )
    }),
  )
}

// -- Changing a flag ---------------------------------------------------------

/// Every change holds the version row, which serializes them, including the
/// first change to a flag, whose row does not exist yet to lock.
fn writing(
  repo: Repo,
  run: fn(Repo) -> service.Result(a),
) -> service.Result(a) {
  use conn <- database.write_transaction(repo, touching: "howdy_flags_version")
  use _ <- result.try(database.one(
    conn,
    "SELECT v.version FROM howdy_flags_version v WHERE v.id = 1"
      <> database.for_update(conn, "v"),
    [],
    decode.field(0, decode.int, decode.success),
    or: service.Internal("the flags version row is missing"),
  ))
  run(conn)
}

fn update(
  repo: Repo,
  key: String,
  by: String,
  decide: fn(Option(Setting)) -> service.Result(Update),
) -> service.Result(Bool) {
  use conn <- writing(repo)
  use stored <- result.try(read_settings(conn, Some(key)))
  let before = case stored {
    [#(_, setting), ..] -> Some(setting)
    [] -> None
  }
  use update <- result.try(decide(before))
  case update {
    Unchanged -> Ok(False)
    Save(setting:, summary:) -> {
      use _ <- result.try(write_setting(conn, key, setting))
      use _ <- result.map(record(
        conn,
        Some(key),
        by,
        summary,
        before,
        Some(setting),
      ))
      True
    }
    Delete(summary:) -> {
      use _ <- result.try(delete_setting(conn, key))
      use _ <- result.map(record(conn, Some(key), by, summary, before, None))
      True
    }
  }
}

fn write_setting(
  conn: Repo,
  key: String,
  setting: Setting,
) -> service.Result(Nil) {
  let #(steps, every, next) = case setting.ramp {
    Some(ramp) -> #(
      Some(list.map(ramp.steps, int.to_string) |> string.join(",")),
      Some(ramp.every),
      ramp.next,
    )
    None -> #(None, None, None)
  }
  use _ <- result.try(
    database.execute(
      conn,
      "INSERT INTO howdy_flags_settings (flag, killed, rollout, bucketing, ramp_steps, ramp_every, ramp_next)
     VALUES ($1, $2, $3, $4, $5, $6, "
        <> database.write_time(conn, "$7")
        <> ") ON CONFLICT (flag) DO UPDATE SET killed = excluded.killed,
       rollout = excluded.rollout, bucketing = excluded.bucketing,
       ramp_steps = excluded.ramp_steps, ramp_every = excluded.ramp_every,
       ramp_next = excluded.ramp_next",
      [
        sql.string(key),
        sql.int(case setting.killed {
          True -> 1
          False -> 0
        }),
        sql.int(setting.rollout),
        sql.string(flags.bucketing_to_string(setting.bucketing)),
        sql.nullable(sql.string, steps),
        sql.nullable(sql.int, every),
        sql.nullable(sql.int, next),
      ],
    ),
  )
  use _ <- result.try(
    database.execute(conn, "DELETE FROM howdy_flags_rules WHERE flag = $1", [
      sql.string(key),
    ]),
  )
  let rules =
    list.append(
      list.map(setting.allowed, fn(target) { #(target, "allow") }),
      list.map(setting.blocked, fn(target) { #(target, "block") }),
    )
  list.try_fold(rules, Nil, fn(_, rule) {
    database.execute(
      conn,
      "INSERT INTO howdy_flags_rules (flag, target, effect) VALUES ($1, $2, $3)",
      [
        sql.string(key),
        sql.string(flags.target_to_string(rule.0)),
        sql.string(rule.1),
      ],
    )
  })
}

/// Rules first, so this does not rely on SQLite enforcing the cascade.
fn delete_setting(conn: Repo, key: String) -> service.Result(Nil) {
  use _ <- result.try(
    database.execute(conn, "DELETE FROM howdy_flags_rules WHERE flag = $1", [
      sql.string(key),
    ]),
  )
  database.execute(conn, "DELETE FROM howdy_flags_settings WHERE flag = $1", [
    sql.string(key),
  ])
}

// -- Groups ------------------------------------------------------------------

fn create_group(
  repo: Repo,
  name: String,
  description: String,
  by: String,
) -> service.Result(Nil) {
  use conn <- writing(repo)
  use _ <- result.try(
    database.execute_or(
      conn,
      "INSERT INTO howdy_flags_groups (name, description) VALUES ($1, $2)",
      [sql.string(name), sql.string(description)],
      on_constraint: fn(_) {
        service.Conflict("there is already a group named " <> name)
      },
    ),
  )
  record(conn, None, by, "Created group:" <> name, None, None)
}

fn delete_group(repo: Repo, name: String, by: String) -> service.Result(Nil) {
  use conn <- writing(repo)
  use using <- result.try(database.query(
    conn,
    "SELECT flag FROM howdy_flags_rules WHERE target = $1 ORDER BY flag",
    [sql.string(flags.target_to_string(flags.Group(name)))],
    decode.field(0, decode.string, decode.success),
  ))
  use _ <- result.try(case using {
    [] -> Ok(Nil)
    keys ->
      Error(service.Conflict(
        "remove the group from these flags first: " <> string.join(keys, ", "),
      ))
  })
  use _ <- result.try(require_group(conn, name))
  use _ <- result.try(
    database.execute(
      conn,
      "DELETE FROM howdy_flags_members WHERE group_name = $1",
      [sql.string(name)],
    ),
  )
  use _ <- result.try(
    database.execute(conn, "DELETE FROM howdy_flags_groups WHERE name = $1", [
      sql.string(name),
    ]),
  )
  record(conn, None, by, "Deleted group:" <> name, None, None)
}

fn add_member(
  repo: Repo,
  group: String,
  member: Target,
  by: String,
) -> service.Result(Nil) {
  use conn <- writing(repo)
  use _ <- result.try(require_group(conn, group))
  use _ <- result.try(
    database.execute_or(
      conn,
      "INSERT INTO howdy_flags_members (group_name, member) VALUES ($1, $2)",
      [sql.string(group), sql.string(flags.target_to_string(member))],
      on_constraint: fn(_) { service.Conflict("already in the group") },
    ),
  )
  record(
    conn,
    None,
    by,
    "Added " <> flags.target_to_string(member) <> " to group:" <> group,
    None,
    None,
  )
}

fn remove_member(
  repo: Repo,
  group: String,
  member: Target,
  by: String,
) -> service.Result(Nil) {
  use conn <- writing(repo)
  use _ <- result.try(database.one(
    conn,
    "SELECT member FROM howdy_flags_members WHERE group_name = $1 AND member = $2",
    [sql.string(group), sql.string(flags.target_to_string(member))],
    decode.field(0, decode.string, decode.success),
    or: service.NotFound("not in the group"),
  ))
  use _ <- result.try(
    database.execute(
      conn,
      "DELETE FROM howdy_flags_members WHERE group_name = $1 AND member = $2",
      [sql.string(group), sql.string(flags.target_to_string(member))],
    ),
  )
  record(
    conn,
    None,
    by,
    "Removed " <> flags.target_to_string(member) <> " from group:" <> group,
    None,
    None,
  )
}

fn require_group(conn: Repo, name: String) -> service.Result(Nil) {
  database.one(
    conn,
    "SELECT name FROM howdy_flags_groups WHERE name = $1",
    [sql.string(name)],
    decode.field(0, decode.string, decode.success),
    or: service.NotFound("no group named " <> name),
  )
  |> result.replace(Nil)
}

// -- History -----------------------------------------------------------------

fn history(
  repo: Repo,
  flag: Option(String),
  limit: Int,
) -> service.Result(List(Change)) {
  use conn <- database.connect(repo)
  let #(filter, args) = case flag {
    Some(key) -> #(" WHERE flag = $1", [sql.string(key)])
    None -> #("", [])
  }
  use rows <- result.try(database.query(
    conn,
    select_changes(conn)
      <> filter
      <> " ORDER BY id DESC LIMIT "
      <> int.to_string(limit),
    args,
    change_decoder(),
  ))
  list.try_map(rows, parse_change)
}

fn read_change(conn: Repo, id: Int) -> service.Result(Change) {
  use row <- result.try(database.one(
    conn,
    select_changes(conn) <> " WHERE id = $1",
    [sql.int(id)],
    change_decoder(),
    or: service.NotFound("no such change"),
  ))
  parse_change(row)
}

fn select_changes(conn: Repo) -> String {
  "SELECT id, flag, "
  <> database.read_time(conn, "at")
  <> ", actor, summary, before, after FROM howdy_flags_changes"
}

/// A change as stored, with its settings still JSON.
type StoredChange {
  StoredChange(
    id: Int,
    flag: Option(String),
    at: Int,
    by: String,
    summary: String,
    before: Option(String),
    after: Option(String),
  )
}

fn change_decoder() -> decode.Decoder(StoredChange) {
  use id <- decode.field(0, decode.int)
  use flag <- decode.field(1, decode.optional(decode.string))
  use at <- decode.field(2, decode.int)
  use by <- decode.field(3, decode.string)
  use summary <- decode.field(4, decode.string)
  use before <- decode.field(5, decode.optional(decode.string))
  use after <- decode.field(6, decode.optional(decode.string))
  decode.success(StoredChange(id:, flag:, at:, by:, summary:, before:, after:))
}

/// A stored setting that cannot be read is an error: `undo` would take a
/// missing `before` as "nothing was stored" and delete the flag's setting.
fn parse_change(stored: StoredChange) -> service.Result(Change) {
  let parse = fn(text: Option(String), which: String) {
    case text {
      None -> Ok(None)
      Some(text) ->
        json.parse(text, flags.setting_decoder())
        |> result.map(Some)
        |> result.map_error(fn(_) {
          unreadable(
            "the setting " <> which <> " change " <> int.to_string(stored.id),
            text,
          )
        })
    }
  }
  use before <- result.try(parse(stored.before, "before"))
  use after <- result.try(parse(stored.after, "after"))
  Ok(Change(
    id: stored.id,
    flag: stored.flag,
    at: stored.at,
    by: stored.by,
    summary: stored.summary,
    before:,
    after:,
  ))
}

/// Record a change and raise the version other nodes watch for. The new
/// version is the change's id, so ids follow the order changes committed.
fn record(
  conn: Repo,
  flag: Option(String),
  by: String,
  summary: String,
  before: Option(Setting),
  after: Option(Setting),
) -> service.Result(Nil) {
  use id <- result.try(database.one(
    conn,
    "UPDATE howdy_flags_version SET version = version + 1 WHERE id = 1 RETURNING version",
    [],
    decode.field(0, decode.int, decode.success),
    or: service.Internal("the flags version row is missing"),
  ))
  let encode = fn(setting: Option(Setting)) -> GlooValue {
    sql.nullable(
      sql.string,
      option.map(setting, fn(setting) {
        json.to_string(flags.setting_to_json(setting))
      }),
    )
  }
  let now = time.now()
  database.execute(
    conn,
    "INSERT INTO howdy_flags_changes (id, flag, at, actor, summary, before, after) VALUES ($1, $2, "
      <> database.write_time(conn, "$3")
      <> ", $4, $5, $6, $7)",
    [
      sql.int(id),
      sql.nullable(sql.string, flag),
      sql.int(now),
      sql.string(by),
      sql.string(summary),
      encode(before),
      encode(after),
    ],
  )
}
