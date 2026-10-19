//// Transactional passkey and MFA storage. Mutations take the user's row lock
//// in auth; low-entropy verification budgets commit before trying a code.

import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gloo/repo.{type Repo}
import gloo/sql
import howdy/auth/internal/database as db
import howdy/auth/internal/token
import howdy/auth/passkey
import howdy/service

pub const challenge_seconds = 300

pub type Ceremony {
  Ceremony(
    user_id: Option(String),
    session_id: String,
    group_id: String,
    version: Int,
    payload: String,
    label: String,
  )
}

pub fn ceremony(
  conn: Repo,
  digest: String,
  kind: String,
  value: Ceremony,
) -> service.Result(Nil) {
  // One statement sweeps expired ceremonies and replaces this session's
  // earlier one of the same kind. Other tables' expiries are swept where
  // they are written and by `auth.prune_expired`.
  use _ <- result.try(
    db.execute(
      conn,
      "DELETE FROM howdy_auth_ceremonies WHERE expires_at <= $1 OR (user_id = $2 AND kind = $3 AND session_id = $4)",
      [
        sql.int(token.now()),
        sql.nullable(sql.string, value.user_id),
        sql.string(kind),
        sql.string(value.session_id),
      ],
    ),
  )
  db.execute(
    conn,
    "INSERT INTO howdy_auth_ceremonies(digest, kind, user_id, session_id, group_id, version, payload, label, expires_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)",
    [
      sql.string(digest),
      sql.string(kind),
      sql.nullable(sql.string, value.user_id),
      sql.string(value.session_id),
      sql.string(value.group_id),
      sql.int(value.version),
      sql.string(value.payload),
      sql.string(value.label),
      sql.int(token.now() + challenge_seconds),
    ],
  )
}

pub fn consume(
  conn: Repo,
  digest: String,
  kind: String,
) -> service.Result(Ceremony) {
  use rows <- result.try(
    db.query(
      conn,
      "DELETE FROM howdy_auth_ceremonies WHERE digest = $1 AND kind = $2 AND expires_at > $3 RETURNING user_id, session_id, group_id, version, payload, label",
      [sql.string(digest), sql.string(kind), sql.int(token.now())],
      {
        use user_id <- decode.field(0, decode.optional(decode.string))
        use session_id <- decode.field(1, decode.string)
        use group_id <- decode.field(2, decode.string)
        use version <- decode.field(3, decode.int)
        use payload <- decode.field(4, decode.string)
        use label <- decode.field(5, decode.string)
        decode.success(Ceremony(
          user_id,
          session_id,
          group_id,
          version,
          payload,
          label,
        ))
      },
    ),
  )
  case rows {
    [row] -> Ok(row)
    _ -> Error(service.Unauthorized)
  }
}

pub fn discard(conn: Repo, digest: String) -> service.Result(Nil) {
  db.execute(conn, "DELETE FROM howdy_auth_ceremonies WHERE digest = $1", [
    sql.string(digest),
  ])
}

fn key_row() -> decode.Decoder(passkey.Stored) {
  use id <- decode.field(0, decode.string)
  use user_id <- decode.field(1, decode.string)
  use name <- decode.field(2, decode.string)
  use key <- decode.field(3, decode.string)
  use counter <- decode.field(4, decode.int)
  use transports <- decode.field(5, decode.string)
  use eligible <- decode.field(6, decode.int)
  use backed <- decode.field(7, decode.int)
  use aaguid <- decode.field(8, decode.string)
  use created <- decode.field(9, decode.int)
  decode.success(passkey.Stored(
    passkey.Passkey(id, name, created, aaguid, eligible == 1, backed == 1),
    user_id,
    key,
    counter,
    transports,
  ))
}

const key_columns = "id, user_id, name, public_key, sign_count, transports, backup_eligible, backed_up, aaguid, created_at"

pub fn passkeys(
  conn: Repo,
  user_id: String,
) -> service.Result(List(passkey.Stored)) {
  db.query(
    conn,
    "SELECT "
      <> key_columns
      <> " FROM howdy_auth_passkeys WHERE user_id = $1 ORDER BY created_at, id",
    [sql.string(user_id)],
    key_row(),
  )
}

pub fn passkey(conn: Repo, id: String) -> service.Result(passkey.Stored) {
  use rows <- result.try(db.query(
    conn,
    "SELECT " <> key_columns <> " FROM howdy_auth_passkeys WHERE id = $1",
    [sql.string(id)],
    key_row(),
  ))
  case rows {
    [row] -> Ok(row)
    _ -> Error(service.Unauthorized)
  }
}

// Gloo's SQLite placeholder rewriting supports at most nine parameters.
// The caller holds a transaction, so filling the timestamp is atomic with insert.
pub fn add_passkey(conn: Repo, key: passkey.Stored) -> service.Result(Nil) {
  use rows <- result.try(db.query(
    conn,
    "INSERT INTO howdy_auth_passkeys("
      <> key_columns
      <> ") VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,0) ON CONFLICT DO NOTHING RETURNING id",
    [
      sql.string(key.info.id),
      sql.string(key.user_id),
      sql.string(key.info.name),
      sql.string(key.key),
      sql.int(key.counter),
      sql.string(key.transports),
      sql.int(boolean(key.info.backup_eligible)),
      sql.int(boolean(key.info.backed_up)),
      sql.string(key.info.aaguid),
    ],
    decode.field(0, decode.string, decode.success),
  ))
  case rows {
    [_] ->
      db.execute(
        conn,
        "UPDATE howdy_auth_passkeys SET created_at = $1 WHERE id = $2",
        [sql.int(key.info.created_at), sql.string(key.info.id)],
      )
    _ ->
      Error(service.Coded(
        "passkey_registered",
        service.Conflict("passkey is already registered"),
      ))
  }
}

pub fn update_passkey(conn: Repo, key: passkey.Stored) -> service.Result(Nil) {
  db.execute(
    conn,
    "UPDATE howdy_auth_passkeys SET sign_count = $1, backed_up = $2 WHERE id = $3 AND user_id = $4",
    [
      sql.int(key.counter),
      sql.int(boolean(key.info.backed_up)),
      sql.string(key.info.id),
      sql.string(key.user_id),
    ],
  )
}

pub fn rename_passkey(
  conn: Repo,
  user_id: String,
  id: String,
  name: String,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "UPDATE howdy_auth_passkeys SET name = $1 WHERE id = $2 AND user_id = $3",
    [sql.string(name), sql.string(id), sql.string(user_id)],
  )
}

pub fn delete_passkey(
  conn: Repo,
  user_id: String,
  id: String,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "DELETE FROM howdy_auth_passkeys WHERE id = $1 AND user_id = $2",
    [sql.string(id), sql.string(user_id)],
  )
}

fn boolean(value: Bool) -> Int {
  case value {
    True -> 1
    False -> 0
  }
}

pub type Factor {
  Factor(method: String, secret: String, last_step: Int)
}

pub fn factor(conn: Repo, user_id: String) -> service.Result(Option(Factor)) {
  db.query(
    conn,
    "SELECT method, secret, last_step FROM howdy_auth_mfa WHERE user_id = $1",
    [sql.string(user_id)],
    {
      use method <- decode.field(0, decode.string)
      use secret <- decode.field(1, decode.string)
      use step <- decode.field(2, decode.int)
      decode.success(Factor(method, secret, step))
    },
  )
  |> result.map(fn(rows) { list.first(rows) |> option.from_result })
}

pub fn enable(
  conn: Repo,
  user_id: String,
  factor: Factor,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "INSERT INTO howdy_auth_mfa(user_id, method, secret, last_step) VALUES ($1,$2,$3,$4)",
    [
      sql.string(user_id),
      sql.string(factor.method),
      sql.string(factor.secret),
      sql.int(factor.last_step),
    ],
  )
}

pub fn step(conn: Repo, user_id: String, step: Int) -> service.Result(Nil) {
  db.execute(
    conn,
    "UPDATE howdy_auth_mfa SET last_step = $1 WHERE user_id = $2",
    [sql.int(step), sql.string(user_id)],
  )
}

pub fn disable(conn: Repo, user_id: String) -> service.Result(Nil) {
  use _ <- result.try(
    db.execute(conn, "DELETE FROM howdy_auth_mfa WHERE user_id = $1", [
      sql.string(user_id),
    ]),
  )
  db.execute(conn, "DELETE FROM howdy_auth_recovery_codes WHERE user_id = $1", [
    sql.string(user_id),
  ])
}

pub fn recovery_codes(
  conn: Repo,
  user_id: String,
  digests: List(String),
) -> service.Result(Nil) {
  use _ <- result.try(
    db.execute(
      conn,
      "DELETE FROM howdy_auth_recovery_codes WHERE user_id = $1",
      [sql.string(user_id)],
    ),
  )
  list.try_each(digests, fn(digest) {
    db.execute(
      conn,
      "INSERT INTO howdy_auth_recovery_codes(digest, user_id) VALUES ($1,$2)",
      [sql.string(digest), sql.string(user_id)],
    )
  })
}

pub fn recover(
  conn: Repo,
  user_id: String,
  digest: String,
) -> service.Result(Nil) {
  use rows <- result.try(db.query(
    conn,
    "DELETE FROM howdy_auth_recovery_codes WHERE user_id = $1 AND digest = $2 RETURNING digest",
    [sql.string(user_id), sql.string(digest)],
    decode.field(0, decode.string, decode.success),
  ))
  case rows {
    [_] -> Ok(Nil)
    _ -> Error(service.Unauthorized)
  }
}

pub fn reserve_attempt(conn: Repo, user_id: String) -> service.Result(Int) {
  use rows <- result.try(db.query(
    conn,
    "INSERT INTO howdy_auth_security_attempts(user_id, window_start, attempts) VALUES ($1,$2,1) ON CONFLICT(user_id) DO UPDATE SET attempts = CASE WHEN howdy_auth_security_attempts.window_start <= $3 THEN 1 ELSE CASE WHEN howdy_auth_security_attempts.attempts < 6 THEN howdy_auth_security_attempts.attempts + 1 ELSE 6 END END, window_start = CASE WHEN howdy_auth_security_attempts.window_start <= $4 THEN $5 ELSE howdy_auth_security_attempts.window_start END RETURNING attempts",
    [
      sql.string(user_id),
      sql.int(token.now()),
      sql.int(token.now() - 300),
      sql.int(token.now() - 300),
      sql.int(token.now()),
    ],
    decode.field(0, decode.int, decode.success),
  ))
  case rows {
    [n] -> Ok(n)
    _ -> Error(service.Unauthorized)
  }
}

pub fn reset_attempts(conn: Repo, user_id: String) -> service.Result(Nil) {
  db.execute(
    conn,
    "DELETE FROM howdy_auth_security_attempts WHERE user_id = $1",
    [sql.string(user_id)],
  )
}

pub type Pending {
  Pending(
    user_id: String,
    version: Int,
    group_id: String,
    method: String,
    client: String,
    otp_digest: String,
    otp_sent_at: Int,
  )
}

pub fn pending(conn: Repo, digest: String) -> service.Result(Pending) {
  use rows <- result.try(
    db.query(
      conn,
      "SELECT user_id, version, group_id, method, client, otp_digest, otp_sent_at FROM howdy_auth_mfa_pending WHERE digest = $1 AND expires_at > $2",
      [sql.string(digest), sql.int(token.now())],
      {
        use user <- decode.field(0, decode.string)
        use version <- decode.field(1, decode.int)
        use group <- decode.field(2, decode.string)
        use method <- decode.field(3, decode.string)
        use client <- decode.field(4, decode.string)
        use otp <- decode.field(5, decode.string)
        use sent <- decode.field(6, decode.int)
        decode.success(Pending(user, version, group, method, client, otp, sent))
      },
    ),
  )
  case rows {
    [row] -> Ok(row)
    _ -> Error(service.Unauthorized)
  }
}

pub fn add_pending(
  conn: Repo,
  digest: String,
  pending: Pending,
) -> service.Result(Nil) {
  use _ <- result.try(prune(conn))
  // Keep a bounded number without allowing new primary proofs to reset guessing budgets.
  use _ <- result.try(
    db.execute(
      conn,
      "DELETE FROM howdy_auth_mfa_pending WHERE user_id = $1 AND digest NOT IN (SELECT digest FROM howdy_auth_mfa_pending WHERE user_id = $2 ORDER BY expires_at DESC, digest LIMIT 4)",
      [sql.string(pending.user_id), sql.string(pending.user_id)],
    ),
  )
  db.execute(
    conn,
    "INSERT INTO howdy_auth_mfa_pending(digest, user_id, version, group_id, method, client, expires_at) VALUES ($1,$2,$3,$4,$5,$6,$7)",
    [
      sql.string(digest),
      sql.string(pending.user_id),
      sql.int(pending.version),
      sql.string(pending.group_id),
      sql.string(pending.method),
      sql.string(pending.client),
      sql.int(token.now() + challenge_seconds),
    ],
  )
}

pub fn spend_pending(conn: Repo, digest: String) -> service.Result(Nil) {
  db.execute(conn, "DELETE FROM howdy_auth_mfa_pending WHERE digest = $1", [
    sql.string(digest),
  ])
}

pub fn send_otp(
  conn: Repo,
  digest: String,
  otp_digest: String,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "UPDATE howdy_auth_mfa_pending SET otp_digest = $1, otp_sent_at = $2 WHERE digest = $3",
    [sql.string(otp_digest), sql.int(token.now()), sql.string(digest)],
  )
}

pub fn add_trusted(
  conn: Repo,
  user_id: String,
  version: Int,
  digest: String,
  seconds: Int,
) -> service.Result(Nil) {
  use _ <- result.try(
    db.execute(
      conn,
      "DELETE FROM howdy_auth_trusted_devices WHERE user_id = $1 AND digest NOT IN (SELECT digest FROM howdy_auth_trusted_devices WHERE user_id = $2 ORDER BY created_at DESC, digest LIMIT 9)",
      [sql.string(user_id), sql.string(user_id)],
    ),
  )
  db.execute(
    conn,
    "INSERT INTO howdy_auth_trusted_devices(digest, user_id, version, created_at, expires_at) VALUES ($1,$2,$3,$4,$5)",
    [
      sql.string(digest),
      sql.string(user_id),
      sql.int(version),
      sql.int(token.now()),
      sql.int(token.now() + seconds),
    ],
  )
}

pub fn renew_trusted(
  conn: Repo,
  digest: String,
  seconds: Int,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "UPDATE howdy_auth_trusted_devices SET expires_at = $1 WHERE digest = $2",
    [sql.int(token.now() + seconds), sql.string(digest)],
  )
}

pub fn trusted(
  conn: Repo,
  digest: String,
  user_id: String,
  version: Int,
) -> service.Result(Bool) {
  db.query(
    conn,
    "SELECT digest FROM howdy_auth_trusted_devices WHERE digest = $1 AND user_id = $2 AND version = $3 AND expires_at > $4",
    [
      sql.string(digest),
      sql.string(user_id),
      sql.int(version),
      sql.int(token.now()),
    ],
    decode.field(0, decode.string, decode.success),
  )
  |> result.map(fn(rows) { rows != [] })
}

pub fn trusted_devices(
  conn: Repo,
  user_id: String,
) -> service.Result(List(#(String, Int, Int))) {
  db.query(
    conn,
    "SELECT digest, created_at, expires_at FROM howdy_auth_trusted_devices WHERE user_id = $1 AND expires_at > $2 AND version = (SELECT session_version FROM howdy_auth_users WHERE id = $3) ORDER BY created_at DESC",
    [sql.string(user_id), sql.int(token.now()), sql.string(user_id)],
    {
      use id <- decode.field(0, decode.string)
      use created <- decode.field(1, decode.int)
      use expires <- decode.field(2, decode.int)
      decode.success(#(id, created, expires))
    },
  )
}

pub fn delete_trusted(
  conn: Repo,
  user_id: String,
  digest: String,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "DELETE FROM howdy_auth_trusted_devices WHERE user_id = $1 AND digest = $2",
    [sql.string(user_id), sql.string(digest)],
  )
}

pub fn clear(conn: Repo, user_id: String) -> service.Result(Nil) {
  use _ <- result.try(
    db.execute(conn, "DELETE FROM howdy_auth_ceremonies WHERE user_id = $1", [
      sql.string(user_id),
    ]),
  )
  use _ <- result.try(
    db.execute(conn, "DELETE FROM howdy_auth_mfa_pending WHERE user_id = $1", [
      sql.string(user_id),
    ]),
  )
  db.execute(conn, "DELETE FROM howdy_auth_trusted_devices WHERE user_id = $1", [
    sql.string(user_id),
  ])
}

pub fn invalidate(conn: Repo) -> service.Result(Nil) {
  use _ <- result.try(db.execute(conn, "DELETE FROM howdy_auth_ceremonies", []))
  db.execute(conn, "DELETE FROM howdy_auth_mfa_pending", [])
}

pub fn prune(conn: Repo) -> service.Result(Nil) {
  list.try_each(["ceremonies", "mfa_pending", "trusted_devices"], fn(table) {
    db.execute(
      conn,
      "DELETE FROM howdy_auth_" <> table <> " WHERE expires_at <= $1",
      [sql.int(token.now())],
    )
  })
}

/// Authenticator secrets after a user id, for resealing: `(user_id, user_id, secret)`.
pub fn sealed_factors(
  conn: Repo,
  after: String,
) -> service.Result(List(#(String, String, String))) {
  db.query(
    conn,
    "SELECT user_id, secret FROM howdy_auth_mfa WHERE method = 'totp' AND user_id > $1 ORDER BY user_id LIMIT 100",
    [sql.string(after)],
    {
      use user_id <- decode.field(0, decode.string)
      use secret <- decode.field(1, decode.string)
      decode.success(#(user_id, user_id, secret))
    },
  )
}

pub fn reseal_factor(
  conn: Repo,
  user_id: String,
  old: String,
  new: String,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "UPDATE howdy_auth_mfa SET secret = $1 WHERE user_id = $2 AND secret = $3",
    [sql.string(new), sql.string(user_id), sql.string(old)],
  )
}

/// Unexpired authenticator enrollments after a digest, for resealing:
/// `(digest, user_id, payload)`.
pub fn sealed_setups(
  conn: Repo,
  after: String,
) -> service.Result(List(#(String, String, String))) {
  db.query(
    conn,
    "SELECT digest, user_id, payload FROM howdy_auth_ceremonies WHERE kind = 'mfa-setup' AND label = 'totp' AND expires_at > $1 AND digest > $2 ORDER BY digest LIMIT 100",
    [sql.int(token.now()), sql.string(after)],
    {
      use digest <- decode.field(0, decode.string)
      use user_id <- decode.field(1, decode.string)
      use payload <- decode.field(2, decode.string)
      decode.success(#(digest, user_id, payload))
    },
  )
}

pub fn reseal_setup(
  conn: Repo,
  digest: String,
  old: String,
  new: String,
) -> service.Result(Nil) {
  db.execute(
    conn,
    "UPDATE howdy_auth_ceremonies SET payload = $1 WHERE digest = $2 AND payload = $3",
    [sql.string(new), sql.string(digest), sql.string(old)],
  )
}
