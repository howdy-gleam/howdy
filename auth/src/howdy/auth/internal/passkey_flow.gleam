//// Passkeys: the relying party configuration, registering a key to an
//// account, signing up with one, signing in with one, and managing the keys
//// an account holds. `howdy/auth` is the public face.

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import gloo/repo.{type Repo}
import howdy/auth/internal/account_store
import howdy/auth/internal/address
import howdy/auth/internal/audit
import howdy/auth/internal/common
import howdy/auth/internal/config.{type Config, Config, PasskeySetup}
import howdy/auth/internal/database as db
import howdy/auth/internal/email_flow
import howdy/auth/internal/labels.{
  Passkey, PasskeyLogin, PasskeyRegister, PasskeySignup, Register,
}
import howdy/auth/internal/security_store
import howdy/auth/internal/session_flow
import howdy/auth/internal/store
import howdy/auth/internal/token
import howdy/auth/internal/types.{
  type LoginStep, type PasskeyChallenge, PasskeyChallenge,
}
import howdy/auth/passkey
import howdy/auth/secret
import howdy/auth/user.{type Principal, Acting}
import howdy/service

// -- Configuration ------------------------------------------------------------

pub fn enable(
  config: Config,
  relying_party_name: String,
) -> service.Result(Config) {
  case
    string.trim(relying_party_name) != ""
    && string.byte_size(relying_party_name) <= 128
  {
    True ->
      Ok(
        Config(
          ..config,
          passkeys: Some(PasskeySetup(relying_party_name, None, [])),
        ),
      )
    False ->
      Error(service.Invalid(
        "passkey relying-party name must contain 1 to 128 bytes",
      ))
  }
}

pub fn relying_party(
  config: Config,
  id: String,
  origins: List(String),
) -> service.Result(Config) {
  use setup <- result.try(case config.passkeys {
    Some(setup) -> Ok(setup)
    None -> Error(service.Invalid("enable passkeys before their relying party"))
  })
  let id = string.lowercase(string.trim(id))
  use origins <- result.try(list.try_map(origins, address.canonical_origin))
  let origins =
    list.unique(origins) |> list.filter(fn(origin) { origin != config.origin })
  let within = fn(origin) {
    case uri.parse(origin) {
      Ok(uri.Uri(host: Some(host), ..)) ->
        host == id || string.ends_with(host, "." <> id)
      _ -> False
    }
  }
  case
    id != ""
    && !string.starts_with(id, ".")
    && list.length(origins) <= 16
    && list.all([config.origin, ..origins], within)
  {
    True ->
      Ok(
        Config(
          ..config,
          passkeys: Some(PasskeySetup(..setup, rp: Some(id), origins:)),
        ),
      )
    False ->
      Error(service.Invalid(
        "passkey RP ID must be the hostname of the public origin and of at most 16 further origins, or a parent domain of them all",
      ))
  }
}

pub fn signup_enabled(config: Config) -> Bool {
  option.is_some(config.passkeys) && config.registration && config.email_tokens
}

// -- The account's keys -------------------------------------------------------

pub fn list_keys(
  config: Config,
  principal: Principal,
) -> service.Result(List(passkey.Passkey)) {
  use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
  use #(user, _) <- result.try(session_flow.current_account(
    conn,
    config,
    principal,
    False,
  ))
  security_store.passkeys(conn, user.id)
  |> result.map(list.map(_, fn(key) { key.info }))
}

fn key_name(name: String) -> service.Result(String) {
  let name = string.trim(name)
  case name != "" && string.byte_size(name) <= 100 {
    True -> Ok(name)
    False ->
      Error(service.Coded(
        "passkey_name",
        service.Invalid("passkey name must contain 1 to 100 bytes"),
      ))
  }
}

pub fn begin_registration(
  config: Config,
  principal: Principal,
  name: String,
) -> service.Result(PasskeyChallenge) {
  use #(rp, rp_name, origins) <- result.try(common.passkey_config(config))
  use name <- result.try(key_name(name))
  let challenge = token.new()
  use options <- result.try({
    use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
    use #(user, _) <- result.try(session_flow.current_account(
      conn,
      config,
      principal,
      True,
    ))
    use keys <- result.try(security_store.passkeys(conn, user.id))
    use _ <- result.try(case list.length(keys) < 20 {
      True -> Ok(Nil)
      False -> Error(passkey_limit())
    })
    let #(options, state) =
      passkey.registration_options(
        rp,
        rp_name,
        config.origin,
        origins,
        user.id,
        user.email,
        keys,
      )
    use version <- result.try(account_store.version(conn, user.id))
    use _ <- result.try(security_store.ceremony(
      conn,
      token.digest(challenge),
      labels.ceremony_name(PasskeyRegister),
      security_store.Ceremony(
        Some(user.id),
        principal.session_id,
        user.group_id,
        version,
        state,
        name,
      ),
    ))
    Ok(options)
  })
  Ok(PasskeyChallenge(secret.wrap(challenge), options))
}

pub fn finish_registration(
  config: Config,
  principal: Principal,
  challenge: String,
  credential: String,
) -> service.Result(Nil) {
  use _ <- result.try(common.passkey_config(config))
  use ceremony <- result.try(common.consume_ceremony(
    config,
    challenge,
    PasskeyRegister,
    credential,
  ))
  use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
  use #(user, _) <- result.try(session_flow.current_account(
    conn,
    config,
    principal,
    True,
  ))
  use _ <- result.try(common.bound_ceremony(conn, ceremony, user, principal))
  use keys <- result.try(security_store.passkeys(conn, user.id))
  use _ <- result.try(case list.length(keys) < 20 {
    True -> Ok(Nil)
    False -> Error(passkey_limit())
  })
  use key <- result.try(passkey.register(
    ceremony.payload,
    credential,
    user.id,
    ceremony.label,
    token.now(),
  ))
  use _ <- result.try(security_store.add_passkey(conn, key))
  audit.event(
    conn,
    user.id,
    "passkey.registered",
    Acting(principal),
    key.info.id,
  )
}

pub fn rename(
  config: Config,
  principal: Principal,
  id: String,
  name: String,
) -> service.Result(Nil) {
  use name <- result.try(key_name(name))
  use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
  use #(user, _) <- result.try(session_flow.current_account(
    conn,
    config,
    principal,
    True,
  ))
  use _ <- result.try(own_passkey(conn, user.id, id))
  use _ <- result.try(security_store.rename_passkey(conn, user.id, id, name))
  audit.event(conn, user.id, "passkey.renamed", Acting(principal), id)
}

fn own_passkey(
  conn: Repo,
  user_id: String,
  id: String,
) -> service.Result(passkey.Stored) {
  use key <- result.try(
    security_store.passkey(conn, id)
    |> result.replace_error(service.NotFound("passkey")),
  )
  case key.user_id == user_id {
    True -> Ok(key)
    False -> Error(service.NotFound("passkey"))
  }
}

pub fn delete(
  config: Config,
  principal: Principal,
  id: String,
) -> service.Result(Nil) {
  use <- common.after_commit(config, fn(store) {
    store.delete_for_user(principal.user.id, None)
  })
  use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
  use #(user, method) <- result.try(session_flow.current_account(
    conn,
    config,
    principal,
    True,
  ))
  use _ <- result.try(own_passkey(conn, user.id, id))
  // Conservative removal: prove a separate login method, not the key being deleted.
  use _ <- result.try(case method {
    Passkey -> Error(service.Forbidden)
    _ -> Ok(Nil)
  })
  use _ <- result.try(security_store.delete_passkey(conn, user.id, id))
  use _ <- result.try(account_store.clear_pending(conn, user.id))
  use _ <- result.try(account_store.revoke(conn, user.id))
  audit.event(conn, user.id, "passkey.deleted", Acting(principal), id)
}

// -- Signing up ---------------------------------------------------------------

pub fn begin_signup(
  config: Config,
  email: String,
  name: String,
) -> service.Result(PasskeyChallenge) {
  use #(rp, rp_name, origins) <- result.try(common.passkey_config(config))
  use _ <- result.try(case signup_enabled(config) {
    True -> Ok(Nil)
    False -> Error(service.Forbidden)
  })
  use email <- result.try(address.normalize_email(email))
  use name <- result.try(key_name(name))
  // The WebAuthn user handle, and so the id the account will be created under.
  let id = token.new()
  let #(options, state) =
    passkey.registration_options(
      rp,
      rp_name,
      config.origin,
      origins,
      id,
      email,
      [],
    )
  let challenge = token.new()
  use _ <- result.try(
    db.transaction(config.repo, security_store.ceremony(
      _,
      token.digest(challenge),
      labels.ceremony_name(PasskeySignup),
      security_store.Ceremony(
        None,
        "",
        option.unwrap(config.group, ""),
        0,
        // An email address holds no newline, nor does a token.
        id <> "\n" <> email <> "\n" <> state,
        name,
      ),
    )),
  )
  Ok(PasskeyChallenge(secret.wrap(challenge), options))
}

pub fn finish_signup(
  config: Config,
  challenge: String,
  credential: String,
  client: String,
) -> service.Result(Nil) {
  use _ <- result.try(common.passkey_config(config))
  use ceremony <- result.try(common.consume_ceremony(
    config,
    challenge,
    PasskeySignup,
    credential,
  ))
  // Register into the group the ceremony began in, never a different one.
  use config <- result.try(case config.group, ceremony.group_id {
    None, "" -> Ok(config)
    None, id -> Ok(config.in_group(config, id))
    Some(bound), id if bound == id -> Ok(config)
    Some(_), _ -> Error(service.Unauthorized)
  })
  use #(id, email, state) <- result.try(
    case string.split_once(ceremony.payload, "\n") {
      Ok(#(id, rest)) ->
        case string.split_once(rest, "\n") {
          Ok(#(email, state)) -> Ok(#(id, email, state))
          Error(_) -> Error(service.Unauthorized)
        }
      Error(_) -> Error(service.Unauthorized)
    },
  )
  use key <- result.try(passkey.register(
    state,
    credential,
    id,
    ceremony.label,
    token.now(),
  ))
  email_flow.request_challenge(
    config,
    email,
    Register,
    client,
    email_flow.WithPasskey(passkey.encode(key)),
  )
}

// -- Signing in ---------------------------------------------------------------

pub fn begin_login(config: Config) -> service.Result(PasskeyChallenge) {
  use #(rp, _, origins) <- result.try(common.passkey_config(config))
  let #(options, state) =
    passkey.authentication_options(rp, config.origin, origins)
  let challenge = token.new()
  use _ <- result.try(
    db.transaction(config.repo, security_store.ceremony(
      _,
      token.digest(challenge),
      labels.ceremony_name(PasskeyLogin),
      security_store.Ceremony(
        None,
        "",
        option.unwrap(config.group, ""),
        0,
        state,
        "",
      ),
    )),
  )
  Ok(PasskeyChallenge(secret.wrap(challenge), options))
}

pub fn finish_login(
  config: Config,
  challenge: String,
  credential: String,
  client: String,
) -> service.Result(LoginStep) {
  use _ <- result.try(common.passkey_config(config))
  use ceremony <- result.try(common.consume_ceremony(
    config,
    challenge,
    PasskeyLogin,
    credential,
  ))
  use id <- result.try(passkey.credential_id(credential))
  use issued <- result.try({
    use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
    use initial <- result.try(security_store.passkey(conn, id))
    use users <- result.try(store.active_user(
      conn,
      initial.user_id,
      locking: True,
    ))
    use user <- result.try(case users {
      [user] -> Ok(user)
      _ -> Error(service.Unauthorized)
    })
    use _ <- result.try(common.in_bound_group(config, user.group_id))
    use _ <- result.try(
      case ceremony.group_id == "" || ceremony.group_id == user.group_id {
        True -> Ok(Nil)
        False -> Error(service.Unauthorized)
      },
    )
    // Re-read after acquiring the user lock, including the signature counter.
    use stored <- result.try(security_store.passkey(conn, id))
    use verified <- result.try(passkey.verify(
      ceremony.payload,
      credential,
      stored,
    ))
    use _ <- result.try(security_store.update_passkey(conn, verified))
    session_flow.issue_session(conn, config, user, Passkey, client)
  })
  session_flow.publish_step(config, issued)
}

fn passkey_limit() -> service.Error {
  service.Coded(
    "passkey_limit",
    service.Conflict("at most 20 passkeys per account"),
  )
}
