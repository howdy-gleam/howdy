//// Account lifecycle SQL. Callers hold the user's row lock when changing it.

import gleam/dynamic/decode
import gleam/result
import gloo/repo.{type Repo}
import gloo/sql
import howdy/auth/internal/database as db
import howdy/auth/internal/security_store
import howdy/auth/internal/token
import howdy/service

pub type EmailChange {
  EmailChange(
    old_email: String,
    new_email: String,
    group_id: String,
    mode: String,
  )
}

pub fn version(conn: Repo, user_id: String) -> service.Result(Int) {
  use rows <- result.try(db.query(
    conn,
    "SELECT session_version FROM howdy_auth_users WHERE id = $1",
    [sql.string(user_id)],
    decode.field(0, decode.int, decode.success),
  ))
  case rows {
    [version] -> Ok(version)
    _ -> Error(service.Unauthorized)
  }
}

pub fn revoke(conn: Repo, user_id: String) -> service.Result(Nil) {
  use _ <- result.try(
    db.execute(
      conn,
      "UPDATE howdy_auth_users SET session_version = session_version + 1 WHERE id = $1",
      [sql.string(user_id)],
    ),
  )
  db.execute(conn, "DELETE FROM howdy_auth_sessions WHERE user_id = $1", [
    sql.string(user_id),
  ])
}

pub fn request_email(
  conn: Repo,
  user_id: String,
  session_id: String,
  digest: String,
  change: EmailChange,
  expires_at: Int,
) -> service.Result(Nil) {
  use _ <- result.try(
    db.execute(
      conn,
      "DELETE FROM howdy_auth_email_changes WHERE user_id = $1 OR expires_at <= $2",
      [sql.string(user_id), sql.int(token.now())],
    ),
  )
  db.execute(
    conn,
    "INSERT INTO howdy_auth_email_changes(digest, user_id, session_id, old_email, new_email, group_id, mode, expires_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8)",
    [
      sql.string(digest),
      sql.string(user_id),
      sql.string(session_id),
      sql.string(change.old_email),
      sql.string(change.new_email),
      sql.string(change.group_id),
      sql.string(change.mode),
      sql.int(expires_at),
    ],
  )
}

pub fn discard_email(conn: Repo, digest: String) -> service.Result(Nil) {
  db.execute(conn, "DELETE FROM howdy_auth_email_changes WHERE digest = $1", [
    sql.string(digest),
  ])
}

pub fn consume_email(
  conn: Repo,
  user_id: String,
  session_id: String,
  digest: String,
) -> service.Result(EmailChange) {
  use rows <- result.try(
    db.query(
      conn,
      "DELETE FROM howdy_auth_email_changes WHERE digest = $1 AND user_id = $2 AND session_id = $3 AND expires_at > $4 RETURNING old_email, new_email, group_id, mode",
      [
        sql.string(digest),
        sql.string(user_id),
        sql.string(session_id),
        sql.int(token.now()),
      ],
      {
        use old <- decode.field(0, decode.string)
        use new <- decode.field(1, decode.string)
        use group <- decode.field(2, decode.string)
        use mode <- decode.field(3, decode.string)
        decode.success(EmailChange(old, new, group, mode))
      },
    ),
  )
  case rows {
    [change] -> Ok(change)
    _ -> Error(service.Unauthorized)
  }
}

pub fn change_email(
  conn: Repo,
  user_id: String,
  email: String,
  login_key: String,
) -> service.Result(Nil) {
  use _ <- result.try(
    db.execute(
      conn,
      "UPDATE howdy_auth_users SET email = $1, login_key = $2, updated_at = "
        <> db.write_time(conn, "$3")
        <> " WHERE id = $4",
      [
        sql.string(email),
        sql.string(login_key),
        sql.int(token.now()),
        sql.string(user_id),
      ],
    ),
  )
  db.execute(
    conn,
    "UPDATE howdy_auth_identities SET subject = $1 WHERE user_id = $2 AND issuer = 'email'",
    [sql.string(login_key), sql.string(user_id)],
  )
}

/// Invalidate pending sensitive operations as well as sessions. Provider
/// callbacks already consumed in another process must recheck the session.
pub fn clear_pending(conn: Repo, user_id: String) -> service.Result(Nil) {
  use _ <- result.try(security_store.clear(conn, user_id))
  use _ <- result.try(
    db.execute(conn, "DELETE FROM howdy_auth_email_changes WHERE user_id = $1", [
      sql.string(user_id),
    ]),
  )
  db.execute(
    conn,
    "DELETE FROM howdy_auth_provider_attempts WHERE link_user = $1",
    [sql.string(user_id)],
  )
}

pub fn linked(
  conn: Repo,
  user_id: String,
) -> service.Result(List(#(String, String))) {
  db.query(
    conn,
    "SELECT provider, issuer FROM howdy_auth_provider_identities WHERE user_id = $1 ORDER BY provider, issuer",
    [sql.string(user_id)],
    {
      use provider <- decode.field(0, decode.string)
      use issuer <- decode.field(1, decode.string)
      decode.success(#(provider, issuer))
    },
  )
}

pub fn unlink(
  conn: Repo,
  user_id: String,
  issuer: String,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "DELETE FROM howdy_auth_provider_identities WHERE user_id = $1 AND issuer = $2",
    [sql.string(user_id), sql.string(issuer)],
  )
}

pub fn has_password(conn: Repo, user_id: String) -> service.Result(Bool) {
  db.query(
    conn,
    "SELECT user_id FROM howdy_auth_passwords WHERE user_id = $1",
    [sql.string(user_id)],
    decode.field(0, decode.string, decode.success),
  )
  |> result.map(fn(rows) { rows != [] })
}

pub fn delete(conn: Repo, user_id: String) -> service.Result(Nil) {
  db.execute(conn, "DELETE FROM howdy_auth_users WHERE id = $1", [
    sql.string(user_id),
  ])
}

pub fn prune(conn: Repo) -> service.Result(Nil) {
  db.execute(
    conn,
    "DELETE FROM howdy_auth_email_changes WHERE expires_at <= $1",
    [sql.int(token.now())],
  )
}

pub fn invalidate_email_changes(conn: Repo) -> service.Result(Nil) {
  db.execute(conn, "DELETE FROM howdy_auth_email_changes", [])
}
