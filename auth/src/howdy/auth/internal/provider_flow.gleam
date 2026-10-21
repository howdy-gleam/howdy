//// Built-in OAuth/OIDC providers: configuring one, beginning a browser
//// attempt, and finishing it by applying local account policy to the
//// identity the provider proved. SSO connections reuse `begin_attempt` and
//// `complete_identity`. `howdy/auth` is the public face.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gloo/repo.{type Repo}
import howdy/auth/group.{AccountPerGroup}
import howdy/auth/internal/account_flow
import howdy/auth/internal/address
import howdy/auth/internal/audit
import howdy/auth/internal/common
import howdy/auth/internal/config.{type Config, Config}
import howdy/auth/internal/database as db
import howdy/auth/internal/labels.{Provider}
import howdy/auth/internal/provider_store
import howdy/auth/internal/session_flow.{Pending}
import howdy/auth/internal/store
import howdy/auth/internal/token
import howdy/auth/internal/types.{
  type ProviderOutcome, type ProviderStart, ProviderLinked, ProviderSecondFactor,
  ProviderSession, ProviderStart,
}
import howdy/auth/provider
import howdy/auth/secret
import howdy/auth/user.{type Principal, type User, Acting, System}
import howdy/service
import howdy/trace

/// Install a built-in provider. Duplicate IDs and issuers are rejected.
pub fn add(
  config: Config,
  provider: provider.Provider,
) -> service.Result(Config) {
  use _ <- result.try(provider.validate(provider))
  let issuer = provider.issuer(provider)
  case
    list.any(config.providers, fn(p) { provider.id(p) == provider.id(provider) }),
    option.is_some(issuer)
    && list.any(config.providers, fn(p) { provider.issuer(p) == issuer })
  {
    True, _ -> Error(service.Invalid("provider is already configured"))
    _, True ->
      Error(service.Invalid("another provider already uses this issuer"))
    False, False ->
      Ok(Config(..config, providers: list.append(config.providers, [provider])))
  }
}

fn configured(config: Config, id: String) -> service.Result(provider.Provider) {
  list.find(config.providers, fn(p) { provider.id(p) == id })
  |> result.replace_error(service.NotFound("provider"))
}

/// Conservative paths for callback mounts and fixed post-login destinations.
pub fn provider_path(path: String) -> Bool {
  string.starts_with(path, "/")
  && !string.starts_with(path, "//")
  && list.all(string.to_graphemes(path), fn(c) {
    string.contains(
      "/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-",
      c,
    )
  })
}

// -- Beginning ----------------------------------------------------------------

pub fn begin(
  config: Config,
  id: String,
  callback_path: String,
  client: String,
) -> service.Result(ProviderStart) {
  use provider <- result.try(configured(config, id))
  begin_attempt(config, provider, callback_path, client, None)
}

pub fn begin_link(
  config: Config,
  principal: Principal,
  id: String,
  callback_path: String,
) -> service.Result(ProviderStart) {
  use principal <- result.try(session_flow.fresh_principal(config, principal))
  use provider <- result.try(configured(config, id))
  begin_attempt(
    config.in_group(config, principal.user.group_id),
    provider,
    callback_path,
    principal.client,
    Some(principal),
  )
}

/// Record a browser-bound attempt and build the URL to send it to.
pub fn begin_attempt(
  config: Config,
  provider: provider.Provider,
  callback_path: String,
  client: String,
  linking: Option(Principal),
) -> service.Result(ProviderStart) {
  let id = provider.id(provider)
  use _ <- result.try(case provider_path(callback_path) {
    True -> Ok(Nil)
    False -> Error(service.Invalid("invalid provider callback path"))
  })
  use within <- result.try(common.target(config, False))
  use _ <- result.try(common.existing(config, within))
  let state = token.new()
  let browser = token.new()
  let nonce = token.new()
  let verifier = token.new()
  let redirect_uri = config.origin <> callback_path
  let #(link_user, link_session) = case linking {
    Some(principal) -> #(principal.user.id, principal.session_id)
    None -> #("", "")
  }
  let attempt =
    provider_store.Attempt(
      id,
      token.digest(nonce),
      secret.wrap(verifier),
      redirect_uri,
      within,
      group.mode_name(config.groups),
      link_user,
      link_session,
      client,
    )
  // Built first: a provider configured by discovery can fail here, and then
  // no attempt should be left behind.
  use url <- result.try(provider.authorization_url(
    provider,
    provider.Authorization(redirect_uri, state, nonce, token.digest(verifier)),
  ))
  use _ <- result.try({
    use conn <- db.write_transaction(
      config.repo,
      touching: "howdy_auth_provider_attempts",
    )
    provider_store.insert(conn, state, browser, attempt)
  })
  Ok(ProviderStart(url, secret.wrap(browser)))
}

// -- Finishing ----------------------------------------------------------------

pub fn finish(
  config: Config,
  id: String,
  callback_path: String,
  state: String,
  browser_token: String,
  code: Option(String),
  principal: Option(Principal),
) -> service.Result(ProviderOutcome) {
  use <- audit.traced("auth.finish_provider", [
    trace.string("auth.provider", id),
  ])
  use provider <- result.try(configured(config, id))
  use attempt <- result.try(consume_attempt(
    config,
    id,
    callback_path,
    state,
    browser_token,
  ))
  use code <- result.try(case code {
    Some(code) if code != "" -> Ok(code)
    _ -> Error(service.Unauthorized)
  })
  use identity <- result.try(provider.exchange(
    provider,
    provider.Exchange(
      secret.wrap(code),
      attempt.redirect_uri,
      attempt.verifier,
      attempt.nonce_digest,
    ),
  ))
  complete_identity(config, id, attempt, identity, principal, Public)
}

/// Spend the browser-bound attempt, whatever happens next, and confirm it was
/// begun under the group configuration that is finishing it.
pub fn consume_attempt(
  config: Config,
  id: String,
  callback_path: String,
  state: String,
  browser_token: String,
) -> service.Result(provider_store.Attempt) {
  use _ <- result.try(common.valid_token(state))
  use _ <- result.try(common.valid_token(browser_token))
  use attempt <- result.try({
    use conn <- db.transaction(config.repo)
    provider_store.consume(
      conn,
      state,
      browser_token,
      id,
      config.origin <> callback_path,
    )
  })
  use _ <- result.try(case attempt.mode == group.mode_name(config.groups) {
    True -> Ok(Nil)
    False -> Error(service.Unauthorized)
  })
  use _ <- result.try(case attempt.group_id {
    Some(g) -> common.in_bound_group(config, g)
    None -> Ok(Nil)
  })
  Ok(attempt)
}

/// What an identity nobody owns yet may become.
pub type Admission {
  /// A built-in provider: a new account if public registration is open, and
  /// never an existing one. Equal addresses alone attach nothing.
  Public
  /// An SSO connection, believed only about its own domains and group, which
  /// the attempt is already bound to. There it is the authority on who holds
  /// an address: the customer's administrator can read that mailbox anyway.
  /// So it takes up the existing account, and otherwise creates one whether
  /// or not registration is public. Without this, turning enforcement on, or
  /// moving to another provider, would lock out everyone who had not linked.
  /// `trusts_mfa` is whether its sign-ins stand without Howdy's second factor.
  Connection(trusts_mfa: Bool)
}

/// Apply local account policy to an identity the external party has already
/// proven. Nothing here depends on how it was proven, so every sign-in
/// protocol ends in this one place.
pub fn complete_identity(
  config: Config,
  id: String,
  attempt: provider_store.Attempt,
  identity: provider.Identity,
  principal: Option(Principal),
  admission: Admission,
) -> service.Result(ProviderOutcome) {
  // Revalidate after the network request: revocation while at Google must not
  // authorize linking, nor may another browser session take over.
  use linking <- result.try(case attempt.link_user, principal {
    "", _ -> Ok(None)
    user_id, Some(p)
      if p.user.id == user_id && p.session_id == attempt.link_session
    -> session_flow.fresh_principal(config, p) |> result.map(Some)
    _, _ -> Error(service.Unauthorized)
  })
  let scope = case config.groups {
    AccountPerGroup -> option.unwrap(attempt.group_id, "")
    _ -> ""
  }
  use completed <- result.try({
    use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
    use owner <- result.try(provider_store.owner(
      conn,
      identity.issuer,
      identity.subject,
      scope,
    ))
    case linking {
      Some(p) -> {
        use users <- result.try(store.active_user(
          conn,
          p.user.id,
          locking: True,
        ))
        use user <- result.try(case users {
          [u] if u.group_id == p.user.group_id -> Ok(u)
          _ -> Error(service.Unauthorized)
        })
        use _ <- result.try(case attempt.group_id {
          Some(g) if g == user.group_id -> Ok(Nil)
          _ -> Error(service.Unauthorized)
        })
        use _ <- result.try(session_flow.current_account(conn, config, p, True))
        use _ <- result.try(provider_store.attach(
          conn,
          identity.issuer,
          identity.subject,
          scope,
          user.id,
          id,
        ))
        use _ <- result.try(audit.event(
          conn,
          user.id,
          "provider.linked",
          Acting(p),
          id,
        ))
        Ok(None)
      }
      None -> {
        use user <- result.try(case owner {
          Some(user_id) -> {
            use users <- result.try(store.active_user(
              conn,
              user_id,
              locking: True,
            ))
            // Unlink may have won the user lock after the first owner lookup.
            // Never recreate a link from a callback that observed its old owner.
            use still_owner <- result.try(provider_store.owner(
              conn,
              identity.issuer,
              identity.subject,
              scope,
            ))
            case users, still_owner {
              [u], Some(current) if current == user_id -> Ok(u)
              _, _ -> Error(service.Unauthorized)
            }
          }
          None -> admit_user(conn, config, attempt, identity, admission, id)
        })
        use _ <- result.try(common.in_bound_group(config, user.group_id))
        use _ <- result.try(case attempt.group_id {
          Some(g) if g != user.group_id -> Error(service.Unauthorized)
          _ -> Ok(Nil)
        })
        use _ <- result.try(provider_store.attach(
          conn,
          identity.issuer,
          identity.subject,
          scope,
          user.id,
          id,
        ))
        case admission {
          Connection(trusts_mfa: True) ->
            session_flow.issue_trusting_provider(
              conn,
              config,
              user,
              id,
              attempt.client,
            )
          _ ->
            session_flow.issue_session(
              conn,
              config,
              user,
              Provider(id),
              attempt.client,
            )
        }
        |> result.map(Some)
      }
    }
  })
  case completed {
    Some(Pending(challenge)) -> Ok(ProviderSecondFactor(challenge))
    Some(issued) ->
      session_flow.publish(config, issued) |> result.map(ProviderSession)
    None -> Ok(ProviderLinked)
  }
}

fn admit_user(
  conn: Repo,
  config: Config,
  attempt: provider_store.Attempt,
  identity: provider.Identity,
  admission: Admission,
  id: String,
) -> service.Result(User) {
  // Third-party Google addresses first register/verify by email, then link.
  let open = case admission {
    Public -> config.registration
    Connection(_) -> True
  }
  use _ <- result.try(case identity.email_authoritative {
    True -> Ok(Nil)
    False -> Error(service.Forbidden)
  })
  use email <- result.try(address.normalize_email(identity.email))
  use existing <- result.try(case admission {
    Public -> Ok([])
    Connection(_) -> store.active_user_by_email(conn, email, attempt.group_id)
  })
  case existing, open {
    [user], _ -> {
      use _ <- result.try(audit.event_from(
        conn,
        user.id,
        "provider.linked",
        System,
        id,
        attempt.client,
      ))
      Ok(user)
    }
    [], True -> {
      use _ <- result.try(account_flow.enroll(
        conn,
        config,
        email,
        attempt.group_id,
        attempt.client,
      ))
      use users <- result.try(store.active_user_by_email(
        conn,
        email,
        attempt.group_id,
      ))
      case users {
        [user] -> Ok(user)
        _ -> Error(service.Unauthorized)
      }
    }
    _, _ -> Error(service.Forbidden)
  }
}
