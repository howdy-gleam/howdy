//// Emailed tokens and codes: requesting a challenge for sign-in or
//// registration, sending it, and redeeming it into a session.
//// `howdy/auth` is the public face.

import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import howdy/auth/group.{OneGroupPerUser}
import howdy/auth/internal/account_flow
import howdy/auth/internal/address
import howdy/auth/internal/audit
import howdy/auth/internal/common
import howdy/auth/internal/config.{type Config}
import howdy/auth/internal/connection_store
import howdy/auth/internal/database as db
import howdy/auth/internal/labels.{
  type Intent, type Purpose, AlreadyRegistered, EmailToken, Login, Register,
  Registration, SignIn,
}
import howdy/auth/internal/security_store
import howdy/auth/internal/session_flow.{type Issued}
import howdy/auth/internal/store
import howdy/auth/internal/token
import howdy/auth/passkey
import howdy/auth/user.{System}
import howdy/service

/// How the request supplies the credential to store with the challenge.
/// A token-only request can be answered by a token already sent; one that
/// carries a password cannot, so only that path pays a cooldown.
pub type Preparation {
  TokenOnly
  WithPassword(fn() -> service.Result(String))
  /// An encoded passkey whose attestation has already been verified.
  WithPasskey(String)
}

// -- Requesting ---------------------------------------------------------------

pub fn request_challenge(
  config: Config,
  email: String,
  intent: Intent,
  client: String,
  preparation: Preparation,
) -> service.Result(Nil) {
  use _ <- result.try(common.require_email_tokens(config))
  use email <- result.try(address.normalize_email(email))
  use _ <- result.try(case intent == Register && !config.registration {
    True -> Error(service.Forbidden)
    False -> Ok(Nil)
  })
  use within <- result.try(common.target(config, intent == Register))
  use _ <- result.try(common.existing(config, within))
  // A covered member's token could never be redeemed. The reply is the same
  // as for any other address; the sign-in page routes them by `sso_for_email`.
  use enforcing <- result.try(
    db.connect(config.repo, connection_store.enforcing(_, email, within)),
  )
  use <- bool.guard(option.is_some(enforcing), Ok(Nil))
  let now = token.now()
  // What the token will actually do, and so what the email must say. Asking to
  // register an address that already has an account sends a sign-in token and
  // keeps no password from the request. The reply to the caller is unchanged,
  // so this tells only the inbox owner anything.
  // Registering collides with an account anywhere the address is unique,
  // which under `OneGroupPerUser` is every group, not just the one asked for.
  let domain = case config.groups, intent {
    OneGroupPerUser, Register -> None
    _, _ -> within
  }
  use owner <- result.try(
    db.connect(config.repo, store.user_id_for_email(_, email, domain)),
  )
  let #(stored, purpose, within) = case intent, owner {
    // The token signs in the account that exists, wherever it is.
    Register, Some(_) -> #(Login, AlreadyRegistered, domain)
    Register, None -> #(Register, Registration, within)
    Login, _ -> #(Login, SignIn, within)
  }
  case preparation {
    // A usable token already in that inbox answers the request: sending a
    // second one would let a third party fill the inbox, and refusing would
    // let them stop its owner receiving anything.
    TokenOnly ->
      send(
        config,
        email,
        within,
        stored,
        purpose,
        None,
        None,
        now,
        client,
        owner,
      )
    WithPasskey(key) -> {
      use _ <- result.try({
        use conn <- db.transaction(config.repo)
        store.reserve_email(
          conn,
          common.address_key(config, within, email),
          now,
          config.policy,
        )
      })
      // As with a password: an existing account keeps nothing from the request.
      let key = case purpose {
        AlreadyRegistered -> None
        _ -> Some(key)
      }
      send(
        config,
        email,
        within,
        stored,
        purpose,
        None,
        key,
        now,
        client,
        owner,
      )
    }
    WithPassword(hash) -> {
      // Reserve the cooldown before hashing, and keep it even if hashing or
      // delivery then fails. Hashing must not hold a transaction open.
      use _ <- result.try({
        use conn <- db.transaction(config.repo)
        store.reserve_email(
          conn,
          common.address_key(config, within, email),
          now,
          config.policy,
        )
      })
      // Hash before deciding to discard it, so the time taken cannot tell a
      // caller whether the address already has an account.
      use encoded <- result.try(hash())
      let password = case purpose {
        AlreadyRegistered -> None
        _ -> Some(encoded)
      }
      send(
        config,
        email,
        within,
        stored,
        purpose,
        password,
        None,
        now,
        client,
        owner,
      )
    }
  }
}

fn send(
  config: Config,
  email: String,
  within: Option(String),
  intent: Intent,
  purpose: Purpose,
  password: Option(String),
  passkey: Option(String),
  now: Int,
  client: String,
  owner: Option(String),
) -> service.Result(Nil) {
  let secret = token.new()
  let code = case config.email_codes {
    True -> Some(token.code())
    False -> None
  }
  use sending <- result.try({
    use conn <- db.transaction(config.repo)
    use sending <- result.try(store.claim_challenge(
      conn,
      address_key: common.address_key(config, within, email),
      digest: token.digest(secret),
      email:,
      intent: labels.intent_name(intent),
      group_id: within,
      now:,
      expires_at: now + config.policy.challenge_seconds,
      live_after: now + config.policy.email_coalesce_margin_seconds,
      password_hash: password,
      passkey:,
      code_digest: option.map(code, common.email_code_digest(config, email, _)),
      keep: config.policy.live_challenges,
    ))
    // Attributable only when the address has an account. Someone investigating
    // unexpected email can see which requests caused it and where from.
    use _ <- result.try(case owner, sending {
      Some(id), True ->
        audit.event_from(
          conn,
          id,
          "token.requested",
          System,
          labels.purpose_name(purpose),
          client,
        )
      _, _ -> Ok(Nil)
    })
    // The owner's chosen locale wins over the request's.
    use stored <- result.try(case owner, sending {
      Some(id), True -> store.user_locale(conn, id)
      _, _ -> Ok(None)
    })
    Ok(#(sending, common.recipient_locale(config, stored)))
  })
  let #(sending, locale) = sending
  case sending {
    False -> Ok(Nil)
    True ->
      case
        config.deliver(common.delivery(
          config,
          email,
          secret,
          purpose,
          code,
          locale,
        ))
      {
        Ok(Nil) -> Ok(Nil)
        Error(Nil) -> {
          let _ =
            db.connect(config.repo, store.delete_challenge(
              _,
              token.digest(secret),
            ))
          Error(service.Internal("auth email delivery failed"))
        }
      }
  }
}

// -- Redeeming ----------------------------------------------------------------

/// Consume a challenge, verify/create the account and issue a session. The
/// token is spent first, in its own transaction: it can create at most one
/// session even under concurrency, and an exchange that then fails (account
/// exists, suspended, method disabled) does not leave it usable.
pub fn redeem(
  config: Config,
  secret: String,
  client: String,
) -> service.Result(Issued) {
  use _ <- result.try(common.valid_token(secret))
  use consumed <- result.try({
    use conn <- db.transaction(config.repo)
    store.consume_challenge(conn, token.digest(secret), token.now())
  })
  redeem_challenge(config, consumed, client)
}

/// A code is tried against the address it was sent to. Every guess spends the
/// same budgets as a password guess first, so codes add no guessing capacity
/// of their own beyond the three each emailed code allows.
pub fn redeem_code(
  config: Config,
  email: String,
  code: String,
  client: String,
) -> service.Result(Issued) {
  use _ <- result.try(case common.email_codes_enabled(config) {
    True -> Ok(Nil)
    False -> Error(service.Forbidden)
  })
  use email <- result.try(
    address.normalize_email(email)
    |> result.replace_error(service.Unauthorized),
  )
  let code = string.trim(code)
  use _ <- result.try(
    case
      string.length(code) == 6
      && list.all(string.to_graphemes(code), string.contains("0123456789", _))
    {
      True -> Ok(Nil)
      False -> Error(service.Unauthorized)
    },
  )
  use within <- result.try(common.target(config, False))
  let address_key = common.address_key(config, within, email)
  let client_key = common.client_key(config, within, email, client)
  use _ <- result.try(common.password_attempt(config, address_key, client_key))
  use consumed <- result.try({
    use conn <- db.transaction(config.repo)
    store.take_code(
      conn,
      email,
      common.email_code_digest(config, email, code),
      token.now(),
    )
  })
  use issued <- result.try(redeem_challenge(config, consumed, client))
  let _ =
    db.transaction(config.repo, fn(conn) {
      use _ <- result.try(store.clear_password_attempts(conn, address_key))
      store.clear_password_client(conn, client_key)
    })
  Ok(issued)
}

fn redeem_challenge(
  config: Config,
  consumed: List(store.Challenge),
  client: String,
) -> service.Result(Issued) {
  use challenge <- result.try(case consumed {
    [value] -> Ok(value)
    _ -> Error(service.Unauthorized)
  })
  use _ <- result.try(common.require_email_tokens(config))
  use intent <- result.try(labels.intent_from(challenge.intent))
  use _ <- result.try(case challenge.group_id {
    Some(id) -> common.in_bound_group(config, id)
    None -> Ok(Nil)
  })
  use _ <- result.try(case challenge.password_hash {
    Some(_) -> common.passwords(config) |> result.map(fn(_) { Nil })
    None -> Ok(Nil)
  })
  // Only a registration carries a passkey. Its WebAuthn user handle is the id
  // the ceremony chose, so the account has to be created under that id.
  use key <- result.try(case challenge.passkey, intent {
    Some(encoded), Register -> {
      use _ <- result.try(common.passkey_config(config))
      passkey.decode(encoded) |> result.map(Some)
    }
    _, _ -> Ok(None)
  })
  use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
  use _ <- result.try(case intent {
    Register ->
      account_flow.register(
        conn,
        config,
        option.map(key, fn(key) { key.user_id }),
        challenge.email,
        challenge.group_id,
        client,
      )
    Login -> Ok(Nil)
  })
  use users <- result.try(store.active_user_by_email(
    conn,
    challenge.email,
    challenge.group_id,
  ))
  use user <- result.try(case users {
    [value] -> Ok(value)
    _ -> Error(service.Unauthorized)
  })
  use _ <- result.try(common.in_bound_group(config, user.group_id))
  use _ <- result.try(case challenge.password_hash {
    Some(encoded) ->
      store.insert_password(conn, user.id, encoded, challenge.normalized)
    None -> Ok(Nil)
  })
  use _ <- result.try(case key {
    Some(key) if key.user_id == user.id -> {
      use _ <- result.try(security_store.add_passkey(conn, key))
      audit.event_from(
        conn,
        user.id,
        "passkey.registered",
        System,
        key.info.id,
        client,
      )
    }
    Some(_) -> Error(service.Unauthorized)
    None -> Ok(Nil)
  })
  // Redeeming a token proves control of the address, so its back-off ends.
  use _ <- result.try(store.clear_email_throttle(
    conn,
    common.address_key(config, Some(user.group_id), challenge.email),
  ))
  session_flow.issue_session(conn, config, user, EmailToken, client)
}
