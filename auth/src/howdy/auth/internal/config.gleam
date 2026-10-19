//// The configuration record every flow reads, and the one place it is
//// constructed. `howdy/auth` is the public face: it wraps `Config` in its
//// opaque `Auth` type and exposes the `with_*` builders. Add a field here
//// and in `new`, and nowhere else.

import gleam/option.{type Option, None, Some}
import gleam/result
import gloo/repo.{type Repo}
import howdy/auth/connection
import howdy/auth/group.{type Mode, AccountPerGroup, Single}
import howdy/auth/internal/account_store
import howdy/auth/internal/audit
import howdy/auth/internal/database as db
import howdy/auth/internal/password as password_hash
import howdy/auth/internal/provider_store
import howdy/auth/internal/schema
import howdy/auth/internal/security_store
import howdy/auth/internal/store
import howdy/auth/internal/types.{type Delivery}
import howdy/auth/mfa
import howdy/auth/policy.{type Policy}
import howdy/auth/provider
import howdy/auth/session_store.{type SessionStore}
import howdy/auth/user.{type User, System}
import howdy/locale.{type Negotiator}
import howdy/migration
import howdy/rate_limit
import howdy/service

pub type Config {
  Config(
    repo: Repo,
    origin: String,
    deliver: fn(Delivery) -> Result(Nil, Nil),
    registration: Bool,
    email_tokens: Bool,
    providers: List(provider.Provider),
    passwords: Option(password_hash.Passwords),
    policy: Policy,
    password_check: fn(String) -> service.Result(Nil),
    throttle_key: String,
    groups: Mode,
    /// The group this value acts in, chosen with `in_group`.
    group: Option(String),
    sessions: Sessions,
    before_delete: Option(fn(Repo, User) -> service.Result(Nil)),
    mfa: Option(mfa.Config),
    passkeys: Option(PasskeySetup),
    sso: Option(connection.Config),
    email_change_approval: Bool,
    multi_session: Option(Int),
    email_links: Option(String),
    email_codes: Bool,
    rate_limits: Option(rate_limit.Store),
    /// The locales pages and emails are written in; see
    /// `howdy/auth.with_locales`.
    locales: Negotiator,
    /// The locale of the request this value acts for, chosen with
    /// `in_locale`: the one a new account and its emails start with.
    locale: Option(String),
  )
}

/// The database keeps sessions in the transactions that create and revoke
/// them. An external store cannot join one, so it is written after the
/// database commits; see `howdy/auth.with_session_store` for what that
/// changes.
pub type Sessions {
  InDatabase
  External(SessionStore)
}

pub type PasskeySetup {
  PasskeySetup(name: String, rp: Option(String), origins: List(String))
}

/// The migrations this package owns.
pub fn schema() -> migration.Package {
  schema.authentication()
}

/// The only constructor. `origin` must already be canonical (see
/// `address.canonical_origin`); the throttle key and group mode are read
/// from the database, which must be migrated.
pub fn new(
  repo repo: Repo,
  origin origin: String,
  deliver deliver: fn(Delivery) -> Result(Nil, Nil),
) -> service.Result(Config) {
  use _ <- result.try(migration.check(repo, schema()))
  use throttle_key <- result.try(db.transaction(repo, store.throttle_key))
  use groups <- result.try(db.connect(repo, stored_groups))
  Ok(Config(
    repo:,
    origin:,
    deliver:,
    registration: False,
    email_tokens: True,
    providers: [],
    passwords: None,
    policy: policy.default(),
    password_check: fn(_) { Ok(Nil) },
    throttle_key:,
    groups:,
    group: None,
    sessions: InDatabase,
    before_delete: None,
    mfa: None,
    passkeys: None,
    sso: None,
    email_change_approval: False,
    multi_session: None,
    email_links: None,
    email_codes: False,
    rate_limits: None,
    locales: locale.negotiator(["en"], default: "en"),
    locale: None,
  ))
}

/// The same configuration, acting in one group.
pub fn in_group(config: Config, group_id: String) -> Config {
  Config(..config, group: Some(group_id))
}

/// Record the group mode, converting the installation when it changes; see
/// `howdy/auth.with_groups`.
pub fn with_groups(config: Config, mode: Mode) -> service.Result(Config) {
  use _ <- result.try({
    use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
    use stored <- result.try(stored_groups(conn))
    case stored == mode {
      True -> Ok(Nil)
      False -> convert_groups(conn, stored, mode)
    }
  })
  Ok(Config(..config, groups: mode))
}

fn stored_groups(conn: Repo) -> service.Result(Mode) {
  use stored <- result.try(store.setting(conn, "groups"))
  case stored {
    [] -> Ok(Single)
    [name] ->
      group.mode_from(name)
      |> result.replace_error(service.Internal(
        "auth database records a group mode this version does not know",
      ))
    _ -> Error(service.Internal("auth database operation failed"))
  }
}

fn convert_groups(conn: Repo, from: Mode, to: Mode) -> service.Result(Nil) {
  use _ <- result.try(case to {
    Single -> {
      use outside <- result.try(store.users_outside_group(
        conn,
        group.default_id,
      ))
      case outside {
        False -> Ok(Nil)
        True ->
          Error(service.Conflict(
            "users exist outside the default group; move them before choosing group.Single",
          ))
      }
    }
    _ -> Ok(Nil)
  })
  use _ <- result.try(case from, to {
    AccountPerGroup, _ -> {
      use shared <- result.try(store.shared_addresses(conn))
      case shared {
        False -> store.rekey_users(conn, False)
        True ->
          Error(service.Conflict(
            "an email address has accounts in more than one group; only group.AccountPerGroup allows that",
          ))
      }
    }
    _, AccountPerGroup -> store.rekey_users(conn, True)
    _, _ -> Ok(Nil)
  })
  use _ <- result.try(provider_store.invalidate(conn))
  use _ <- result.try(account_store.invalidate_email_changes(conn))
  use _ <- result.try(security_store.invalidate(conn))
  use _ <- result.try(store.set_setting(conn, "groups", group.mode_name(to)))
  audit.event(conn, "", "groups.mode", System, group.mode_name(to))
}
