//// Application-owned data beside auth's, through `howdy/database`: a package
//// of migrations for the `notes_` namespace, and services that run on either
//// database and answer with `howdy/service` errors.

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/result
import gleam/string
import gleam/time/timestamp
import gloo/migration as gloo_migration
import gloo/repo.{type Repo}
import gloo/sql
import howdy/auth/user.{type User}
import howdy/database
import howdy/migration
import howdy/service

pub type Note {
  Note(id: String, title: String, created: Int)
}

const limit = 100

pub fn schema() -> migration.Package {
  migration.Package("notes", [
    gloo_migration.new(1, "create_notes", "CREATE TABLE notes_notes (
         id TEXT PRIMARY KEY,
         user_id TEXT NOT NULL REFERENCES howdy_auth_users(id),
         title TEXT NOT NULL,
         CONSTRAINT notes_notes_title UNIQUE (user_id, title)
       )" <> migration.per_database(
      postgres: "; ALTER TABLE notes_notes ADD COLUMN created TIMESTAMPTZ NOT NULL",
      sqlite: "; ALTER TABLE notes_notes ADD COLUMN created BIGINT NOT NULL DEFAULT 0",
    )),
  ])
}

pub fn to_json(note: Note) -> Json {
  json.object([
    #("id", json.string(note.id)),
    #("title", json.string(note.title)),
    #("created", json.int(note.created)),
  ])
}

pub fn list(db: Repo, owner: User) -> service.Result(List(Note)) {
  use conn <- database.connect(db)
  database.query(
    conn,
    "SELECT id, title, "
      <> database.read_time(conn, "created")
      <> " FROM notes_notes WHERE user_id = $1 ORDER BY created, id",
    [sql.string(owner.id)],
    {
      use id <- decode.field(0, decode.string)
      use title <- decode.field(1, decode.string)
      use created <- decode.field(2, decode.int)
      decode.success(Note(id:, title:, created:))
    },
  )
}

/// Counting and then inserting is a read before a write, so it takes the
/// write lock up front; two requests cannot both squeeze under the limit.
pub fn create(db: Repo, owner: User, title: String) -> service.Result(Note) {
  let title = string.trim(title)
  use _ <- result.try(case string.length(title) {
    0 -> Error(service.Invalid("a note needs a title"))
    n if n > 200 -> Error(service.Invalid("a title is at most 200 characters"))
    _ -> Ok(Nil)
  })
  use conn <- database.write_transaction(db, touching: "notes_notes")
  use held <- result.try(database.one(
    conn,
    "SELECT COUNT(*) FROM notes_notes WHERE user_id = $1",
    [sql.string(owner.id)],
    decode.field(0, decode.int, decode.success),
    or: service.Internal("notes count returned no row"),
  ))
  use _ <- result.try(case held < limit {
    True -> Ok(Nil)
    False -> Error(service.Conflict("delete a note before adding another"))
  })
  let #(created, _) =
    timestamp.to_unix_seconds_and_nanoseconds(timestamp.system_time())
  let id = bit_array.base64_url_encode(crypto.strong_random_bytes(16), False)
  let note = Note(id:, title:, created:)
  use _ <- result.map(
    database.execute_or(
      conn,
      "INSERT INTO notes_notes(id, user_id, title, created) VALUES ($1, $2, $3, "
        <> database.write_time(conn, "$4")
        <> ")",
      [
        sql.string(note.id),
        sql.string(owner.id),
        sql.string(note.title),
        sql.int(note.created),
      ],
      on_constraint: fn(_) { service.Conflict("you already have that note") },
    ),
  )
  note
}

pub fn delete(db: Repo, owner: User, id: String) -> service.Result(Nil) {
  use conn <- database.write_transaction(db, touching: "notes_notes")
  use _ <- result.try(database.one(
    conn,
    "SELECT id FROM notes_notes n WHERE id = $1 AND user_id = $2"
      <> database.for_update(conn, "n"),
    [sql.string(id), sql.string(owner.id)],
    decode.field(0, decode.string, decode.success),
    or: service.NotFound("note not found"),
  ))
  database.execute(conn, "DELETE FROM notes_notes WHERE id = $1", [
    sql.string(id),
  ])
}

/// For `auth.with_account_deletion`: `conn` is auth's deletion transaction,
/// so the notes and the account go together or not at all.
pub fn delete_all(conn: Repo, owner: User) -> service.Result(Nil) {
  database.execute(conn, "DELETE FROM notes_notes WHERE user_id = $1", [
    sql.string(owner.id),
  ])
}
