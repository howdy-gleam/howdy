//// Hearing about changes on PostgreSQL through `NOTIFY`, instead of asking.
////
//// Each table the admin shows gets a statement-level trigger,
//// `howdy_admin_notify`, that sends the table's name on the `howdy_admin`
//// channel after any insert, update, delete or truncate. A grid listens
//// with `howdy/database/postgres.listen`, on a connection of its own opened
//// with the pool's settings, and reloads when its table is named. `howdy/migration` ignores
//// triggers with this prefix when it checks a package's schema.
////
//// SQLite has no such mechanism, and neither does `sqlight` expose its
//// update hook, so there the grid keeps polling.

import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import gleam/result
import gloo/repo.{type Repo}
import gloo/sql
import gloo/value.{type GlooValue}
import howdy/admin/internal/schema
import howdy/database.{Postgres, Sqlite}
import howdy/database/postgres
import howdy/service
import logging
import pog

/// The channel every notification arrives on. The payload is the table.
pub const channel = "howdy_admin"

/// The trigger and function name.
pub const trigger = "howdy_admin_notify"

/// Whether this Repo is on PostgreSQL, where the grid can listen. Whether
/// the pool's settings can be found is only known when it tries.
pub fn available(repo: Repo, _settings: Option(pog.Config)) -> Bool {
  database.backend(repo) == Ok(Postgres)
}

/// Make sure the trigger is on `table`. Creating the function again is
/// harmless; the trigger is only created when missing, so a second grid on
/// the same table changes nothing.
pub fn install(repo: Repo, table: schema.Table) -> service.Result(Nil) {
  use conn <- database.connect(repo)
  use backend <- result.try(database.backend(conn))
  case backend {
    Sqlite -> Error(service.Invalid("SQLite has no NOTIFY"))
    Postgres -> {
      use _ <- result.try(
        execute(
          conn,
          "CREATE OR REPLACE FUNCTION "
            <> trigger
            <> "() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_notify('"
            <> channel
            <> "', TG_TABLE_NAME); RETURN NULL; END $$",
          [],
        ),
      )
      use present <- result.try(
        repo.all(
          conn,
          "SELECT 1 FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE t.tgname = $1 AND c.relname = $2 AND n.nspname = current_schema()",
          [sql.string(trigger), sql.string(table.name)],
          decode.field(0, decode.int, decode.success),
        )
        |> result.map_error(failed),
      )
      case present {
        [_, ..] -> Ok(Nil)
        [] ->
          execute(
            conn,
            "CREATE TRIGGER "
              <> trigger
              <> " AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON "
              <> schema.quote(table.name)
              <> " FOR EACH STATEMENT EXECUTE FUNCTION "
              <> trigger
              <> "()",
            [],
          )
      }
    }
  }
}

/// Remove the function and, with it, every trigger the admin installed.
pub fn uninstall(repo: Repo) -> service.Result(Nil) {
  use conn <- database.connect(repo)
  use backend <- result.try(database.backend(conn))
  case backend {
    Sqlite -> Ok(Nil)
    Postgres ->
      execute(conn, "DROP FUNCTION IF EXISTS " <> trigger <> "() CASCADE", [])
  }
}

/// Call `notify` with each table name announced on the channel, from a
/// listener linked to the caller, until the caller exits. Connects with the
/// settings the app gave, or else with the pool's. An `Error` means no
/// notifications will come, and says why in the log: the caller should
/// poll. A lost connection is opened again by the listener; the grid's
/// slower poll covers what was sent meanwhile.
pub fn subscribe(
  repo: Repo,
  settings: Option(pog.Config),
  notify: fn(String) -> Nil,
) -> Result(postgres.Listener, Nil) {
  let listening = case settings {
    Some(config) -> postgres.listen_via(config, channel, notify)
    None -> postgres.listen(repo, channel, notify)
  }
  case listening {
    Ok(listener) -> Ok(listener)
    Error(error) -> {
      logging.log(
        logging.Warning,
        "howdy/admin: could not listen for changes on PostgreSQL: "
          <> postgres.listen_error_to_string(error)
          <> case error, settings {
          postgres.SettingsNotFound, None ->
            "; pass them with howdy/admin.notify_via"
          _, _ -> ""
        }
          <> "; the grid polls instead",
      )
      Error(Nil)
    }
  }
}

fn execute(
  conn: Repo,
  statement: String,
  parameters: List(GlooValue),
) -> service.Result(Nil) {
  repo.execute(conn, statement, parameters)
  |> result.map(fn(_) { Nil })
  |> result.map_error(failed)
}

fn failed(reason) -> service.Error {
  service.Invalid(gloo_error_to_string(reason))
}

@external(erlang, "gloo@error", "to_string")
fn gloo_error_to_string(reason: a) -> String
