//// Passwords: registering with one, verifying one at login, and setting or
//// changing the caller's own. `howdy/auth` is the public face.

import gleam/option.{None, Some}
import gleam/result
import gleam/string
import howdy/auth/internal/account_store
import howdy/auth/internal/address
import howdy/auth/internal/audit
import howdy/auth/internal/common
import howdy/auth/internal/config.{type Config, External, InDatabase}
import howdy/auth/internal/database as db
import howdy/auth/internal/email_flow
import howdy/auth/internal/labels.{
  EmailToken, Password, PasswordChanged, Register,
}
import howdy/auth/internal/password as password_hash
import howdy/auth/internal/security_store
import howdy/auth/internal/session_flow.{type Issued}
import howdy/auth/internal/store
import howdy/auth/internal/token
import howdy/auth/policy
import howdy/auth/user.{type Principal, Acting, System}
import howdy/service

pub fn validate_new_password(
  config: Config,
  password: String,
) -> service.Result(Nil) {
  use _ <- result.try(password_hash.validate(
    password,
    config.policy.password_min_length,
  ))
  let normalized = password_hash.normalize(password)
  use _ <- result.try(password_hash.validate(
    normalized,
    config.policy.password_min_length,
  ))
  use _ <- result.try(password_hash.common_check(normalized))
  config.password_check(normalized)
}

pub fn register(
  config: Config,
  email: String,
  password: String,
  client: String,
) -> service.Result(Nil) {
  use <- audit.traced("auth.register_password", [])
  use hasher <- result.try(common.passwords(config))
  use _ <- result.try(validate_new_password(config, password))
  email_flow.request_challenge(
    config,
    email,
    Register,
    client,
    email_flow.WithPassword(fn() { password_hash.hash(hasher, password) }),
  )
}

/// Verify an email and password into a session the caller then publishes.
pub fn verify(
  config: Config,
  email: String,
  password: String,
  client: String,
) -> service.Result(Issued) {
  use hasher <- result.try(common.passwords(config))
  use email <- result.try(
    address.normalize_email(email)
    |> result.map_error(fn(_) { service.Unauthorized }),
  )
  use _ <- result.try(
    case
      string.byte_size(password) > 0
      && string.byte_size(password) <= policy.password_max_bytes
    {
      True -> Ok(Nil)
      False -> Error(service.Unauthorized)
    },
  )
  use within <- result.try(common.target(config, False))
  let address_key = common.address_key(config, within, email)
  let client_key = common.client_key(config, within, email, client)
  use _ <- result.try(common.password_attempt(config, address_key, client_key))
  use found <- result.try(
    db.connect(config.repo, store.password_candidates(_, email, within)),
  )
  let #(encoded, normalized) = case found {
    [#(_, encoded, normalized)] -> #(encoded, normalized)
    _ -> #(password_hash.dummy(hasher), True)
  }
  // Verification runs outside the transaction and performs the same
  // expensive work for missing accounts, avoiding a fast unknown-user path.
  use #(valid, legacy_input) <- result.try(password_hash.verify(
    hasher,
    encoded,
    password,
    normalized,
  ))
  case valid, found {
    True, [#(candidate, _, _)] -> {
      use upgraded <- result.try(
        case password_hash.needs_rehash(hasher, encoded) || legacy_input {
          True ->
            password_hash.rehash(hasher, encoded, password) |> result.map(Some)
          False -> Ok(None)
        },
      )
      use conn <- db.write_transaction(
        config.repo,
        touching: "howdy_auth_users",
      )
      // Recheck the credential and lock the account after hashing, so
      // suspension or a concurrent credential replacement cannot issue a
      // stale session.
      use users <- result.try(store.active_user_with_password(
        conn,
        candidate.id,
        encoded,
        normalized,
      ))
      // The login identifier may have changed during hashing.
      use user <- result.try(case users {
        [user] if user.email == email && user.group_id == candidate.group_id ->
          Ok(user)
        _ -> Error(service.Unauthorized)
      })
      use _ <- result.try(store.clear_password_attempts(conn, address_key))
      use _ <- result.try(store.clear_password_client(conn, client_key))
      use _ <- result.try(case upgraded {
        Some(hash) -> store.replace_password(conn, user.id, hash)
        None ->
          case normalized {
            True -> Ok(Nil)
            False -> store.mark_password_normalized(conn, user.id)
          }
      })
      session_flow.issue_session(conn, config, user, Password, client)
    }
    False, [#(candidate, _, _)] -> {
      // Committed on its own: there is no surrounding transaction to roll back.
      let _ =
        db.connect(config.repo, audit.event_from(
          _,
          candidate.id,
          "login.failed",
          System,
          "",
          client,
        ))
      Error(service.Unauthorized)
    }
    _, _ -> Error(service.Unauthorized)
  }
}

pub fn set(
  config: Config,
  principal: Principal,
  password: String,
) -> service.Result(Nil) {
  use hasher <- result.try(common.passwords(config))
  use _ <- result.try(validate_new_password(config, password))
  let fresh = fn(conn) {
    let now = token.now()
    let created_after = now - config.policy.fresh_session_seconds
    use fresh <- result.try(case config.sessions {
      InDatabase ->
        store.fresh_email_session(
          conn,
          principal.session_id,
          principal.user.id,
          now,
          created_after,
        )
      External(external) -> {
        use entry <- result.try(external.get(principal.session_id))
        use users <- result.try(store.active_user(
          conn,
          principal.user.id,
          locking: True,
        ))
        use version <- result.try(account_store.version(conn, principal.user.id))
        Ok(case entry, users {
          Some(entry), [_] ->
            entry.version == version
            && entry.user_id == principal.user.id
            && labels.method_from(entry.method) == EmailToken
            && entry.expires_at > now
            && entry.created_at > created_after
          _, _ -> False
        })
      }
    })
    case fresh {
      True -> Ok(Nil)
      False -> Error(service.Forbidden)
    }
  }
  // Refuse before paying for a hash, then check again under the row lock.
  use _ <- result.try(db.connect(config.repo, fresh))
  use encoded <- result.try(password_hash.hash(hasher, password))
  // Revoked after the commit: from then on the old password opens no more.
  use <- common.after_commit(config, fn(external) {
    external.delete_for_user(principal.user.id, Some(principal.session_id))
  })
  use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
  use _ <- result.try(fresh(conn))
  use _ <- result.try(store.replace_password(conn, principal.user.id, encoded))
  use _ <- result.try(store.delete_other_sessions(
    conn,
    principal.user.id,
    principal.session_id,
  ))
  let address_key =
    common.address_key(
      config,
      Some(principal.user.group_id),
      principal.user.email,
    )
  use _ <- result.try(store.clear_password_attempts(conn, address_key))
  use _ <- result.try(store.clear_password_clients(conn, address_key))
  use _ <- result.try(security_store.clear(conn, principal.user.id))
  audit.event(conn, principal.user.id, "password.set", Acting(principal), "")
}

pub fn change(
  config: Config,
  principal: Principal,
  current: String,
  new: String,
  client: String,
) -> service.Result(Nil) {
  use hasher <- result.try(common.passwords(config))
  let wrong =
    service.Coded(
      "password_incorrect",
      service.Invalid("current password is incorrect"),
    )
  use _ <- result.try(
    case
      string.byte_size(current) > 0
      && string.byte_size(current) <= policy.password_max_bytes
    {
      True -> Ok(Nil)
      False -> Error(wrong)
    },
  )
  use _ <- result.try(case current == new {
    True ->
      Error(service.Coded(
        "password_unchanged",
        service.Invalid("new password must differ from the current"),
      ))
    False -> Ok(Nil)
  })
  use _ <- result.try(validate_new_password(config, new))
  let user = principal.user
  let within = Some(user.group_id)
  let address_key = common.address_key(config, within, user.email)
  let client_key = common.client_key(config, within, user.email, client)
  use found <- result.try(
    db.connect(config.repo, store.password_candidates(_, user.email, within)),
  )
  use #(encoded, normalized) <- result.try(case found {
    [#(candidate, encoded, normalized)] if candidate.id == user.id ->
      Ok(#(encoded, normalized))
    _ -> Error(service.Forbidden)
  })
  use _ <- result.try(common.password_attempt(config, address_key, client_key))
  use #(valid, _) <- result.try(password_hash.verify(
    hasher,
    encoded,
    current,
    normalized,
  ))
  use _ <- result.try(case valid {
    True -> Ok(Nil)
    False -> {
      let _ =
        db.connect(config.repo, audit.event_from(
          _,
          user.id,
          "password.change_failed",
          Acting(principal),
          "",
          client,
        ))
      Error(wrong)
    }
  })
  use replacement <- result.try(password_hash.hash(hasher, new))
  // The notice follows the commit even when external session cleanup fails.
  use <- common.after_commit(config, fn(external) {
    external.delete_for_user(user.id, Some(principal.session_id))
  })
  use _ <- result.try({
    use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
    // Lock the account and recheck both proofs after hashing: the session may
    // have been revoked, or the password replaced, during hashing.
    use _ <- result.try(session_flow.current_account(
      conn,
      config,
      principal,
      False,
    ))
    use users <- result.try(store.active_user_with_password(
      conn,
      user.id,
      encoded,
      normalized,
    ))
    use _ <- result.try(case users {
      [_] -> Ok(Nil)
      _ -> Error(wrong)
    })
    use _ <- result.try(store.replace_password(conn, user.id, replacement))
    use _ <- result.try(store.delete_other_sessions(
      conn,
      user.id,
      principal.session_id,
    ))
    use _ <- result.try(store.clear_password_attempts(conn, address_key))
    use _ <- result.try(store.clear_password_clients(conn, address_key))
    use _ <- result.try(security_store.clear(conn, user.id))
    audit.event_from(
      conn,
      user.id,
      "password.changed",
      Acting(principal),
      "",
      client,
    )
  })
  let _ =
    config.deliver(common.delivery(
      config,
      user.email,
      "",
      PasswordChanged,
      None,
      common.recipient_locale(config, user.locale),
    ))
  Ok(Nil)
}
