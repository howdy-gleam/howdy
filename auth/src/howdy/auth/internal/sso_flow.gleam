//// Enterprise single sign-on through a stored connection: finding the
//// connection for an address, beginning and finishing a sign-in or link
//// through it, and signing out the members a newly enforced connection
//// covers. Protocol details live in `sso_oidc` and `sso_saml`; the account
//// policy is `provider_flow`'s. `howdy/auth` is the public face.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gloo/repo.{type Repo}
import howdy/auth/connection
import howdy/auth/internal/address
import howdy/auth/internal/audit
import howdy/auth/internal/common
import howdy/auth/internal/config.{type Config}
import howdy/auth/internal/connection_store
import howdy/auth/internal/database as db
import howdy/auth/internal/provider_flow
import howdy/auth/internal/session_flow
import howdy/auth/internal/sso_oidc
import howdy/auth/internal/sso_saml
import howdy/auth/internal/store
import howdy/auth/internal/types.{type ProviderOutcome, type ProviderStart}
import howdy/auth/provider
import howdy/auth/secret
import howdy/auth/user.{type Principal}
import howdy/service
import howdy/trace

/// Sign out every member a newly enforced connection covers, in the caller's
/// transaction and then in an external session store.
pub fn end_covered_sessions(
  config: Config,
  connection_id: String,
  commit: fn(Repo) -> service.Result(a),
) -> service.Result(a) {
  use #(value, users) <- result.try({
    use conn <- db.write_transaction(
      config.repo,
      touching: "howdy_auth_sso_connections",
    )
    use value <- result.try(commit(conn))
    use users <- result.try(connection_store.covered(conn, connection_id))
    use _ <- result.try(list.try_each(users, store.delete_sessions(conn, _)))
    Ok(#(value, users))
  })
  use _ <- result.try(
    common.externally(config, fn(external) {
      list.try_each(users, external.delete_for_user(_, None))
    }),
  )
  Ok(value)
}

fn enabled_connection(
  config: Config,
  id: String,
) -> service.Result(#(connection.Config, connection.Connection)) {
  use sso <- result.try(common.sso_config(config))
  use found <- result.try(
    db.connect(config.repo, connection_store.find(_, sso, id)),
  )
  case found {
    Some(c) if c.enabled -> Ok(#(sso, c))
    _ -> Error(service.NotFound("SSO connection"))
  }
}

fn connection_provider(
  sso: connection.Config,
  conn: connection.Connection,
) -> service.Result(provider.Provider) {
  case conn.protocol {
    connection.Oidc(issuer, client_id, client_secret) ->
      sso_oidc.provider(sso, conn, issuer, client_id, client_secret)
    connection.Saml(entity_id, sso_url, certificates) ->
      Ok(sso_saml.provider(conn, entity_id, sso_url, certificates))
  }
}

pub fn for_email(
  config: Config,
  email: String,
) -> service.Result(Option(String)) {
  use _ <- result.try(common.sso_config(config))
  use email <- result.try(address.normalize_email(email))
  let assert [_, domain] = string.split(email, "@")
  db.connect(config.repo, connection_store.id_for_domain(_, domain))
}

pub fn begin(
  config: Config,
  connection_id: String,
  callback_path: String,
  client: String,
) -> service.Result(ProviderStart) {
  use #(sso, conn) <- result.try(enabled_connection(config, connection_id))
  use _ <- result.try(common.in_bound_group(config, conn.group_id))
  use provider <- result.try(connection_provider(sso, conn))
  provider_flow.begin_attempt(
    config.in_group(config, conn.group_id),
    provider,
    callback_path,
    client,
    None,
  )
}

pub fn begin_link(
  config: Config,
  principal: Principal,
  connection_id: String,
  callback_path: String,
) -> service.Result(ProviderStart) {
  use principal <- result.try(session_flow.fresh_principal(config, principal))
  use #(sso, conn) <- result.try(enabled_connection(config, connection_id))
  use _ <- result.try(case conn.group_id == principal.user.group_id {
    True -> Ok(Nil)
    False -> Error(service.Forbidden)
  })
  use provider <- result.try(connection_provider(sso, conn))
  provider_flow.begin_attempt(
    config.in_group(config, conn.group_id),
    provider,
    callback_path,
    principal.client,
    Some(principal),
  )
}

pub fn finish(
  config: Config,
  connection_id: String,
  callback_path: String,
  state: String,
  browser_token: String,
  code: Option(String),
  principal: Option(Principal),
) -> service.Result(ProviderOutcome) {
  use <- audit.traced("auth.finish_sso", [
    trace.string("auth.connection", connection_id),
  ])
  let id = connection.identity_issuer(connection_id)
  use attempt <- result.try(provider_flow.consume_attempt(
    config,
    id,
    callback_path,
    state,
    browser_token,
  ))
  use #(sso, conn) <- result.try(enabled_connection(config, connection_id))
  // The connection may have moved group while the user was at the provider.
  use _ <- result.try(case attempt.group_id == Some(conn.group_id) {
    True -> Ok(Nil)
    False -> Error(service.Unauthorized)
  })
  use code <- result.try(case code {
    Some(code) if code != "" -> Ok(code)
    _ -> Error(service.Unauthorized)
  })
  use provider <- result.try(connection_provider(sso, conn))
  use identity <- result.try(provider.exchange(
    provider,
    provider.Exchange(
      secret.wrap(code),
      attempt.redirect_uri,
      attempt.verifier,
      attempt.nonce_digest,
    ),
  ))
  provider_flow.complete_identity(
    config,
    id,
    attempt,
    identity,
    principal,
    provider_flow.Connection(conn.trusts_provider_mfa),
  )
}
