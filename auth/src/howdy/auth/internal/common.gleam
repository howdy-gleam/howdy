//// Helpers more than one flow needs: group targeting, throttle keys, token
//// shape, feature gates, email delivery, the external session store and the
//// single-use ceremonies passkeys and MFA share. `howdy/auth` is the public
//// face; nothing here is exported from it directly.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import gloo/repo.{type Repo}
import howdy/auth/connection
import howdy/auth/group.{AccountPerGroup, OneGroupPerUser, Single}
import howdy/auth/internal/account_store
import howdy/auth/internal/config.{type Config, External, InDatabase}
import howdy/auth/internal/connection_store
import howdy/auth/internal/database as db
import howdy/auth/internal/labels.{
  type Purpose, AlreadyRegistered, EmailChange, EmailChangeApproval,
  EmailChanged, PasswordChanged, Registration, SignIn,
}
import howdy/auth/internal/password as password_hash
import howdy/auth/internal/security_store
import howdy/auth/internal/store
import howdy/auth/internal/token
import howdy/auth/internal/types.{type Delivery, Delivery}
import howdy/auth/mfa
import howdy/auth/provider
import howdy/auth/secret
import howdy/auth/session_store.{type SessionStore}
import howdy/auth/user.{type Principal, type User}
import howdy/service

/// Emailed tokens and session tokens are 32 random bytes, base64url encoded.
const token_bytes = 43

pub fn valid_token(secret: String) -> service.Result(Nil) {
  case string.byte_size(secret) == token_bytes {
    True -> Ok(Nil)
    False -> Error(service.Unauthorized)
  }
}

pub fn secure(config: Config) -> Bool {
  string.starts_with(config.origin, "https://")
}

pub fn cookie_name(config: Config) -> String {
  case secure(config) {
    True -> "__Host-howdy_session"
    False -> "howdy_dev_session"
  }
}

// -- Groups -------------------------------------------------------------------

/// The group a sign-in or registration applies to, `None` for whichever group
/// holds the address.
pub fn target(
  config: Config,
  registering: Bool,
) -> service.Result(Option(String)) {
  case config.groups, config.group {
    Single, None -> Ok(Some(group.default_id))
    Single, Some(id) if id == group.default_id -> Ok(Some(id))
    Single, Some(_) -> Error(service.NotFound("group"))
    AccountPerGroup, None ->
      Error(service.Coded(
        "group_required",
        service.Invalid(
          "accounts belong to a group here; choose one with auth.in_group",
        ),
      ))
    OneGroupPerUser, None if registering ->
      Error(service.Coded(
        "group_required",
        service.Invalid(
          "registration needs a group; choose one with auth.in_group",
        ),
      ))
    _, within -> Ok(within)
  }
}

/// Refuse a group that does not exist rather than email a token that can
/// never be redeemed.
pub fn existing(config: Config, within: Option(String)) -> service.Result(Nil) {
  case within {
    None -> Ok(Nil)
    Some(id) -> {
      use found <- result.try(db.connect(config.repo, store.find_group(_, id)))
      case found {
        [_] -> Ok(Nil)
        _ -> Error(service.NotFound("group"))
      }
    }
  }
}

pub fn in_bound_group(config: Config, group_id: String) -> service.Result(Nil) {
  case config.group {
    Some(id) if id != group_id -> Error(service.Unauthorized)
    _ -> Ok(Nil)
  }
}

// -- Throttle keys ------------------------------------------------------------

/// Throttle rows are keyed with the installation secret so they do not reveal
/// which addresses have been asking for tokens. They follow the login key, so
/// accounts sharing an address across groups are throttled apart.
pub fn address_key(
  config: Config,
  within: Option(String),
  email: String,
) -> String {
  token.keyed_digest(config.throttle_key, account_key(config, within, email))
}

pub fn account_key(
  config: Config,
  within: Option(String),
  email: String,
) -> String {
  group.login_key(config.groups, option.unwrap(within, ""), email)
}

/// The per-client key a password or code guess is throttled under.
pub fn client_key(
  config: Config,
  within: Option(String),
  email: String,
  client: String,
) -> String {
  token.keyed_digest(
    config.throttle_key,
    account_key(config, within, email) <> "\u{0}" <> client,
  )
}

/// Spend the per-client pair reservation and the per-address attempt budget
/// that every password or emailed-code guess pays before verification.
pub fn password_attempt(
  config: Config,
  address_key: String,
  client_key: String,
) -> service.Result(Nil) {
  // Pair reservation and address ceiling each commit before verification.
  use _ <- result.try({
    use conn <- db.transaction(config.repo)
    store.reserve_password_client(
      conn,
      client_key,
      address_key,
      token.now(),
      config.policy,
    )
  })
  // Commit the attempt counter independently, including failed logins.
  use attempts <- result.try({
    use conn <- db.transaction(config.repo)
    store.count_password_attempt(conn, address_key, token.now(), config.policy)
  })
  case attempts {
    [n] if n <= config.policy.password_account_attempts -> Ok(Nil)
    _ -> Error(service.TooManyRequests(config.policy.password_window_seconds))
  }
}

// -- Feature gates ------------------------------------------------------------

pub fn passwords(config: Config) -> service.Result(password_hash.Passwords) {
  case config.passwords {
    Some(value) -> Ok(value)
    None -> Error(service.Forbidden)
  }
}

pub fn require_email_tokens(config: Config) -> service.Result(Nil) {
  case config.email_tokens {
    True -> Ok(Nil)
    False -> Error(service.Forbidden)
  }
}

pub fn email_codes_enabled(config: Config) -> Bool {
  config.email_tokens && config.email_codes
}

pub fn mfa_config(config: Config) -> service.Result(mfa.Config) {
  case config.mfa {
    Some(value) -> Ok(value)
    None -> Error(service.Forbidden)
  }
}

/// The passkey relying party as #(rp id, name, further origins).
pub fn passkey_config(
  config: Config,
) -> service.Result(#(String, String, List(String))) {
  use setup <- result.try(case config.passkeys {
    Some(setup) -> Ok(setup)
    None -> Error(service.Forbidden)
  })
  case setup.rp {
    Some(rp) -> Ok(#(rp, setup.name, setup.origins))
    None -> {
      use parsed <- result.try(
        uri.parse(config.origin) |> result.replace_error(service.Forbidden),
      )
      case parsed.host {
        Some(host) -> Ok(#(host, setup.name, []))
        None -> Error(service.Forbidden)
      }
    }
  }
}

pub fn sso_config(config: Config) -> service.Result(connection.Config) {
  option.to_result(config.sso, service.Forbidden)
}

/// Whether a session's provider method can still sign in: a built-in provider
/// that is configured, or an SSO connection that exists and is enabled.
pub fn provider_enabled(
  conn: Repo,
  config: Config,
  id: String,
) -> service.Result(Bool) {
  case labels.sso_connection_id(id), config.sso {
    Some(connection_id), Some(sso) ->
      connection_store.find(conn, sso, connection_id)
      |> result.map(fn(found) {
        case found {
          Some(c) -> c.enabled
          None -> False
        }
      })
    Some(_), None -> Ok(False)
    None, _ -> Ok(list.any(config.providers, fn(p) { provider.id(p) == id }))
  }
}

// -- Email delivery -----------------------------------------------------------

pub fn delivery(
  config: Config,
  email: String,
  token: String,
  purpose: Purpose,
  code: Option(String),
  locale: Option(String),
) -> Delivery {
  let page = case purpose {
    SignIn | Registration | AlreadyRegistered -> Some("/login#token=")
    EmailChange -> Some("/account#email-confirm=")
    EmailChangeApproval -> Some("/account#email-approve=")
    EmailChanged | PasswordChanged -> None
  }
  let link = case config.email_links, page {
    Some(path), Some(page) ->
      Some(secret.wrap(config.origin <> path <> page <> token))
    _, _ -> None
  }
  Delivery(
    email,
    secret.wrap(token),
    purpose,
    link,
    option.map(code, secret.wrap),
    locale,
  )
}

/// The locale to write to a recipient in: their own when they have one,
/// otherwise the request's.
pub fn recipient_locale(
  config: Config,
  stored: Option(String),
) -> Option(String) {
  option.or(stored, config.locale)
}

pub fn email_code_digest(
  config: Config,
  email: String,
  code: String,
) -> String {
  token.keyed_digest(
    config.throttle_key,
    "email-code\u{0}" <> email <> "\u{0}" <> code,
  )
}

// -- External session store ---------------------------------------------------

/// Run against the external store, if there is one.
pub fn externally(
  config: Config,
  run: fn(SessionStore) -> service.Result(Nil),
) -> service.Result(Nil) {
  case config.sessions {
    InDatabase -> Ok(Nil)
    External(external) -> run(external)
  }
}

/// Commit a database change, then revoke in the external store. In that
/// order, so a session revoked because a credential or suspension changed
/// cannot be recreated under the old rules in between.
pub fn after_commit(
  config: Config,
  revoke: fn(SessionStore) -> service.Result(Nil),
  commit: fn() -> service.Result(Nil),
) -> service.Result(Nil) {
  use _ <- result.try(commit())
  externally(config, revoke)
}

// -- Ceremonies ---------------------------------------------------------------

/// Spend a passkey or MFA ceremony of the given kind, whatever happens next.
pub fn consume_ceremony(
  config: Config,
  challenge: String,
  kind: labels.Ceremony,
  response: String,
) -> service.Result(security_store.Ceremony) {
  use _ <- result.try(valid_token(challenge))
  use _ <- result.try(case string.byte_size(response) <= 65_536 {
    True -> Ok(Nil)
    False ->
      Error(service.Coded(
        "credential_too_large",
        service.Invalid("credential response is too large"),
      ))
  })
  db.transaction(config.repo, security_store.consume(
    _,
    token.digest(challenge),
    labels.ceremony_name(kind),
  ))
}

/// A ceremony begun by this user, in this session, at this account version.
pub fn bound_ceremony(
  conn: Repo,
  ceremony: security_store.Ceremony,
  user: User,
  principal: Principal,
) -> service.Result(Nil) {
  use version <- result.try(account_store.version(conn, user.id))
  case
    ceremony.user_id == Some(user.id)
    && ceremony.session_id == principal.session_id
    && ceremony.group_id == user.group_id
    && ceremony.version == version
  {
    True -> Ok(Nil)
    False -> Error(service.Unauthorized)
  }
}
