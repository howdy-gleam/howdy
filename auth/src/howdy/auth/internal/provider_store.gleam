//// Persistent, single-use provider attempts and group-scoped identities.

import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import gleam/result
import gloo/repo.{type Repo}
import gloo/sql
import howdy/auth/internal/database as db
import howdy/auth/internal/token
import howdy/auth/secret
import howdy/service

pub type Attempt {
  Attempt(
    provider: String,
    nonce_digest: String,
    verifier: secret.Secret,
    redirect_uri: String,
    group_id: Option(String),
    mode: String,
    link_user: String,
    link_session: String,
    client: String,
  )
}

pub fn insert(
  conn: Repo,
  state: String,
  browser: String,
  attempt: Attempt,
) -> service.Result(Nil) {
  use _ <- result.try(prune(conn))
  use _ <- result.try(
    db.execute(
      conn,
      "INSERT INTO howdy_auth_provider_attempts(digest, browser_digest, provider, nonce_digest, verifier, redirect_uri, group_id, mode, expires_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)",
      [
        sql.string(token.digest(state)),
        sql.string(token.digest(browser)),
        sql.string(attempt.provider),
        sql.string(attempt.nonce_digest),
        sql.string(secret.reveal(attempt.verifier)),
        sql.string(attempt.redirect_uri),
        sql.nullable(sql.string, attempt.group_id),
        sql.string(attempt.mode),
        sql.int(token.now() + 600),
      ],
    ),
  )
  db.execute(
    conn,
    "UPDATE howdy_auth_provider_attempts SET link_user = $1, link_session = $2, client = $3 WHERE digest = $4",
    [
      sql.string(attempt.link_user),
      sql.string(attempt.link_session),
      sql.string(attempt.client),
      sql.string(token.digest(state)),
    ],
  )
}

pub fn consume(
  conn: Repo,
  state: String,
  browser: String,
  provider: String,
  redirect_uri: String,
) -> service.Result(Attempt) {
  use rows <- result.try(
    db.query(
      conn,
      "DELETE FROM howdy_auth_provider_attempts WHERE digest = $1 AND browser_digest = $2 AND provider = $3 AND redirect_uri = $4 AND expires_at > $5 RETURNING provider, nonce_digest, verifier, redirect_uri, group_id, mode, link_user, link_session, client",
      [
        sql.string(token.digest(state)),
        sql.string(token.digest(browser)),
        sql.string(provider),
        sql.string(redirect_uri),
        sql.int(token.now()),
      ],
      {
        use provider <- decode.field(0, decode.string)
        use nonce <- decode.field(1, decode.string)
        use verifier <- decode.field(2, decode.string)
        use redirect <- decode.field(3, decode.string)
        use group <- decode.field(4, decode.optional(decode.string))
        use mode <- decode.field(5, decode.string)
        use link_user <- decode.field(6, decode.string)
        use link_session <- decode.field(7, decode.string)
        use client <- decode.field(8, decode.string)
        decode.success(Attempt(
          provider,
          nonce,
          secret.wrap(verifier),
          redirect,
          group,
          mode,
          link_user,
          link_session,
          client,
        ))
      },
    ),
  )
  case rows {
    [attempt] -> Ok(attempt)
    _ -> Error(service.Unauthorized)
  }
}

pub fn prune(conn: Repo) -> service.Result(Nil) {
  db.execute(
    conn,
    "DELETE FROM howdy_auth_provider_attempts WHERE expires_at <= $1",
    [sql.int(token.now())],
  )
}

pub fn invalidate(conn: Repo) -> service.Result(Nil) {
  db.execute(conn, "DELETE FROM howdy_auth_provider_attempts", [])
}

pub fn owner(
  conn: Repo,
  issuer: String,
  subject: String,
  scope: String,
) -> service.Result(Option(String)) {
  use rows <- result.try(db.query(
    conn,
    "SELECT user_id FROM howdy_auth_provider_identities WHERE issuer = $1 AND subject = $2 AND scope = $3",
    [sql.string(issuer), sql.string(subject), sql.string(scope)],
    decode.field(0, decode.string, decode.success),
  ))
  case rows {
    [id] -> Ok(Some(id))
    _ -> Ok(None)
  }
}

pub fn attach(
  conn: Repo,
  issuer: String,
  subject: String,
  scope: String,
  user_id: String,
  provider: String,
) -> service.Result(Nil) {
  // ON CONFLICT + readback makes concurrent first sign-ins/linking fail closed.
  // A user has at most one identity per issuer.
  use _ <- result.try(
    db.execute(
      conn,
      "INSERT INTO howdy_auth_provider_identities(issuer, subject, scope, user_id, provider) VALUES ($1,$2,$3,$4,$5) ON CONFLICT DO NOTHING",
      [
        sql.string(issuer),
        sql.string(subject),
        sql.string(scope),
        sql.string(user_id),
        sql.string(provider),
      ],
    ),
  )
  use found <- result.try(owner(conn, issuer, subject, scope))
  case found {
    Some(id) if id == user_id -> Ok(Nil)
    _ ->
      Error(service.Coded(
        "provider_linked",
        service.Conflict("provider identity is already linked"),
      ))
  }
}

pub fn rekey(conn: Repo, per_group: Bool) -> service.Result(Nil) {
  use _ <- result.try(case per_group {
    True -> Ok(Nil)
    False -> {
      use rows <- result.try(db.query(
        conn,
        "SELECT issuer FROM howdy_auth_provider_identities GROUP BY issuer, subject HAVING COUNT(*) > 1 LIMIT 1",
        [],
        decode.field(0, decode.string, decode.success),
      ))
      case rows {
        [] -> Ok(Nil)
        _ ->
          Error(service.Conflict(
            "a provider identity has accounts in more than one group",
          ))
      }
    }
  })
  db.execute(
    conn,
    "UPDATE howdy_auth_provider_identities SET scope = "
      <> case per_group {
      True ->
        "(SELECT u.group_id FROM howdy_auth_users u WHERE u.id = howdy_auth_provider_identities.user_id)"
      False -> "''"
    },
    [],
  )
}
