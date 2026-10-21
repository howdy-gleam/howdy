//// Every SQL statement the authentication runtime issues, as named
//// operations. All of them run on the connection they are given, so callers
//// decide transaction boundaries. Statements work on PostgreSQL and SQLite.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import gleam/time/timestamp
import gloo/repo.{type Repo}
import gloo/sql
import gloo/value.{type GlooValue}
import howdy/auth/field
import howdy/auth/group.{type Group}
import howdy/auth/internal/account_store
import howdy/auth/internal/database as db
import howdy/auth/internal/provider_store
import howdy/auth/internal/security_store
import howdy/auth/internal/token
import howdy/auth/policy.{type Policy}
import howdy/auth/user.{type User}
import howdy/database.{Postgres}
import howdy/service

/// The columns `user.row` decodes, from the users table under alias `u`.
fn user_columns(conn: Repo) -> String {
  "u.id, u.email, u.group_id, "
  <> db.read_time(conn, "u.created_at")
  <> ", "
  <> db.read_time(conn, "u.updated_at")
  <> ", u.locale"
}

/// The columns `group.row` decodes, from the groups table under alias `g`.
fn group_columns(conn: Repo) -> String {
  "g.id, g.name, "
  <> db.read_time(conn, "g.created_at")
  <> ", "
  <> db.read_time(conn, "g.updated_at")
}

// --- Per-installation keys --------------------------------------------------

/// Read the installation's throttle key, creating it on first use. Digesting
/// an email address with a shared, unkeyed hash is only obfuscation: anyone
/// can hash a guess and look for it. Keying the digest with a secret that
/// never leaves the database makes throttle rows opaque to anyone who sees
/// them without it. Runs once at startup, and is safe to race.
pub fn throttle_key(conn: Repo) -> service.Result(String) {
  use existing <- result.try(read_key(conn, "throttle"))
  case existing {
    [secret] -> Ok(secret)
    _ -> {
      use _ <- result.try(
        db.execute(
          conn,
          "INSERT INTO howdy_auth_keys(name, secret) VALUES ($1, $2) ON CONFLICT(name) DO NOTHING",
          [sql.string("throttle"), sql.string(token.new())],
        ),
      )
      use created <- result.try(read_key(conn, "throttle"))
      case created {
        [secret] -> Ok(secret)
        _ -> Error(service.Internal("auth database operation failed"))
      }
    }
  }
}

fn read_key(conn: Repo, name: String) -> service.Result(List(String)) {
  db.query(
    conn,
    "SELECT secret FROM howdy_auth_keys WHERE name = $1",
    [sql.string(name)],
    decode.field(0, decode.string, decode.success),
  )
}

// --- Email request back-off -------------------------------------------------

/// Claim the right to email `key` now, or report how long remains. Must run
/// in a transaction: the row is created, locked, then advanced, so concurrent
/// requests for one address are decided one at a time on both databases.
pub fn reserve_email(
  conn: Repo,
  key: String,
  now: Int,
  policy: Policy,
) -> service.Result(Nil) {
  use _ <- result.try(
    db.execute(conn, "DELETE FROM howdy_auth_throttles WHERE next_at <= $1", [
      sql.int(now - policy.email_quiet_seconds),
    ]),
  )
  use _ <- result.try(
    db.execute(
      conn,
      "INSERT INTO howdy_auth_throttles(key, next_at, strikes) VALUES ($1, 0, 0) ON CONFLICT(key) DO NOTHING",
      [sql.string(key)],
    ),
  )
  let row = {
    use next_at <- decode.field(0, decode.int)
    use strikes <- decode.field(1, decode.int)
    decode.success(#(next_at, strikes))
  }
  use rows <- result.try(db.query(
    conn,
    "SELECT t.next_at, t.strikes FROM howdy_auth_throttles t WHERE t.key = $1"
      <> db.for_update(conn, "t"),
    [sql.string(key)],
    row,
  ))
  case rows {
    [#(next_at, _)] if next_at > now ->
      Error(service.TooManyRequests(next_at - now))
    [#(_, strikes)] -> {
      // Cap the shift, not just the product, so it cannot overflow.
      let doubled =
        int.bitwise_shift_left(
          policy.email_cooldown_seconds,
          int.min(strikes, 30),
        )
      let wait = int.min(doubled, policy.email_cooldown_max_seconds)
      db.execute(
        conn,
        "UPDATE howdy_auth_throttles SET next_at = $1, strikes = $2 WHERE key = $3",
        [sql.int(now + wait), sql.int(strikes + 1), sql.string(key)],
      )
    }
    _ -> Error(service.Internal("auth database operation failed"))
  }
}

pub fn clear_email_throttle(conn: Repo, key: String) -> service.Result(Nil) {
  db.execute(conn, "DELETE FROM howdy_auth_throttles WHERE key = $1", [
    sql.string(key),
  ])
}

// --- Challenges -------------------------------------------------------------

pub type Challenge {
  Challenge(
    email: String,
    intent: String,
    password_hash: Option(String),
    normalized: Bool,
    /// The group the request named, if it named one.
    group_id: Option(String),
    /// A verified passkey awaiting the account this token will create.
    passkey: Option(String),
  )
}

/// Store a new challenge, first discarding expired ones and this address's
/// oldest beyond `keep - 1`. Tokens still in transit stay valid.
pub fn insert_challenge(
  conn: Repo,
  digest digest: String,
  email email: String,
  intent intent: String,
  group_id group_id: Option(String),
  now now: Int,
  expires_at expires_at: Int,
  password_hash password_hash: Option(String),
  passkey passkey: Option(String),
  code_digest code_digest: Option(String),
  keep keep: Int,
) -> service.Result(Nil) {
  use _ <- result.try(
    db.execute(
      conn,
      "DELETE FROM howdy_auth_challenges WHERE expires_at <= $1",
      [
        sql.int(now),
      ],
    ),
  )
  use _ <- result.try(
    db.execute(
      conn,
      "DELETE FROM howdy_auth_challenges WHERE email = $1 AND COALESCE(group_id, '') = $2 AND digest NOT IN (SELECT digest FROM howdy_auth_challenges WHERE email = $3 AND COALESCE(group_id, '') = $4 ORDER BY created_at DESC, digest LIMIT $5)",
      [
        sql.string(email),
        sql.string(option.unwrap(group_id, "")),
        sql.string(email),
        sql.string(option.unwrap(group_id, "")),
        sql.int(keep - 1),
      ],
    ),
  )
  db.execute(
    conn,
    "INSERT INTO howdy_auth_challenges(digest, email, intent, expires_at, password_hash, created_at, password_normalized, group_id, passkey, code_digest) VALUES ($1, $2, $3, $4, $5, $6, 1, $7, $8, $9)",
    [
      sql.string(digest),
      sql.string(email),
      sql.string(intent),
      sql.int(expires_at),
      sql.nullable(sql.string, password_hash),
      sql.int(now),
      sql.nullable(sql.string, group_id),
      sql.nullable(sql.string, passkey),
      sql.nullable(sql.string, code_digest),
    ],
  )
}

/// Store a new challenge unless this address already holds a usable token for
/// the same intent, and report which happened. One statement decides, after
/// taking the address's own lock row, so two requests arriving together for
/// one address cannot both conclude that an email is needed.
pub fn claim_challenge(
  conn: Repo,
  address_key address_key: String,
  digest digest: String,
  email email: String,
  intent intent: String,
  group_id group_id: Option(String),
  now now: Int,
  expires_at expires_at: Int,
  live_after live_after: Int,
  password_hash password_hash: Option(String),
  passkey passkey: Option(String),
  code_digest code_digest: Option(String),
  keep keep: Int,
) -> service.Result(Bool) {
  use _ <- result.try(lock_address(conn, address_key))
  use live <- result.try(
    db.query(
      conn,
      "SELECT 1 FROM howdy_auth_challenges WHERE email = $1 AND intent = $2 AND expires_at > $3 AND password_hash IS NULL AND passkey IS NULL AND COALESCE(group_id, '') = $4 LIMIT 1",
      [
        sql.string(email),
        sql.string(intent),
        sql.int(live_after),
        sql.string(option.unwrap(group_id, "")),
      ],
      decode.field(0, decode.int, decode.success),
    )
    |> result.map(fn(rows) { rows != [] }),
  )
  // A token-only request is answered by whatever is already in that inbox.
  case live && password_hash == option.None && passkey == option.None {
    True -> Ok(False)
    False -> {
      use _ <- result.try(insert_challenge(
        conn,
        digest:,
        email:,
        intent:,
        group_id:,
        now:,
        expires_at:,
        password_hash:,
        passkey:,
        code_digest:,
        keep:,
      ))
      Ok(True)
    }
  }
}

/// Serialize requests for one address. The row is only ever a lock and the
/// password cooldown; it carries nothing that has to survive.
fn lock_address(conn: Repo, address_key: String) -> service.Result(Nil) {
  use _ <- result.try(
    db.execute(
      conn,
      "INSERT INTO howdy_auth_throttles(key, next_at, strikes) VALUES ($1, 0, 0) ON CONFLICT(key) DO NOTHING",
      [sql.string(address_key)],
    ),
  )
  db.query(
    conn,
    "SELECT t.next_at FROM howdy_auth_throttles t WHERE t.key = $1"
      <> db.for_update(conn, "t"),
    [sql.string(address_key)],
    decode.field(0, decode.int, decode.success),
  )
  |> result.map(fn(_) { Nil })
}

pub fn delete_challenge(conn: Repo, digest: String) -> service.Result(Nil) {
  db.execute(conn, "DELETE FROM howdy_auth_challenges WHERE digest = $1", [
    sql.string(digest),
  ])
}

/// Atomically remove and return an unexpired challenge. At most one caller
/// ever receives a given challenge.
pub fn consume_challenge(
  conn: Repo,
  digest: String,
  now: Int,
) -> service.Result(List(Challenge)) {
  let row = {
    use email <- decode.field(0, decode.string)
    use intent <- decode.field(1, decode.string)
    use password_hash <- decode.field(2, decode.optional(decode.string))
    use normalized <- decode.field(3, decode.int)
    use group_id <- decode.field(4, decode.optional(decode.string))
    use passkey <- decode.field(5, decode.optional(decode.string))
    decode.success(Challenge(
      email,
      intent,
      password_hash,
      normalized == 1,
      group_id,
      passkey,
    ))
  }
  db.query(
    conn,
    "DELETE FROM howdy_auth_challenges WHERE digest = $1 AND expires_at > $2 RETURNING email, intent, password_hash, password_normalized, group_id, passkey",
    [sql.string(digest), sql.int(now)],
    row,
  )
}

/// Wrong guesses an emailed code survives. The token beside it still works.
pub const code_attempts = 3

/// Spend the live challenge for this address whose code has this digest, or
/// count a wrong guess against every live code for the address, retiring
/// those that reach `code_attempts`. Returns no challenge on a wrong guess,
/// and the caller must commit either way.
pub fn take_code(
  conn: Repo,
  email: String,
  code_digest: String,
  now: Int,
) -> service.Result(List(Challenge)) {
  use rows <- result.try(
    db.query(
      conn,
      "SELECT c.digest, c.code_digest FROM howdy_auth_challenges c WHERE c.email = $1 AND c.expires_at > $2 AND c.code_digest IS NOT NULL"
        <> db.for_update(conn, "c"),
      [sql.string(email), sql.int(now)],
      {
        use digest <- decode.field(0, decode.string)
        use stored <- decode.field(1, decode.string)
        decode.success(#(digest, stored))
      },
    ),
  )
  case
    list.find(rows, fn(row) { token.constant_time_equal(row.1, code_digest) })
  {
    Ok(#(digest, _)) -> consume_challenge(conn, digest, now)
    Error(_) -> {
      use _ <- result.try(
        db.execute(
          conn,
          "UPDATE howdy_auth_challenges SET code_attempts = code_attempts + 1, code_digest = CASE WHEN code_attempts + 1 >= $1 THEN NULL ELSE code_digest END WHERE email = $2 AND expires_at > $3 AND code_digest IS NOT NULL",
          [sql.int(code_attempts), sql.string(email), sql.int(now)],
        ),
      )
      Ok([])
    }
  }
}

pub fn delete_challenges_for_user(
  conn: Repo,
  user_id: String,
) -> service.Result(Nil) {
  db.execute(
    conn,
    // A challenge that named no group could sign this user in too.
    "DELETE FROM howdy_auth_challenges WHERE EXISTS (SELECT 1 FROM howdy_auth_users u WHERE u.id = $1 AND u.email = howdy_auth_challenges.email AND (howdy_auth_challenges.group_id IS NULL OR howdy_auth_challenges.group_id = u.group_id))",
    [sql.string(user_id)],
  )
}

// --- Users and credentials --------------------------------------------------

/// `group` narrows a lookup by address to one group; `None` is any group.
/// Bound twice because Gloo's SQLite placeholders are positional.
fn in_group(group: Option(String)) -> List(GlooValue) {
  let id = option.unwrap(group, "")
  [sql.string(id), sql.string(id)]
}

/// The account that owns an address, if any. Used both to decide what a token
/// email should say and to attribute the request in the audit trail. Under
/// `AccountPerGroup` callers always pass a group, so at most one row matches.
pub fn user_id_for_email(
  conn: Repo,
  email: String,
  group: Option(String),
) -> service.Result(Option(String)) {
  db.query(
    conn,
    "SELECT id FROM howdy_auth_users WHERE email = $1 AND ($2 = '' OR group_id = $3)",
    [sql.string(email), ..in_group(group)],
    decode.field(0, decode.string, decode.success),
  )
  |> result.map(fn(rows) {
    case rows {
      [id] -> option.Some(id)
      _ -> option.None
    }
  })
}

/// Whether registering would collide. The unique login key decides: it is
/// the address, or the address within its group, as the mode requires.
pub fn login_key_taken(conn: Repo, key: String) -> service.Result(Bool) {
  db.query(
    conn,
    "SELECT id FROM howdy_auth_users WHERE login_key = $1",
    [sql.string(key)],
    decode.field(0, decode.string, decode.success),
  )
  |> result.map(fn(rows) { rows != [] })
}

pub fn insert_user(
  conn: Repo,
  id id: String,
  email email: String,
  group_id group_id: String,
  login_key login_key: String,
  locale locale: Option(String),
) -> service.Result(User) {
  let now = token.now()
  use _ <- result.try(
    db.execute(
      conn,
      "INSERT INTO howdy_auth_users(id, email, group_id, login_key, created_at, updated_at, locale) VALUES ($1, $2, $3, $4, "
        <> db.write_time(conn, "$5")
        <> ", "
        <> db.write_time(conn, "$6")
        <> ", $7)",
      [
        sql.string(id),
        sql.string(email),
        sql.string(group_id),
        sql.string(login_key),
        sql.int(now),
        sql.int(now),
        sql.nullable(sql.string, locale),
      ],
    ),
  )
  use _ <- result.try(
    db.execute(
      conn,
      "INSERT INTO howdy_auth_identities(issuer, subject, user_id) VALUES ('email', $1, $2)",
      [sql.string(login_key), sql.string(id)],
    ),
  )
  let at = timestamp.from_unix_seconds(now)
  Ok(user.User(id, email, group_id, at, at, locale))
}

/// The active user owning a verified email address, row-locked.
pub fn active_user_by_email(
  conn: Repo,
  email: String,
  group: Option(String),
) -> service.Result(List(User)) {
  db.query(
    conn,
    // howdy_auth_users.email is the one address this package authenticates on.
    // The identity row records that the address was verified by email; it is
    // never a second place to look one up, so the two cannot disagree.
    "SELECT "
      <> user_columns(conn)
      <> " FROM howdy_auth_users u JOIN howdy_auth_identities i ON i.user_id = u.id AND i.issuer = 'email' WHERE u.email = $1 AND ($2 = '' OR u.group_id = $3) AND u.suspended = 0"
      <> db.for_update(conn, "u"),
    [sql.string(email), ..in_group(group)],
    user.row(),
  )
}

pub fn set_suspended(
  conn: Repo,
  user_id: String,
  suspended: Bool,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "UPDATE howdy_auth_users SET suspended = $1, updated_at = "
      <> db.write_time(conn, "$2")
      <> " WHERE id = $3",
    [
      sql.int(case suspended {
        True -> 1
        False -> 0
      }),
      sql.int(token.now()),
      sql.string(user_id),
    ],
  )
}

pub fn insert_password(
  conn: Repo,
  user_id: String,
  encoded: String,
  normalized: Bool,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "INSERT INTO howdy_auth_passwords(user_id, encoded_hash, normalized) VALUES ($1, $2, $3)",
    [
      sql.string(user_id),
      sql.string(encoded),
      sql.int(case normalized {
        True -> 1
        False -> 0
      }),
    ],
  )
}

pub fn replace_password(
  conn: Repo,
  user_id: String,
  encoded: String,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "INSERT INTO howdy_auth_passwords(user_id, encoded_hash, normalized) VALUES ($1, $2, 1) ON CONFLICT(user_id) DO UPDATE SET encoded_hash = excluded.encoded_hash, normalized = 1",
    [sql.string(user_id), sql.string(encoded)],
  )
}

/// Active password users for an address, with their encoded hash.
pub fn password_candidates(
  conn: Repo,
  email: String,
  group: Option(String),
) -> service.Result(List(#(User, String, Bool))) {
  let row = {
    use found <- decode.then(user.row())
    use hash <- decode.field(6, decode.string)
    use normalized <- decode.field(7, decode.int)
    decode.success(#(found, hash, normalized == 1))
  }
  db.query(
    conn,
    "SELECT "
      <> user_columns(conn)
      <> ", p.encoded_hash, p.normalized FROM howdy_auth_users u JOIN howdy_auth_passwords p ON p.user_id = u.id WHERE u.email = $1 AND ($2 = '' OR u.group_id = $3) AND u.suspended = 0",
    [sql.string(email), ..in_group(group)],
    row,
  )
}

/// Row-lock the active user with the same hash. Unknown -> NFC metadata is a
/// compatible upgrade: it does not change which password verified. NFC ->
/// unknown is refused; every real hash replacement must still match exactly.
pub fn active_user_with_password(
  conn: Repo,
  user_id: String,
  encoded: String,
  normalized: Bool,
) -> service.Result(List(User)) {
  db.query(
    conn,
    "SELECT "
      <> user_columns(conn)
      <> " FROM howdy_auth_users u JOIN howdy_auth_passwords p ON p.user_id = u.id WHERE u.id = $1 AND p.encoded_hash = $2 AND p.normalized >= $3 AND u.suspended = 0"
      <> db.for_update(conn, "u"),
    [
      sql.string(user_id),
      sql.string(encoded),
      sql.int(case normalized {
        True -> 1
        False -> 0
      }),
    ],
    user.row(),
  )
}

/// Count a password login against `key` and return the attempts so far in
/// the current window, saturating at `limit + 1`.
pub fn count_password_attempt(
  conn: Repo,
  key: String,
  now: Int,
  policy: Policy,
) -> service.Result(List(Int)) {
  use _ <- result.try(
    db.execute(
      conn,
      "DELETE FROM howdy_auth_password_attempts WHERE window_start <= $1",
      [sql.int(now - policy.password_window_seconds)],
    ),
  )
  db.query(
    conn,
    "INSERT INTO howdy_auth_password_attempts(key, window_start, attempts) VALUES ($1, $2, 1) ON CONFLICT(key) DO UPDATE SET attempts = CASE WHEN howdy_auth_password_attempts.attempts < $3 THEN howdy_auth_password_attempts.attempts + 1 ELSE $4 END RETURNING attempts",
    [
      sql.string(key),
      sql.int(now),
      sql.int(policy.password_account_attempts + 1),
      sql.int(policy.password_account_attempts + 1),
    ],
    decode.field(0, decode.int, decode.success),
  )
}

pub fn clear_password_attempts(conn: Repo, key: String) -> service.Result(Nil) {
  db.execute(conn, "DELETE FROM howdy_auth_password_attempts WHERE key = $1", [
    sql.string(key),
  ])
}

// --- Sessions ---------------------------------------------------------------

pub type SessionRow {
  SessionRow(
    digest: String,
    method: String,
    created_at: Int,
    last_seen_at: Int,
    expires_at: Int,
    client: String,
  )
}

/// Expired sessions are swept a bounded number at a time. This runs inside the
/// transaction that locks the account, so it must not grow with however long
/// the installation has been idle; `auth.prune_expired` clears any backlog.
const sweep_limit = 100

pub fn insert_session(
  conn: Repo,
  digest digest: String,
  user_id user_id: String,
  method method: String,
  now now: Int,
  expires_at expires_at: Int,
  client client: String,
) -> service.Result(Nil) {
  use _ <- result.try(
    db.execute(
      conn,
      "DELETE FROM howdy_auth_sessions WHERE digest IN (SELECT digest FROM howdy_auth_sessions WHERE expires_at <= $1 LIMIT $2)",
      [sql.int(now), sql.int(sweep_limit)],
    ),
  )
  db.execute(
    conn,
    "INSERT INTO howdy_auth_sessions(digest, user_id, expires_at, created_at, last_seen_at, method, client) VALUES ($1, $2, $3, $4, $5, $6, $7)",
    [
      sql.string(digest),
      sql.string(user_id),
      sql.int(expires_at),
      sql.int(now),
      sql.int(now),
      sql.string(method),
      sql.string(client),
    ],
  )
}

/// The active user behind a live session and when it was last used.
/// `seen_after` is the idle cutoff; pass -1 when there is no idle timeout.
pub fn session_user(
  conn: Repo,
  digest: String,
  now: Int,
  seen_after: Int,
) -> service.Result(List(#(User, Int, Int, Int))) {
  let row = {
    use found <- decode.then(user.row())
    use last_seen_at <- decode.field(6, decode.int)
    use created_at <- decode.field(7, decode.int)
    use expires_at <- decode.field(8, decode.int)
    decode.success(#(found, last_seen_at, created_at, expires_at))
  }
  db.query(
    conn,
    "SELECT "
      <> user_columns(conn)
      <> ", s.last_seen_at, s.created_at, s.expires_at FROM howdy_auth_sessions s JOIN howdy_auth_users u ON u.id = s.user_id WHERE s.digest = $1 AND s.expires_at > $2 AND s.last_seen_at > $3 AND u.suspended = 0",
    [sql.string(digest), sql.int(now), sql.int(seen_after)],
    row,
  )
}

pub fn touch_session(
  conn: Repo,
  digest: String,
  now: Int,
  expires_at: Int,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "UPDATE howdy_auth_sessions SET last_seen_at = $1, expires_at = $2 WHERE digest = $3",
    [sql.int(now), sql.int(expires_at), sql.string(digest)],
  )
}

/// Whether this live session was created by an email-token exchange after
/// `created_after`, row-locking its active user.
pub fn fresh_email_session(
  conn: Repo,
  digest: String,
  user_id: String,
  now: Int,
  created_after: Int,
) -> service.Result(Bool) {
  db.query(
    conn,
    "SELECT "
      <> user_columns(conn)
      <> " FROM howdy_auth_sessions s JOIN howdy_auth_users u ON u.id = s.user_id WHERE s.digest = $1 AND s.user_id = $2 AND s.method IN ('email', 'mfa:email') AND s.expires_at > $3 AND s.created_at > $4 AND u.suspended = 0"
      <> db.for_update(conn, "u"),
    [
      sql.string(digest),
      sql.string(user_id),
      sql.int(now),
      sql.int(created_after),
    ],
    user.row(),
  )
  |> result.map(fn(rows) { rows != [] })
}

const session_columns = "digest, method, created_at, last_seen_at, expires_at, client"

fn session_row() -> decode.Decoder(SessionRow) {
  use digest <- decode.field(0, decode.string)
  use method <- decode.field(1, decode.string)
  use created_at <- decode.field(2, decode.int)
  use last_seen_at <- decode.field(3, decode.int)
  use expires_at <- decode.field(4, decode.int)
  use client <- decode.field(5, decode.string)
  decode.success(SessionRow(
    digest,
    method,
    created_at,
    last_seen_at,
    expires_at,
    client,
  ))
}

pub fn sessions_for_user(
  conn: Repo,
  user_id: String,
  now: Int,
) -> service.Result(List(SessionRow)) {
  db.query(
    conn,
    "SELECT "
      <> session_columns
      <> " FROM howdy_auth_sessions WHERE user_id = $1 AND expires_at > $2 ORDER BY created_at DESC, digest",
    [sql.string(user_id), sql.int(now)],
    session_row(),
  )
}

/// One live session of a user, by digest: the caller's own, checked without
/// loading every session they hold.
pub fn session_for_user(
  conn: Repo,
  user_id: String,
  digest: String,
  now: Int,
) -> service.Result(List(SessionRow)) {
  db.query(
    conn,
    "SELECT "
      <> session_columns
      <> " FROM howdy_auth_sessions WHERE user_id = $1 AND digest = $2 AND expires_at > $3",
    [sql.string(user_id), sql.string(digest), sql.int(now)],
    session_row(),
  )
}

pub fn delete_session(
  conn: Repo,
  digest: String,
  user_id: String,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "DELETE FROM howdy_auth_sessions WHERE digest = $1 AND user_id = $2",
    [sql.string(digest), sql.string(user_id)],
  )
}

pub fn delete_sessions(conn: Repo, user_id: String) -> service.Result(Nil) {
  db.execute(conn, "DELETE FROM howdy_auth_sessions WHERE user_id = $1", [
    sql.string(user_id),
  ])
}

pub fn delete_other_sessions(
  conn: Repo,
  user_id: String,
  keep_digest: String,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "DELETE FROM howdy_auth_sessions WHERE user_id = $1 AND digest <> $2",
    [sql.string(user_id), sql.string(keep_digest)],
  )
}

// --- Audit events and housekeeping ------------------------------------------

pub fn insert_event(
  conn: Repo,
  user_id user_id: String,
  action action: String,
  actor_id actor_id: String,
  detail detail: String,
  client client: String,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "INSERT INTO howdy_auth_events(id, user_id, action, occurred_at, actor_id, detail, client) VALUES ($1, $2, $3, $4, $5, $6, $7)",
    [
      sql.string(token.new()),
      sql.string(user_id),
      sql.string(action),
      sql.int(token.now()),
      sql.string(actor_id),
      sql.string(detail),
      sql.string(client),
    ],
  )
}

pub fn delete_events_before(conn: Repo, before: Int) -> service.Result(Nil) {
  db.execute(conn, "DELETE FROM howdy_auth_events WHERE occurred_at < $1", [
    sql.int(before),
  ])
}

pub fn delete_expired(
  conn: Repo,
  now: Int,
  policy: Policy,
) -> service.Result(Nil) {
  use _ <- result.try(provider_store.prune(conn))
  use _ <- result.try(account_store.prune(conn))
  use _ <- result.try(security_store.prune(conn))
  use _ <- result.try(
    db.execute(conn, "DELETE FROM howdy_auth_sessions WHERE expires_at <= $1", [
      sql.int(now),
    ]),
  )
  use _ <- result.try(
    db.execute(
      conn,
      "DELETE FROM howdy_auth_challenges WHERE expires_at <= $1",
      [
        sql.int(now),
      ],
    ),
  )
  use _ <- result.try(
    db.execute(conn, "DELETE FROM howdy_auth_throttles WHERE next_at <= $1", [
      sql.int(now - policy.email_quiet_seconds),
    ]),
  )
  use _ <- result.try(
    db.execute(
      conn,
      "DELETE FROM howdy_auth_password_clients WHERE expires_at <= $1",
      [sql.int(now)],
    ),
  )
  db.execute(
    conn,
    "DELETE FROM howdy_auth_password_attempts WHERE window_start <= $1",
    [sql.int(now - policy.password_window_seconds)],
  )
}

/// The user if they exist and are not suspended: what an external session
/// store cannot know. Lock only inside a transaction.
pub fn active_user(
  conn: Repo,
  user_id: String,
  locking locking: Bool,
) -> service.Result(List(User)) {
  db.query(
    conn,
    "SELECT "
      <> user_columns(conn)
      <> " FROM howdy_auth_users u WHERE u.id = $1 AND u.suspended = 0"
      <> case locking {
      True -> db.for_update(conn, "u")
      False -> ""
    },
    [sql.string(user_id)],
    user.row(),
  )
}

/// `active_user` together with the account's session version, in one query,
/// for checking an external store's entry against the database.
pub fn active_user_version(
  conn: Repo,
  user_id: String,
  locking locking: Bool,
) -> service.Result(List(#(User, Int))) {
  db.query(
    conn,
    "SELECT "
      <> user_columns(conn)
      <> ", u.session_version FROM howdy_auth_users u WHERE u.id = $1 AND u.suspended = 0"
      <> case locking {
      True -> db.for_update(conn, "u")
      False -> ""
    },
    [sql.string(user_id)],
    {
      use user <- decode.then(user.row())
      use version <- decode.field(6, decode.int)
      decode.success(#(user, version))
    },
  )
}

/// Verify and lock the subject before privileged mutations.
pub fn require_user(conn: Repo, user_id: String) -> service.Result(Nil) {
  use rows <- result.try(db.query(
    conn,
    "SELECT u.id FROM howdy_auth_users u WHERE u.id = $1"
      <> db.for_update(conn, "u"),
    [sql.string(user_id)],
    decode.field(0, decode.string, decode.success),
  ))
  case rows {
    [_] -> Ok(Nil)
    _ -> Error(service.NotFound("user"))
  }
}

/// Reserve a client/address attempt before expensive hashing. Concurrent guesses
/// count as failures until proven successful. Denied requests never extend a ban.
pub fn reserve_password_client(
  conn: Repo,
  key: String,
  email_key: String,
  now: Int,
  policy: Policy,
) -> service.Result(Nil) {
  use _ <- result.try(
    db.execute(
      conn,
      "DELETE FROM howdy_auth_password_clients WHERE expires_at <= $1",
      [sql.int(now)],
    ),
  )
  use _ <- result.try(
    db.execute(
      conn,
      "INSERT INTO howdy_auth_password_clients(key, email_key, failures, next_at, expires_at) VALUES ($1, $2, 0, 0, $3) ON CONFLICT(key) DO NOTHING",
      [
        sql.string(key),
        sql.string(email_key),
        sql.int(now + policy.password_quiet_seconds),
      ],
    ),
  )
  let row = {
    use failures <- decode.field(0, decode.int)
    use next_at <- decode.field(1, decode.int)
    decode.success(#(failures, next_at))
  }
  use rows <- result.try(db.query(
    conn,
    "SELECT c.failures, c.next_at FROM howdy_auth_password_clients c WHERE c.key = $1"
      <> db.for_update(conn, "c"),
    [sql.string(key)],
    row,
  ))
  case rows {
    [#(_, next_at)] if next_at > now ->
      Error(service.TooManyRequests(next_at - now))
    [#(failures, _)] -> {
      let failures = int.min(failures + 1, policy.password_attempts + 30)
      let wait = case failures < policy.password_attempts {
        True -> 0
        False ->
          int.min(
            int.bitwise_shift_left(
              policy.password_window_seconds,
              failures - policy.password_attempts,
            ),
            policy.password_backoff_max_seconds,
          )
      }
      db.execute(
        conn,
        "UPDATE howdy_auth_password_clients SET failures = $1, next_at = $2, expires_at = $3 WHERE key = $4",
        [
          sql.int(failures),
          sql.int(now + wait),
          sql.int(now + policy.password_quiet_seconds),
          sql.string(key),
        ],
      )
    }
    _ -> Error(service.Internal("auth database operation failed"))
  }
}

pub fn clear_password_client(conn: Repo, key: String) -> service.Result(Nil) {
  db.execute(conn, "DELETE FROM howdy_auth_password_clients WHERE key = $1", [
    sql.string(key),
  ])
}

pub fn clear_password_clients(
  conn: Repo,
  email_key: String,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "DELETE FROM howdy_auth_password_clients WHERE email_key = $1",
    [sql.string(email_key)],
  )
}

/// Caller has rechecked the complete credential snapshot under the user lock.
pub fn mark_password_normalized(
  conn: Repo,
  user_id: String,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "UPDATE howdy_auth_passwords SET normalized = 1 WHERE user_id = $1",
    [sql.string(user_id)],
  )
}

// --- Groups ----------------------------------------------------------------

pub fn setting(conn: Repo, name: String) -> service.Result(List(String)) {
  db.query(
    conn,
    "SELECT value FROM howdy_auth_settings WHERE name = $1",
    [sql.string(name)],
    decode.field(0, decode.string, decode.success),
  )
}

pub fn set_setting(
  conn: Repo,
  name: String,
  value: String,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "INSERT INTO howdy_auth_settings(name, value) VALUES ($1, $2) ON CONFLICT(name) DO UPDATE SET value = excluded.value",
    [sql.string(name), sql.string(value)],
  )
}

pub fn insert_group(
  conn: Repo,
  id: String,
  name: String,
) -> service.Result(Group) {
  let now = token.now()
  use _ <- result.try(
    db.execute(
      conn,
      "INSERT INTO howdy_auth_groups(id, name, created_at, updated_at) VALUES ($1, $2, "
        <> db.write_time(conn, "$3")
        <> ", "
        <> db.write_time(conn, "$4")
        <> ")",
      [sql.string(id), sql.string(name), sql.int(now), sql.int(now)],
    ),
  )
  let at = timestamp.from_unix_seconds(now)
  Ok(group.Group(id, name, at, at))
}

/// The group, row-locked so it cannot be deleted while a user is put in it.
pub fn find_group(conn: Repo, id: String) -> service.Result(List(Group)) {
  db.query(
    conn,
    "SELECT "
      <> group_columns(conn)
      <> " FROM howdy_auth_groups g WHERE g.id = $1"
      <> db.for_update(conn, "g"),
    [sql.string(id)],
    group.row(),
  )
}

pub fn groups(conn: Repo) -> service.Result(List(Group)) {
  db.query(
    conn,
    "SELECT "
      <> group_columns(conn)
      <> " FROM howdy_auth_groups g ORDER BY g.name, g.id",
    [],
    group.row(),
  )
}

pub fn rename_group(
  conn: Repo,
  id: String,
  name: String,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "UPDATE howdy_auth_groups SET name = $1, updated_at = "
      <> db.write_time(conn, "$2")
      <> " WHERE id = $3",
    [sql.string(name), sql.int(token.now()), sql.string(id)],
  )
}

pub fn delete_group(conn: Repo, id: String) -> service.Result(Nil) {
  db.execute(conn, "DELETE FROM howdy_auth_groups WHERE id = $1", [
    sql.string(id),
  ])
}

pub fn group_members(conn: Repo, id: String) -> service.Result(List(User)) {
  db.query(
    conn,
    "SELECT "
      <> user_columns(conn)
      <> " FROM howdy_auth_users u WHERE u.group_id = $1 ORDER BY u.email, u.id",
    [sql.string(id)],
    user.row(),
  )
}

/// Every user, or every user in `group`, by email then id.
pub fn users(conn: Repo, group: Option(String)) -> service.Result(List(User)) {
  db.query(
    conn,
    "SELECT "
      <> user_columns(conn)
      <> " FROM howdy_auth_users u WHERE ($1 = '' OR u.group_id = $2) ORDER BY u.email, u.id",
    in_group(group),
    user.row(),
  )
}

/// Whether the user is suspended. Empty when there is no such user.
pub fn suspended(conn: Repo, user_id: String) -> service.Result(List(Bool)) {
  db.query(
    conn,
    "SELECT suspended FROM howdy_auth_users WHERE id = $1",
    [sql.string(user_id)],
    decode.field(0, decode.int, fn(flag) { decode.success(flag == 1) }),
  )
}

/// Users outside `id`, at most one: enough to know whether there are any.
pub fn users_outside_group(conn: Repo, id: String) -> service.Result(Bool) {
  db.query(
    conn,
    "SELECT id FROM howdy_auth_users WHERE group_id <> $1 LIMIT 1",
    [sql.string(id)],
    decode.field(0, decode.string, decode.success),
  )
  |> result.map(fn(rows) { rows != [] })
}

/// The user, row-locked.
pub fn find_user(conn: Repo, user_id: String) -> service.Result(List(User)) {
  db.query(
    conn,
    "SELECT "
      <> user_columns(conn)
      <> " FROM howdy_auth_users u WHERE u.id = $1"
      <> db.for_update(conn, "u"),
    [sql.string(user_id)],
    user.row(),
  )
}

/// Put a user in another group under the login key that group gives them.
/// The identity row carries the same key, so the two cannot disagree.
pub fn move_user(
  conn: Repo,
  user_id: String,
  group_id: String,
  login_key: String,
) -> service.Result(Nil) {
  use _ <- result.try(
    db.execute(
      conn,
      "UPDATE howdy_auth_users SET group_id = $1, login_key = $2, updated_at = "
        <> db.write_time(conn, "$3")
        <> " WHERE id = $4",
      [
        sql.string(group_id),
        sql.string(login_key),
        sql.int(token.now()),
        sql.string(user_id),
      ],
    ),
  )
  use _ <- result.try(
    db.execute(
      conn,
      "UPDATE howdy_auth_identities SET subject = $1 WHERE issuer = 'email' AND user_id = $2",
      [sql.string(login_key), sql.string(user_id)],
    ),
  )
  use _ <- result.try(
    db.execute(
      conn,
      "UPDATE howdy_auth_provider_identities SET scope = $1 WHERE user_id = $2 AND scope <> ''",
      [sql.string(group_id), sql.string(user_id)],
    ),
  )
  // In-flight sign-ins must not follow an account into a different group.
  use _ <- result.try(provider_store.invalidate(conn))
  use _ <- result.try(account_store.clear_pending(conn, user_id))
  // Keys unique within a group name the group, so they follow the user.
  db.execute(
    conn,
    "UPDATE howdy_auth_user_fields SET unique_key = $1 || value WHERE user_id = $2 AND substr(unique_key, 1, 2) = 'g:'",
    [sql.string(field.group_key(group_id, "")), sql.string(user_id)],
  )
}

/// Whether a field the user holds uniquely within their group is already
/// held in `group_id`, so moving them there would collide.
pub fn fields_taken_in_group(
  conn: Repo,
  user_id: String,
  group_id: String,
) -> service.Result(Bool) {
  db.query(
    conn,
    "SELECT f.name FROM howdy_auth_user_fields f JOIN howdy_auth_user_fields o ON o.name = f.name AND o.unique_key = $1 || f.value WHERE f.user_id = $2 AND substr(f.unique_key, 1, 2) = 'g:' LIMIT 1",
    [sql.string(field.group_key(group_id, "")), sql.string(user_id)],
    decode.field(0, decode.string, decode.success),
  )
  |> result.map(fn(rows) { rows != [] })
}

// --- Fields -----------------------------------------------------------------

/// Whose fields a statement touches. The names are trusted query text.
pub type Owner {
  Owner(table: String, fields: String, column: String)
}

pub const of_user = Owner(
  "howdy_auth_users",
  "howdy_auth_user_fields",
  "user_id",
)

pub const of_group = Owner(
  "howdy_auth_groups",
  "howdy_auth_group_fields",
  "group_id",
)

pub fn fields(
  conn: Repo,
  owner: Owner,
  id: String,
) -> service.Result(List(#(String, String))) {
  let row = {
    use name <- decode.field(0, decode.string)
    use value <- decode.field(1, decode.string)
    decode.success(#(name, value))
  }
  db.query(
    conn,
    "SELECT name, value FROM "
      <> owner.fields
      <> " WHERE "
      <> owner.column
      <> " = $1 ORDER BY name",
    [sql.string(id)],
    row,
  )
}

/// Apply field writes and move the owner's `updated_at`. Conflict when a
/// unique value is held by another owner: the insert steps aside for the
/// unique index rather than failing, so a concurrent claim reads as taken.
pub fn write_fields(
  conn: Repo,
  owner: Owner,
  id: String,
  writes: List(field.Write),
) -> service.Result(Int) {
  use _ <- result.try(
    list.try_fold(writes, Nil, fn(_, write) {
      use _ <- result.try(
        db.execute(
          conn,
          "DELETE FROM "
            <> owner.fields
            <> " WHERE "
            <> owner.column
            <> " = $1 AND name = $2",
          [sql.string(id), sql.string(write.name)],
        ),
      )
      case write {
        field.Remove(_) -> Ok(Nil)
        field.Put(name:, value:, key:) -> {
          use stored <- result.try(db.query(
            conn,
            "INSERT INTO "
              <> owner.fields
              <> "("
              <> owner.column
              <> ", name, value, unique_key) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING RETURNING name",
            [
              sql.string(id),
              sql.string(name),
              sql.string(value),
              sql.nullable(sql.string, key),
            ],
            decode.field(0, decode.string, decode.success),
          ))
          case stored {
            [_] -> Ok(Nil)
            _ -> Error(service.Conflict(name <> " is already taken"))
          }
        }
      }
    }),
  )
  let now = token.now()
  use _ <- result.try(
    db.execute(
      conn,
      "UPDATE "
        <> owner.table
        <> " SET updated_at = "
        <> db.write_time(conn, "$1")
        <> " WHERE id = $2",
      [sql.int(now), sql.string(id)],
    ),
  )
  Ok(now)
}

/// Users holding `value` in the field `name`, in one group or in any.
pub fn users_with_field(
  conn: Repo,
  name: String,
  value: String,
  group: Option(String),
) -> service.Result(List(User)) {
  db.query(
    conn,
    "SELECT "
      <> user_columns(conn)
      <> " FROM howdy_auth_user_fields f JOIN howdy_auth_users u ON u.id = f.user_id WHERE f.name = $1 AND f.value = $2 AND ($3 = '' OR u.group_id = $4) ORDER BY u.email, u.id",
    [sql.string(name), sql.string(value), ..in_group(group)],
    user.row(),
  )
}

pub fn groups_with_field(
  conn: Repo,
  name: String,
  value: String,
) -> service.Result(List(Group)) {
  db.query(
    conn,
    "SELECT "
      <> group_columns(conn)
      <> " FROM howdy_auth_group_fields f JOIN howdy_auth_groups g ON g.id = f.group_id WHERE f.name = $1 AND f.value = $2 ORDER BY g.name, g.id",
    [sql.string(name), sql.string(value)],
    group.row(),
  )
}

/// Whether any address has accounts in more than one group.
pub fn shared_addresses(conn: Repo) -> service.Result(Bool) {
  db.query(
    conn,
    "SELECT email FROM howdy_auth_users GROUP BY email HAVING COUNT(*) > 1 LIMIT 1",
    [],
    decode.field(0, decode.string, decode.success),
  )
  |> result.map(fn(rows) { rows != [] })
}

/// Rewrite every login key for a change of mode. Check `shared_addresses`
/// before moving to per-address keys; the unique constraint refuses otherwise.
pub fn rekey_users(conn: Repo, per_group: Bool) -> service.Result(Nil) {
  let key = case per_group {
    True -> "group_id || ':' || email"
    False -> "email"
  }
  use _ <- result.try(
    db.execute(conn, "UPDATE howdy_auth_users SET login_key = " <> key, []),
  )
  use _ <- result.try(
    db.execute(
      conn,
      "UPDATE howdy_auth_identities SET subject = (SELECT u.login_key FROM howdy_auth_users u WHERE u.id = howdy_auth_identities.user_id) WHERE issuer = 'email'",
      [],
    ),
  )
  use _ <- result.try(provider_store.rekey(conn, per_group))
  // Pending tokens were issued under the old rules.
  db.execute(conn, "DELETE FROM howdy_auth_challenges", [])
}

// --- Authorization grants ---------------------------------------------------

/// Rows per INSERT. Gloo rewrites `$N` for SQLite by replacing `$1`, then
/// `$2`, and so on, which turns `$10` into `?0`: on that adapter a statement
/// can carry at most nine parameters. Anything here that binds more than nine
/// values must therefore be written for PostgreSQL only, or chunked like this.
fn insert_batch(conn: Repo) -> Int {
  case db.backend(conn) {
    Ok(Postgres) -> 100
    _ -> 3
  }
}

/// Insert a role's permissions in batches rather than one statement each.
/// Every value is bound; only the placeholder list is built from the input
/// length, never from the strings themselves.
pub fn insert_permissions(
  conn: Repo,
  scope: String,
  role: String,
  permissions: List(String),
) -> service.Result(Nil) {
  list.sized_chunk(permissions, insert_batch(conn))
  |> list.try_fold(Nil, fn(_, chunk) {
    let rows =
      list.index_map(chunk, fn(_, index) {
        let n = index * 3 + 1
        "($"
        <> int.to_string(n)
        <> ", $"
        <> int.to_string(n + 1)
        <> ", $"
        <> int.to_string(n + 2)
        <> ")"
      })
      |> string.join(", ")
    let args =
      list.flat_map(chunk, fn(permission) {
        [sql.string(scope), sql.string(role), sql.string(permission)]
      })
    db.execute(
      conn,
      "INSERT INTO howdy_authz_permissions(scope, role, permission) VALUES "
        <> rows,
      args,
    )
  })
}

/// Set or clear the locale a user's pages and emails use.
pub fn set_locale(
  conn: Repo,
  user_id: String,
  locale: Option(String),
) -> service.Result(Nil) {
  db.execute(conn, "UPDATE howdy_auth_users SET locale = $1 WHERE id = $2", [
    sql.nullable(sql.string, locale),
    sql.string(user_id),
  ])
}

/// The locale a user chose or registered with, if any.
pub fn user_locale(
  conn: Repo,
  user_id: String,
) -> service.Result(Option(String)) {
  db.query(
    conn,
    "SELECT locale FROM howdy_auth_users WHERE id = $1",
    [sql.string(user_id)],
    decode.field(0, decode.optional(decode.string), decode.success),
  )
  |> result.map(fn(rows) {
    case rows {
      [locale] -> locale
      _ -> option.None
    }
  })
}
