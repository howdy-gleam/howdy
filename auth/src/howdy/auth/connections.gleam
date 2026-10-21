//// SSO connection management. Every operation here is privileged: authorize
//// the caller first, as with `howdy/auth/groups`. None is exposed over HTTP.
//// Enable connections with `auth.with_sso`.
////
//// Disabling or deleting a connection stops new sign-ins through it. Sessions
//// it already issued live on until they expire; end them with
//// `auth.revoke_sessions` when a customer is offboarded.

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gloo/repo.{type Repo}
import howdy/auth.{type Auth}
import howdy/auth/connection.{type Connection, type Protocol}
import howdy/auth/group.{Single}
import howdy/auth/internal/connection_store
import howdy/auth/internal/database as db
import howdy/auth/internal/keyring
import howdy/auth/internal/store
import howdy/auth/internal/token
import howdy/auth/user.{type Actor}
import howdy/service

const table = "howdy_auth_sso_connections"

/// Create a connection with a generated id. Its users sign in to `group`;
/// under `Single` that is `group.default_id`.
pub fn create(
  identity: Auth,
  group group_id: String,
  name name: String,
  protocol protocol: Protocol,
  domains domains: List(String),
  by actor: Actor,
) -> service.Result(Connection) {
  create_with_id(
    identity,
    id: token.new(),
    group: group_id,
    name:,
    protocol:,
    domains:,
    by: actor,
  )
}

/// Create a connection under an id of your choosing, such as the customer's
/// slug: 1 to 64 of letters, digits, hyphen and underscore. The id is part of
/// the URLs the customer configures at their provider, so it cannot change.
pub fn create_with_id(
  identity: Auth,
  id id: String,
  group group_id: String,
  name name: String,
  protocol protocol: Protocol,
  domains domains: List(String),
  by actor: Actor,
) -> service.Result(Connection) {
  use config <- result.try(auth.sso_config(identity))
  use _ <- result.try(valid_id(id))
  use name <- result.try(valid_name(name))
  use protocol <- result.try(connection.valid_protocol(protocol))
  use domains <- result.try(connection.valid_domains(domains))
  use _ <- result.try(case auth.group_mode(identity), group_id {
    Single, g if g != group.default_id ->
      Error(service.Invalid(
        "every user shares the default group; choose another mode with auth.with_groups",
      ))
    _, _ -> Ok(Nil)
  })
  use sealed <- result.try(connection.seal(config, id, protocol))
  use conn <- db.write_transaction(auth.repo(identity), touching: table)
  use groups <- result.try(store.find_group(conn, group_id))
  use _ <- result.try(case groups {
    [_] -> Ok(Nil)
    _ -> Error(service.NotFound("group"))
  })
  use taken <- result.try(connection_store.find(conn, config, id))
  use _ <- result.try(case taken {
    None -> Ok(Nil)
    Some(_) ->
      Error(service.Conflict("an SSO connection with this id already exists"))
  })
  use _ <- result.try(connection_store.insert(
    conn,
    id,
    group_id,
    name,
    protocol,
    sealed,
  ))
  use _ <- result.try(connection_store.set_domains(conn, id, domains))
  use _ <- result.try(auth.event(conn, "", "sso.created", actor, id))
  require(conn, config, id)
}

pub fn get(identity: Auth, id: String) -> service.Result(Connection) {
  use config <- result.try(auth.sso_config(identity))
  use conn <- db.connect(auth.repo(identity))
  require(conn, config, id)
}

/// Every connection, by name.
pub fn list(identity: Auth) -> service.Result(List(Connection)) {
  use config <- result.try(auth.sso_config(identity))
  use conn <- db.connect(auth.repo(identity))
  connection_store.all(conn, config, None)
}

/// Re-encrypt every connection with the key given to `connection.config`: the
/// last step of a rotation (see `connection.with_decryption_keys`). Returns how
/// many needed it; once every node seals with the new key, a rerun returns 0
/// and the old key can be dropped. Safe to run while serving. A connection no
/// configured key opens stops it with an error naming the connection.
pub fn reseal(identity: Auth) -> service.Result(Int) {
  use config <- result.try(auth.sso_config(identity))
  use conn <- db.connect(auth.repo(identity))
  keyring.reseal_all(
    connection.keys(config),
    conn,
    page: connection_store.sealed,
    replace: connection_store.reseal,
    unreadable: fn(id) {
      service.Internal("SSO connection could not be decrypted: " <> id)
    },
  )
}

/// One group's connections, by name.
pub fn in_group(
  identity: Auth,
  group_id: String,
) -> service.Result(List(Connection)) {
  use config <- result.try(auth.sso_config(identity))
  use conn <- db.connect(auth.repo(identity))
  connection_store.all(conn, config, Some(group_id))
}

pub fn rename(
  identity: Auth,
  id: String,
  to name: String,
  by actor: Actor,
) -> service.Result(Connection) {
  use name <- result.try(valid_name(name))
  use conn, _ <- change(identity, id, "sso.renamed", actor)
  connection_store.rename(conn, id, name)
}

/// Replace what the customer's provider handed over. Rotating a client secret
/// or a signing certificate leaves users as they were. Pointing the connection
/// at a different provider (another OIDC issuer or SAML entity ID) forgets the
/// identities signed in through it, because the new provider's subjects name
/// different people: accounts remain, and each user links again.
pub fn set_protocol(
  identity: Auth,
  id: String,
  to protocol: Protocol,
  by actor: Actor,
) -> service.Result(Connection) {
  use protocol <- result.try(connection.valid_protocol(protocol))
  use conn, config <- change(identity, id, "sso.protocol_changed", actor)
  use current <- result.try(require(conn, config, id))
  use _ <- result.try(
    case
      connection.upstream(current.protocol) == connection.upstream(protocol)
    {
      True -> Ok(Nil)
      False -> connection_store.forget_identities(conn, id)
    },
  )
  use sealed <- result.try(connection.seal(config, id, protocol))
  connection_store.set_protocol(conn, id, protocol, sealed)
}

/// Replace the connection's email domains. Conflict if another connection
/// holds one: confirm the customer controls a domain before adding it. On an
/// enforced connection the members now covered are signed out, as by `enforce`.
pub fn set_domains(
  identity: Auth,
  id: String,
  to domains: List(String),
  by actor: Actor,
) -> service.Result(Connection) {
  use domains <- result.try(connection.valid_domains(domains))
  use config <- result.try(auth.sso_config(identity))
  let apply = fn(conn) {
    use _ <- result.try(require(conn, config, id))
    use _ <- result.try(connection_store.set_domains(conn, id, domains))
    use _ <- result.try(connection_store.touch(conn, id))
    use _ <- result.try(auth.event(conn, "", "sso.domains_changed", actor, id))
    require(conn, config, id)
  }
  use current <- result.try(get(identity, id))
  case current.enforced {
    True -> auth.end_covered_sessions(identity, id, apply)
    False ->
      db.write_transaction(auth.repo(identity), touching: table, run: apply)
  }
}

pub fn enable(
  identity: Auth,
  id: String,
  by actor: Actor,
) -> service.Result(Connection) {
  use conn, _ <- change(identity, id, "sso.enabled", actor)
  connection_store.set_enabled(conn, id, True)
}

/// Refuse new sign-ins without forgetting the configuration or its users.
pub fn disable(
  identity: Auth,
  id: String,
  by actor: Actor,
) -> service.Result(Connection) {
  use conn, _ <- change(identity, id, "sso.disabled", actor)
  connection_store.set_enabled(conn, id, False)
}

/// Require the members the connection covers to sign in through it: those of
/// its group whose address is in one of its domains. Every other way in is
/// refused for them (email tokens, passwords, passkeys, built-in providers),
/// and they are signed out now, so that the next sign-in is the provider's.
/// Members outside the domains, such as guests, are unaffected.
///
/// A covered member with an existing account is taken up by their first SSO
/// sign-in; nobody needs to link beforehand. Enforcement lapses while the
/// connection is disabled. If the customer's provider breaks, `stop_enforcing`
/// is the way back in: keep an operator account outside the domains.
pub fn enforce(
  identity: Auth,
  id: String,
  by actor: Actor,
) -> service.Result(Connection) {
  use config <- result.try(auth.sso_config(identity))
  use conn <- auth.end_covered_sessions(identity, id)
  use current <- result.try(require(conn, config, id))
  use _ <- result.try(case current.domains {
    [] ->
      Error(service.Invalid(
        "an SSO connection without domains covers nobody; add domains first",
      ))
    _ -> Ok(Nil)
  })
  use _ <- result.try(connection_store.set_enforced(conn, id, True))
  use _ <- result.try(auth.event(conn, "", "sso.enforced", actor, id))
  require(conn, config, id)
}

pub fn stop_enforcing(
  identity: Auth,
  id: String,
  by actor: Actor,
) -> service.Result(Connection) {
  use conn, _ <- change(identity, id, "sso.enforcement_stopped", actor)
  connection_store.set_enforced(conn, id, False)
}

/// Let a sign-in through this connection stand without Howdy's own second
/// factor, for a customer whose provider already demands one. Off by default.
///
/// This is trust, not verification: providers report how a user authenticated
/// too inconsistently to check, so Howdy takes the customer's word that their
/// policy requires MFA. It also means the provider's administrator can reach an
/// account in the connection's domains and group that has a Howdy factor,
/// without that factor. Each such sign-in is audited as `mfa.provider_trusted`.
///
/// Such a session has not proven the Howdy factor, so it cannot disable it or
/// regenerate recovery codes. Other ways to sign in still ask for it.
pub fn trust_provider_mfa(
  identity: Auth,
  id: String,
  by actor: Actor,
) -> service.Result(Connection) {
  use conn, _ <- change(identity, id, "sso.provider_mfa_trusted", actor)
  connection_store.set_trusts_mfa(conn, id, True)
}

/// Ask for Howdy's second factor after this connection again.
pub fn require_local_mfa(
  identity: Auth,
  id: String,
  by actor: Actor,
) -> service.Result(Connection) {
  use conn, _ <- change(identity, id, "sso.local_mfa_required", actor)
  connection_store.set_trusts_mfa(conn, id, False)
}

/// Delete the connection and the identities signed in through it. The user
/// accounts remain, with whatever other ways to sign in they have.
pub fn delete(
  identity: Auth,
  id: String,
  by actor: Actor,
) -> service.Result(Nil) {
  use config <- result.try(auth.sso_config(identity))
  use conn <- db.write_transaction(auth.repo(identity), touching: table)
  use _ <- result.try(require(conn, config, id))
  use _ <- result.try(connection_store.delete(conn, id))
  auth.event(conn, "", "sso.deleted", actor, id)
}

fn change(
  identity: Auth,
  id: String,
  action: String,
  actor: Actor,
  apply: fn(Repo, connection.Config) -> service.Result(Nil),
) -> service.Result(Connection) {
  use config <- result.try(auth.sso_config(identity))
  use conn <- db.write_transaction(auth.repo(identity), touching: table)
  use _ <- result.try(require(conn, config, id))
  use _ <- result.try(apply(conn, config))
  use _ <- result.try(auth.event(conn, "", action, actor, id))
  require(conn, config, id)
}

fn require(
  conn: Repo,
  config: connection.Config,
  id: String,
) -> service.Result(Connection) {
  use found <- result.try(connection_store.find(conn, config, id))
  option.to_result(found, service.NotFound("SSO connection"))
}

fn valid_id(id: String) -> service.Result(Nil) {
  let allowed =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
  case
    id != ""
    && string.byte_size(id) <= 64
    && list.all(string.to_graphemes(id), string.contains(allowed, _))
  {
    True -> Ok(Nil)
    False ->
      Error(service.Invalid(
        "SSO connection ids are 1 to 64 letters, digits, hyphens and underscores",
      ))
  }
}

fn valid_name(name: String) -> service.Result(String) {
  let name = string.trim(name)
  case name != "" && string.byte_size(name) <= 200 {
    True -> Ok(name)
    False ->
      Error(service.Invalid(
        "SSO connection names must be nonempty and at most 200 bytes",
      ))
  }
}
