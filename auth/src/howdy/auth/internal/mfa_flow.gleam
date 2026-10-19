//// Second factors: enrolling a TOTP or delivered-code factor, verifying one
//// after a first-factor sign-in, remembered devices, recovery codes, and
//// resealing stored secrets after a key rotation. `howdy/auth` is the
//// public face.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import gloo/repo.{type Repo}
import howdy/auth/internal/account_store
import howdy/auth/internal/audit
import howdy/auth/internal/common
import howdy/auth/internal/config.{type Config}
import howdy/auth/internal/database as db
import howdy/auth/internal/keyring
import howdy/auth/internal/labels.{
  type MfaMethod, DeliveredCode, EmailToken, Impersonation, MfaEnrolment, Otp,
  Passkey, Password, Provider, RecoveryCode, Totp, TotpCode,
}
import howdy/auth/internal/security_store
import howdy/auth/internal/session_flow
import howdy/auth/internal/store
import howdy/auth/internal/token
import howdy/auth/internal/types.{
  type MfaSession, type MfaSetup, type Session, MfaSession, MfaSetup,
}
import howdy/auth/mfa
import howdy/auth/secret
import howdy/auth/user.{type Principal, type User, Acting, System}
import howdy/service

// -- Keys ---------------------------------------------------------------------

pub fn reseal(config: Config) -> service.Result(Int) {
  use mfa_config <- result.try(common.mfa_config(config))
  let keys = mfa.keys(mfa_config)
  let unreadable = fn(id) {
    service.Internal("MFA secret could not be decrypted: " <> id)
  }
  use conn <- db.connect(config.repo)
  use factors <- result.try(keyring.reseal_all(
    keys,
    conn,
    page: security_store.sealed_factors,
    replace: security_store.reseal_factor,
    unreadable:,
  ))
  use setups <- result.try(
    keyring.reseal_all(
      keys,
      conn,
      page: security_store.sealed_setups,
      replace: security_store.reseal_setup,
      unreadable: fn(_) { unreadable("an enrollment in progress") },
    ),
  )
  Ok(factors + setups)
}

// -- Enrolment ----------------------------------------------------------------

pub fn status(
  config: Config,
  principal: Principal,
) -> service.Result(Option(String)) {
  use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
  use #(user, _) <- result.try(session_flow.current_account(
    conn,
    config,
    principal,
    False,
  ))
  security_store.factor(conn, user.id)
  |> result.map(option.map(_, fn(f) { f.method }))
}

pub fn begin(
  config: Config,
  principal: Principal,
  method: MfaMethod,
) -> service.Result(MfaSetup) {
  use mfa_config <- result.try(common.mfa_config(config))
  let challenge = token.new()
  let seed = case method {
    TotpCode -> mfa.new_secret()
    _ -> mfa.otp()
  }
  use #(user, setup) <- result.try({
    use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
    use #(user, login_method) <- result.try(session_flow.current_account(
      conn,
      config,
      principal,
      True,
    ))
    use factor <- result.try(security_store.factor(conn, user.id))
    use _ <- result.try(case factor {
      None -> Ok(Nil)
      Some(_) -> Error(mfa_enabled())
    })
    use kind <- result.try(case method {
      TotpCode -> Ok(Totp)
      DeliveredCode if login_method != EmailToken ->
        case mfa.can_deliver(mfa_config) {
          True -> Ok(Otp)
          False -> Error(service.Forbidden)
        }
      _ -> Error(service.Forbidden)
    })
    use _ <- result.try(store.reserve_email(
      conn,
      token.keyed_digest(config.throttle_key, "mfa-enroll:" <> user.id),
      token.now(),
      config.policy,
    ))
    use payload <- result.try(case method {
      TotpCode -> mfa.seal(mfa_config, user.id, seed)
      _ -> Ok(code_digest(config, user.id, seed))
    })
    use version <- result.try(account_store.version(conn, user.id))
    use _ <- result.try(security_store.ceremony(
      conn,
      token.digest(challenge),
      labels.ceremony_name(MfaEnrolment),
      security_store.Ceremony(
        Some(user.id),
        principal.session_id,
        user.group_id,
        version,
        payload,
        labels.factor_name(kind),
      ),
    ))
    let setup = case method {
      TotpCode -> {
        let uri =
          "otpauth://totp/"
          <> uri.percent_encode(mfa.issuer(mfa_config) <> ":" <> user.email)
          <> "?secret="
          <> seed
          <> "&issuer="
          <> uri.percent_encode(mfa.issuer(mfa_config))
          <> "&algorithm=SHA1&digits=6&period=30"
        MfaSetup(
          secret.wrap(challenge),
          Some(secret.wrap(seed)),
          Some(secret.wrap(uri)),
          mfa.qr_code(uri) |> option.from_result |> option.map(secret.wrap),
        )
      }
      _ -> MfaSetup(secret.wrap(challenge), None, None, None)
    }
    Ok(#(user, setup))
  })
  case method {
    DeliveredCode ->
      case mfa.deliver(mfa_config, user, secret.wrap(seed)) {
        Ok(_) -> Ok(setup)
        Error(error) -> {
          let _ =
            db.connect(config.repo, security_store.discard(
              _,
              token.digest(challenge),
            ))
          Error(error)
        }
      }
    _ -> Ok(setup)
  }
}

fn code_digest(config: Config, user_id: String, code: String) -> String {
  token.keyed_digest(config.throttle_key, "mfa-code:" <> user_id <> ":" <> code)
}

fn security_attempt(config: Config, user_id: String) -> service.Result(Nil) {
  use attempts <- result.try(
    db.transaction(config.repo, security_store.reserve_attempt(_, user_id)),
  )
  case attempts <= 5 {
    True -> Ok(Nil)
    False -> Error(service.TooManyRequests(300))
  }
}

fn new_recovery_codes(
  conn: Repo,
  config: Config,
  user_id: String,
) -> service.Result(List(secret.Secret)) {
  use mfa_config <- result.try(common.mfa_config(config))
  let codes =
    list.map(list.repeat(Nil, mfa.recovery_codes(mfa_config)), fn(_) {
      mfa.backup()
    })
  use _ <- result.try(security_store.recovery_codes(
    conn,
    user_id,
    list.map(codes, code_digest(config, user_id, _)),
  ))
  Ok(list.map(codes, secret.wrap))
}

pub fn confirm(
  config: Config,
  principal: Principal,
  challenge: String,
  code: String,
) -> service.Result(List(secret.Secret)) {
  use mfa_config <- result.try(common.mfa_config(config))
  use _ <- result.try(
    db.write_transaction(config.repo, "howdy_auth_users", fn(conn) {
      session_flow.current_account(conn, config, principal, True)
      |> result.map(fn(_) { Nil })
    }),
  )
  use _ <- result.try(security_attempt(config, principal.user.id))
  use ceremony <- result.try(common.consume_ceremony(
    config,
    challenge,
    MfaEnrolment,
    code,
  ))
  use codes <- result.try({
    use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
    use #(user, _) <- result.try(session_flow.current_account(
      conn,
      config,
      principal,
      True,
    ))
    use _ <- result.try(common.bound_ceremony(conn, ceremony, user, principal))
    use existing <- result.try(security_store.factor(conn, user.id))
    use _ <- result.try(case existing {
      None -> Ok(Nil)
      _ -> Error(mfa_enabled())
    })
    use factor <- result.try(case labels.factor_from(ceremony.label) {
      Ok(Totp) -> {
        use seed <- result.try(mfa.open(mfa_config, user.id, ceremony.payload))
        use step <- result.try(
          mfa.verify_totp(seed, code, -1, token.now())
          |> result.replace_error(service.Unauthorized),
        )
        Ok(security_store.Factor(
          labels.factor_name(Totp),
          ceremony.payload,
          step,
        ))
      }
      Ok(Otp) if code != "" ->
        case
          token.constant_time_equal(
            code_digest(config, user.id, code),
            ceremony.payload,
          )
        {
          True -> Ok(security_store.Factor(labels.factor_name(Otp), "", -1))
          False -> Error(service.Unauthorized)
        }
      _ -> Error(service.Unauthorized)
    })
    use _ <- result.try(security_store.enable(conn, user.id, factor))
    use codes <- result.try(new_recovery_codes(conn, config, user.id))
    use _ <- result.try(account_store.clear_pending(conn, user.id))
    use _ <- result.try(account_store.revoke(conn, user.id))
    use _ <- result.try(security_store.reset_attempts(conn, user.id))
    use _ <- result.try(audit.event(
      conn,
      user.id,
      "mfa.enabled",
      Acting(principal),
      factor.method,
    ))
    Ok(codes)
  })
  // Database generation makes old external sessions inert even if cleanup fails.
  let _ =
    common.externally(config, fn(store) {
      store.delete_for_user(principal.user.id, None)
    })
  Ok(codes)
}

// -- Verifying ----------------------------------------------------------------

fn pending_user(
  conn: Repo,
  config: Config,
  digest: String,
) -> service.Result(#(security_store.Pending, User, security_store.Factor)) {
  use initial <- result.try(security_store.pending(conn, digest))
  use users <- result.try(store.active_user(
    conn,
    initial.user_id,
    locking: True,
  ))
  use user <- result.try(case users {
    [u] -> Ok(u)
    _ -> Error(service.Unauthorized)
  })
  use pending <- result.try(security_store.pending(conn, digest))
  use version <- result.try(account_store.version(conn, user.id))
  use _ <- result.try(common.in_bound_group(config, user.group_id))
  use _ <- result.try(
    case pending.group_id == user.group_id && pending.version == version {
      True -> Ok(Nil)
      False -> Error(service.Unauthorized)
    },
  )
  use factor <- result.try(security_store.factor(conn, user.id))
  use factor <- result.try(case factor {
    Some(factor) -> Ok(factor)
    None -> Error(service.Unauthorized)
  })
  // Configuration changes cannot promote proof from a disabled login method.
  use _ <- result.try(case labels.method_from(pending.method) {
    EmailToken -> common.require_email_tokens(config)
    // An impersonated session never reaches a second factor.
    Impersonation -> Error(service.Unauthorized)
    Password -> common.passwords(config) |> result.map(fn(_) { Nil })
    Passkey -> common.passkey_config(config) |> result.map(fn(_) { Nil })
    Provider(id) -> {
      use enabled <- result.try(common.provider_enabled(conn, config, id))
      case enabled {
        True -> Ok(Nil)
        False -> Error(service.NotFound("provider"))
      }
    }
  })
  Ok(#(pending, user, factor))
}

/// Whether a pending sign-in's first factor was something other than the
/// inbox, so a delivered code may serve as the second.
fn not_by_email(pending: security_store.Pending) -> Bool {
  pending.method != labels.method_name(EmailToken)
}

pub fn send_code(config: Config, challenge: String) -> service.Result(Nil) {
  use mfa_config <- result.try(common.mfa_config(config))
  use _ <- result.try(common.valid_token(challenge))
  let code = mfa.otp()
  let digest = token.digest(challenge)
  use user <- result.try({
    use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
    use #(pending, user, _) <- result.try(pending_user(conn, config, digest))
    use _ <- result.try(
      case not_by_email(pending) && mfa.can_deliver(mfa_config) {
        True -> Ok(Nil)
        False -> Error(service.Forbidden)
      },
    )
    use _ <- result.try(store.reserve_email(
      conn,
      token.keyed_digest(config.throttle_key, "mfa-send:" <> user.id),
      token.now(),
      config.policy,
    ))
    use _ <- result.try(security_store.send_otp(
      conn,
      digest,
      code_digest(config, user.id, code),
    ))
    Ok(user)
  })
  case mfa.deliver(mfa_config, user, secret.wrap(code)) {
    Ok(_) -> Ok(Nil)
    Error(error) -> {
      let _ = db.connect(config.repo, security_store.spend_pending(_, digest))
      Error(error)
    }
  }
}

pub fn verify(
  config: Config,
  challenge: String,
  method: MfaMethod,
  code: String,
  remember: Bool,
) -> service.Result(MfaSession) {
  use mfa_config <- result.try(common.mfa_config(config))
  use _ <- result.try(common.valid_token(challenge))
  let digest = token.digest(challenge)
  use initial <- result.try(
    db.connect(config.repo, security_store.pending(_, digest)),
  )
  use _ <- result.try(security_attempt(config, initial.user_id))
  let trusted = case remember {
    True -> Some(secret.wrap(token.new()))
    False -> None
  }
  use issued <- result.try({
    use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
    use #(pending, user, factor) <- result.try(pending_user(
      conn,
      config,
      digest,
    ))
    let totp = labels.factor_name(Totp)
    let by_email = !not_by_email(pending)
    use _ <- result.try(case method {
      TotpCode if factor.method == totp -> {
        use seed <- result.try(mfa.open(mfa_config, user.id, factor.secret))
        use step <- result.try(
          mfa.verify_totp(seed, code, factor.last_step, token.now())
          |> result.replace_error(service.Unauthorized),
        )
        security_store.step(conn, user.id, step)
      }
      RecoveryCode ->
        security_store.recover(
          conn,
          user.id,
          code_digest(config, user.id, string.uppercase(string.trim(code))),
        )
      DeliveredCode if !by_email && pending.otp_digest != "" && code != "" ->
        case
          mfa.can_deliver(mfa_config)
          && token.constant_time_equal(
            code_digest(config, user.id, code),
            pending.otp_digest,
          )
        {
          True -> Ok(Nil)
          False -> Error(service.Unauthorized)
        }
      _ -> Error(service.Unauthorized)
    })
    use _ <- result.try(security_store.spend_pending(conn, digest))
    use _ <- result.try(security_store.reset_attempts(conn, user.id))
    use _ <- result.try(case trusted {
      Some(value) ->
        security_store.add_trusted(
          conn,
          user.id,
          pending.version,
          token.digest(secret.reveal(value)),
          mfa.trust_seconds(mfa_config),
        )
      None -> Ok(Nil)
    })
    use _ <- result.try(audit.event_from(
      conn,
      user.id,
      "mfa.verified",
      System,
      labels.mfa_method_name(method),
      pending.client,
    ))
    session_flow.issue_verified_session(
      conn,
      config,
      user,
      labels.with_second_factor(pending.method),
      pending.client,
    )
  })
  use session <- result.try(session_flow.publish(config, issued))
  Ok(MfaSession(session, trusted))
}

pub fn use_trusted_device(
  config: Config,
  challenge: String,
  device: String,
) -> service.Result(Session) {
  use mfa_config <- result.try(common.mfa_config(config))
  use _ <- result.try(common.valid_token(challenge))
  use _ <- result.try(common.valid_token(device))
  use issued <- result.try({
    use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
    use #(pending, user, _) <- result.try(pending_user(
      conn,
      config,
      token.digest(challenge),
    ))
    use trusted <- result.try(security_store.trusted(
      conn,
      token.digest(device),
      user.id,
      pending.version,
    ))
    use _ <- result.try(case trusted, mfa.trust_renewal(mfa_config) {
      True, True ->
        security_store.renew_trusted(
          conn,
          token.digest(device),
          mfa.trust_seconds(mfa_config),
        )
      True, False -> Ok(Nil)
      False, _ -> Error(service.Unauthorized)
    })
    use _ <- result.try(security_store.spend_pending(
      conn,
      token.digest(challenge),
    ))
    session_flow.issue_verified_session(
      conn,
      config,
      user,
      labels.with_second_factor(pending.method),
      pending.client,
    )
  })
  session_flow.publish(config, issued)
}

// -- Managing an enrolled factor ----------------------------------------------

/// The current account, only from a session that passed its second factor.
fn require_mfa_session(
  conn: Repo,
  config: Config,
  principal: Principal,
) -> service.Result(User) {
  use #(user, _) <- result.try(session_flow.current_account(
    conn,
    config,
    principal,
    True,
  ))
  use method <- result.try(session_flow.session_method(
    conn,
    config,
    principal,
    user,
  ))
  case labels.second_factor_verified(method) {
    True -> Ok(user)
    False -> Error(service.Forbidden)
  }
}

pub fn disable(config: Config, principal: Principal) -> service.Result(Nil) {
  use _ <- result.try(common.mfa_config(config))
  use <- common.after_commit(config, fn(store) {
    store.delete_for_user(principal.user.id, None)
  })
  use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
  use user <- result.try(require_mfa_session(conn, config, principal))
  use _ <- result.try(security_store.disable(conn, user.id))
  use _ <- result.try(account_store.clear_pending(conn, user.id))
  use _ <- result.try(account_store.revoke(conn, user.id))
  audit.event(conn, user.id, "mfa.disabled", Acting(principal), "")
}

pub fn regenerate_recovery_codes(
  config: Config,
  principal: Principal,
) -> service.Result(List(secret.Secret)) {
  use _ <- result.try(common.mfa_config(config))
  use codes <- result.try({
    use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
    use user <- result.try(require_mfa_session(conn, config, principal))
    use codes <- result.try(new_recovery_codes(conn, config, user.id))
    use _ <- result.try(account_store.clear_pending(conn, user.id))
    use _ <- result.try(account_store.revoke(conn, user.id))
    use _ <- result.try(audit.event(
      conn,
      user.id,
      "mfa.recovery_regenerated",
      Acting(principal),
      "",
    ))
    Ok(codes)
  })
  let _ =
    common.externally(config, fn(store) {
      store.delete_for_user(principal.user.id, None)
    })
  Ok(codes)
}

pub fn trusted_devices(
  config: Config,
  principal: Principal,
) -> service.Result(List(#(String, Int, Int))) {
  use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
  use #(user, _) <- result.try(session_flow.current_account(
    conn,
    config,
    principal,
    False,
  ))
  security_store.trusted_devices(conn, user.id)
}

pub fn revoke_trusted_device(
  config: Config,
  principal: Principal,
  id: String,
) -> service.Result(Nil) {
  use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
  use #(user, _) <- result.try(session_flow.current_account(
    conn,
    config,
    principal,
    True,
  ))
  use _ <- result.try(security_store.delete_trusted(conn, user.id, id))
  audit.event(conn, user.id, "mfa.device_revoked", Acting(principal), "")
}

fn mfa_enabled() -> service.Error {
  service.Coded("mfa_enabled", service.Conflict("MFA is already enabled"))
}
