//// Persistent SSO connections. The protocol is sealed at rest, so every read
//// takes the application's SSO configuration.

import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import gloo/repo.{type Repo}
import gloo/sql
import howdy/auth/connection.{type Config, type Connection, type Protocol}
import howdy/auth/internal/database as db
import howdy/auth/internal/token
import howdy/service

const columns = "c.id, c.group_id, c.kind, c.name, c.config, c.enabled, c.enforced, c.trusts_mfa, c.created_at, c.updated_at"

type Row {
  Row(
    id: String,
    group_id: String,
    kind: String,
    name: String,
    sealed: String,
    enabled: Bool,
    enforced: Bool,
    trusts_mfa: Bool,
    created_at: Int,
    updated_at: Int,
  )
}

fn row() -> decode.Decoder(Row) {
  use id <- decode.field(0, decode.string)
  use group_id <- decode.field(1, decode.string)
  use kind <- decode.field(2, decode.string)
  use name <- decode.field(3, decode.string)
  use sealed <- decode.field(4, decode.string)
  use enabled <- decode.field(5, decode.int)
  use enforced <- decode.field(6, decode.int)
  use trusts_mfa <- decode.field(7, decode.int)
  use created_at <- decode.field(8, decode.int)
  use updated_at <- decode.field(9, decode.int)
  decode.success(Row(
    id,
    group_id,
    kind,
    name,
    sealed,
    enabled == 1,
    enforced == 1,
    trusts_mfa == 1,
    created_at,
    updated_at,
  ))
}

fn open(conn: Repo, config: Config, row: Row) -> service.Result(Connection) {
  use protocol <- result.try(connection.open(
    config,
    row.id,
    row.kind,
    row.sealed,
  ))
  use domains <- result.try(domains(conn, row.id))
  Ok(connection.Connection(
    row.id,
    row.group_id,
    row.name,
    protocol,
    domains,
    row.enabled,
    row.enforced,
    row.trusts_mfa,
    timestamp.from_unix_seconds(row.created_at),
    timestamp.from_unix_seconds(row.updated_at),
  ))
}

pub fn insert(
  conn: Repo,
  id: String,
  group_id: String,
  name: String,
  protocol: Protocol,
  sealed: String,
) -> service.Result(Nil) {
  let now = token.now()
  db.execute(
    conn,
    "INSERT INTO howdy_auth_sso_connections(id, group_id, kind, name, config, enabled, created_at, updated_at) VALUES ($1,$2,$3,$4,$5,1,$6,$7)",
    [
      sql.string(id),
      sql.string(group_id),
      sql.string(connection.kind(protocol)),
      sql.string(name),
      sql.string(sealed),
      sql.int(now),
      sql.int(now),
    ],
  )
}

/// The connection, row-locked so concurrent changes apply in turn.
pub fn find(
  conn: Repo,
  config: Config,
  id: String,
) -> service.Result(Option(Connection)) {
  use rows <- result.try(db.query(
    conn,
    "SELECT "
      <> columns
      <> " FROM howdy_auth_sso_connections c WHERE c.id = $1"
      <> db.for_update(conn, "c"),
    [sql.string(id)],
    row(),
  ))
  case rows {
    [found] -> open(conn, config, found) |> result.map(Some)
    _ -> Ok(None)
  }
}

/// Every connection, or those of one group, by name.
pub fn all(
  conn: Repo,
  config: Config,
  group_id: Option(String),
) -> service.Result(List(Connection)) {
  use rows <- result.try(case group_id {
    Some(group_id) ->
      db.query(
        conn,
        "SELECT "
          <> columns
          <> " FROM howdy_auth_sso_connections c WHERE c.group_id = $1 ORDER BY c.name, c.id",
        [sql.string(group_id)],
        row(),
      )
    None ->
      db.query(
        conn,
        "SELECT "
          <> columns
          <> " FROM howdy_auth_sso_connections c ORDER BY c.name, c.id",
        [],
        row(),
      )
  })
  list.try_map(rows, open(conn, config, _))
}

/// Sorted here, not by the database: PostgreSQL's collation and SQLite's
/// bytewise order disagree about punctuation.
pub fn domains(conn: Repo, id: String) -> service.Result(List(String)) {
  db.query(
    conn,
    "SELECT domain FROM howdy_auth_sso_domains WHERE connection_id = $1",
    [sql.string(id)],
    decode.field(0, decode.string, decode.success),
  )
  |> result.map(list.sort(_, string.compare))
}

/// The enabled connection an email domain routes to.
pub fn id_for_domain(
  conn: Repo,
  domain: String,
) -> service.Result(Option(String)) {
  use rows <- result.try(db.query(
    conn,
    "SELECT c.id FROM howdy_auth_sso_domains d JOIN howdy_auth_sso_connections c ON c.id = d.connection_id WHERE d.domain = $1 AND c.enabled = 1",
    [sql.string(domain)],
    decode.field(0, decode.string, decode.success),
  ))
  case rows {
    [id] -> Ok(Some(id))
    _ -> Ok(None)
  }
}

/// Replace a connection's domains. Conflict when another connection holds one.
pub fn set_domains(
  conn: Repo,
  id: String,
  domains: List(String),
) -> service.Result(Nil) {
  use _ <- result.try(
    db.execute(
      conn,
      "DELETE FROM howdy_auth_sso_domains WHERE connection_id = $1",
      [sql.string(id)],
    ),
  )
  list.try_each(domains, fn(domain) {
    // ON CONFLICT + readback: a concurrent claim fails closed instead of
    // surfacing as an opaque driver error.
    use _ <- result.try(
      db.execute(
        conn,
        "INSERT INTO howdy_auth_sso_domains(domain, connection_id) VALUES ($1,$2) ON CONFLICT DO NOTHING",
        [sql.string(domain), sql.string(id)],
      ),
    )
    use owners <- result.try(db.query(
      conn,
      "SELECT connection_id FROM howdy_auth_sso_domains WHERE domain = $1",
      [sql.string(domain)],
      decode.field(0, decode.string, decode.success),
    ))
    case owners {
      [owner] if owner == id -> Ok(Nil)
      _ ->
        Error(service.Conflict(
          "an SSO domain already belongs to another connection",
        ))
    }
  })
}

pub fn rename(conn: Repo, id: String, name: String) -> service.Result(Nil) {
  db.execute(
    conn,
    "UPDATE howdy_auth_sso_connections SET name = $1, updated_at = $2 WHERE id = $3",
    [sql.string(name), sql.int(token.now()), sql.string(id)],
  )
}

pub fn set_protocol(
  conn: Repo,
  id: String,
  protocol: Protocol,
  sealed: String,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "UPDATE howdy_auth_sso_connections SET kind = $1, config = $2, updated_at = $3 WHERE id = $4",
    [
      sql.string(connection.kind(protocol)),
      sql.string(sealed),
      sql.int(token.now()),
      sql.string(id),
    ],
  )
}

pub fn set_enabled(
  conn: Repo,
  id: String,
  enabled: Bool,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "UPDATE howdy_auth_sso_connections SET enabled = $1, updated_at = $2 WHERE id = $3",
    [
      sql.int(case enabled {
        True -> 1
        False -> 0
      }),
      sql.int(token.now()),
      sql.string(id),
    ],
  )
}

pub fn touch(conn: Repo, id: String) -> service.Result(Nil) {
  db.execute(
    conn,
    "UPDATE howdy_auth_sso_connections SET updated_at = $1 WHERE id = $2",
    [sql.int(token.now()), sql.string(id)],
  )
}

/// Identities are keyed by the connection, so they go with it: a connection
/// recreated under the same id must not inherit the old one's users.
pub fn delete(conn: Repo, id: String) -> service.Result(Nil) {
  use _ <- result.try(forget_identities(conn, id))
  db.execute(conn, "DELETE FROM howdy_auth_sso_connections WHERE id = $1", [
    sql.string(id),
  ])
}

pub fn forget_identities(conn: Repo, id: String) -> service.Result(Nil) {
  db.execute(
    conn,
    "DELETE FROM howdy_auth_provider_identities WHERE issuer = $1",
    [sql.string(connection.identity_issuer(id))],
  )
}

pub fn set_enforced(
  conn: Repo,
  id: String,
  enforced: Bool,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "UPDATE howdy_auth_sso_connections SET enforced = $1, updated_at = $2 WHERE id = $3",
    [
      sql.int(case enforced {
        True -> 1
        False -> 0
      }),
      sql.int(token.now()),
      sql.string(id),
    ],
  )
}

/// The enabled, enforced connection that covers a normalized address: one
/// whose domains hold the address's and whose group is the account's. With no
/// group given, the group is whichever holds an account for the address.
/// Reads no sealed configuration, so it works without the SSO key.
pub fn enforcing(
  conn: Repo,
  email: String,
  group_id: Option(String),
) -> service.Result(Option(String)) {
  let domain = case string.split(email, "@") {
    [_, domain] -> domain
    _ -> ""
  }
  use rows <- result.try(db.query(
    conn,
    "SELECT c.id FROM howdy_auth_sso_domains d JOIN howdy_auth_sso_connections c ON c.id = d.connection_id WHERE d.domain = $1 AND c.enabled = 1 AND c.enforced = 1 AND (c.group_id = $2 OR ($3 = '' AND EXISTS (SELECT 1 FROM howdy_auth_users u WHERE u.email = $4 AND u.group_id = c.group_id)))",
    // Each placeholder once: SQLite binds them by position.
    [
      sql.string(domain),
      sql.string(option.unwrap(group_id, "")),
      sql.string(option.unwrap(group_id, "")),
      sql.string(email),
    ],
    decode.field(0, decode.string, decode.success),
  ))
  case rows {
    [id] -> Ok(Some(id))
    _ -> Ok(None)
  }
}

/// The members a connection covers: those of its group with an address in
/// one of its domains. Addresses are stored normalized, so the suffix is exact.
pub fn covered(conn: Repo, id: String) -> service.Result(List(String)) {
  db.query(
    conn,
    "SELECT u.id FROM howdy_auth_users u JOIN howdy_auth_sso_connections c ON c.group_id = u.group_id JOIN howdy_auth_sso_domains d ON d.connection_id = c.id WHERE c.id = $1 AND substr(u.email, length(u.email) - length(d.domain)) = '@' || d.domain",
    [sql.string(id)],
    decode.field(0, decode.string, decode.success),
  )
}

pub fn set_trusts_mfa(
  conn: Repo,
  id: String,
  trusted: Bool,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "UPDATE howdy_auth_sso_connections SET trusts_mfa = $1, updated_at = $2 WHERE id = $3",
    [
      sql.int(case trusted {
        True -> 1
        False -> 0
      }),
      sql.int(token.now()),
      sql.string(id),
    ],
  )
}

/// Sealed protocols after a connection id, for resealing: `(id, id, config)`.
pub fn sealed(
  conn: Repo,
  after: String,
) -> service.Result(List(#(String, String, String))) {
  db.query(
    conn,
    "SELECT id, config FROM howdy_auth_sso_connections WHERE id > $1 ORDER BY id LIMIT 100",
    [sql.string(after)],
    {
      use id <- decode.field(0, decode.string)
      use sealed <- decode.field(1, decode.string)
      decode.success(#(id, id, sealed))
    },
  )
}

pub fn reseal(
  conn: Repo,
  id: String,
  old: String,
  new: String,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "UPDATE howdy_auth_sso_connections SET config = $1 WHERE id = $2 AND config = $3",
    [sql.string(new), sql.string(id), sql.string(old)],
  )
}
