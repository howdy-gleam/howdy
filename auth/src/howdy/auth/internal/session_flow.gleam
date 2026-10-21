//// Sessions: issuing one once a sign-in has been proven, authenticating a
//// token on each request, listing and revoking, suspension, impersonation,
//// and `current_account`, the row-locked re-check every account mutation
//// starts from. `howdy/auth` is the public face.

import gleam/http
import gleam/http/request.{type Request}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import gloo/repo.{type Repo}
import howdy/auth/connection
import howdy/auth/internal/account_store
import howdy/auth/internal/audit
import howdy/auth/internal/cache
import howdy/auth/internal/common
import howdy/auth/internal/config.{type Config, External, InDatabase}
import howdy/auth/internal/connection_store
import howdy/auth/internal/database as db
import howdy/auth/internal/labels.{
  type Method, EmailToken, Impersonation, Passkey, Password, Provider,
}
import howdy/auth/internal/origin
import howdy/auth/internal/rate_limit_store
import howdy/auth/internal/security_store
import howdy/auth/internal/store
import howdy/auth/internal/token
import howdy/auth/internal/types.{
  type LoginStep, type MfaChallenge, type Session, type SessionInfo,
  MfaChallenge, SecondFactor, Session, SessionInfo, SignedIn,
}
import howdy/auth/secret
import howdy/auth/session_store.{type Entry, Entry}
import howdy/auth/user.{
  type Actor, type Principal, type User, Acting, Principal, System,
}
import howdy/context.{type Body, type Context}
import howdy/service
import howdy/trace

/// Last use is recorded at most this often, keeping reads read-only.
const touch_seconds = 60

// -- Issuing ------------------------------------------------------------------

/// A session the database has committed to, and the entry an external store
/// has yet to be given.
pub type Issued {
  Issued(session: Session, entry: Entry)
  Pending(challenge: MfaChallenge)
}

pub fn issue_session(
  conn: Repo,
  config: Config,
  user: User,
  method: Method,
  client: String,
) -> service.Result(Issued) {
  use _ <- result.try(sso_permits(conn, user, labels.method_name(method)))
  use factor <- result.try(security_store.factor(conn, user.id))
  case factor {
    None ->
      issue_verified_session(
        conn,
        config,
        user,
        labels.method_name(method),
        client,
      )
    Some(_) -> {
      use _ <- result.try(common.mfa_config(config))
      let challenge = token.new()
      use version <- result.try(account_store.version(conn, user.id))
      use _ <- result.try(security_store.add_pending(
        conn,
        token.digest(challenge),
        security_store.Pending(
          user.id,
          version,
          user.group_id,
          labels.method_name(method),
          client,
          "",
          0,
        ),
      ))
      Ok(Pending(MfaChallenge(secret.wrap(challenge))))
    }
  }
}

/// A session for a connection whose provider's MFA is trusted. The method is
/// the provider alone, never "mfa:": the Howdy factor was not proven, so the
/// session cannot manage it. Skipping a factor the user has is audited.
pub fn issue_trusting_provider(
  conn: Repo,
  config: Config,
  user: User,
  id: String,
  client: String,
) -> service.Result(Issued) {
  use factor <- result.try(security_store.factor(conn, user.id))
  use _ <- result.try(case factor {
    None -> Ok(Nil)
    Some(_) ->
      audit.event_from(
        conn,
        user.id,
        "mfa.provider_trusted",
        System,
        id,
        client,
      )
  })
  issue_verified_session(
    conn,
    config,
    user,
    labels.method_name(Provider(id)),
    client,
  )
}

/// A member covered by an enforced SSO connection signs in through it and no
/// other way. Every sign-in ends at a session, so this is the one gate. The
/// refusal is Unauthorized, as for a wrong credential: a right password must
/// not be distinguishable from a wrong one by an account that may not use it.
/// It reads no SSO configuration, so enforcement holds (and covered members
/// are locked out, visibly) if a deployment forgets `with_sso`.
fn sso_permits(conn: Repo, user: User, method: String) -> service.Result(Nil) {
  use enforcing <- result.try(connection_store.enforcing(
    conn,
    user.email,
    Some(user.group_id),
  ))
  case enforcing {
    None -> Ok(Nil)
    Some(id) -> {
      let first = labels.first_factor(method)
      case
        first == labels.method_name(Provider(connection.identity_issuer(id)))
      {
        True -> Ok(Nil)
        False -> Error(service.Unauthorized)
      }
    }
  }
}

pub fn issue_verified_session(
  conn: Repo,
  config: Config,
  user: User,
  method: String,
  client: String,
) -> service.Result(Issued) {
  // Again here: a second factor may finish after enforcement began.
  use _ <- result.try(sso_permits(conn, user, method))
  create_session(conn, config, user, method, client)
}

/// Record a session for a user whose right to one has been established.
fn create_session(
  conn: Repo,
  config: Config,
  user: User,
  method: String,
  client: String,
) -> service.Result(Issued) {
  let now = token.now()
  let session =
    Session(user, secret.wrap(token.new()), now + config.policy.session_seconds)
  use version <- result.try(account_store.version(conn, user.id))
  let entry =
    Entry(
      digest: token.digest(secret.reveal(session.token)),
      user_id: user.id,
      method: method,
      created_at: now,
      last_seen_at: now,
      expires_at: session.expires_at,
      client:,
      version:,
    )
  use _ <- result.try(case config.sessions {
    InDatabase ->
      store.insert_session(
        conn,
        digest: entry.digest,
        user_id: entry.user_id,
        method: entry.method,
        now:,
        expires_at: entry.expires_at,
        client:,
      )
    External(_) -> Ok(Nil)
  })
  use _ <- result.try(audit.event_from(
    conn,
    user.id,
    "session.created",
    System,
    method,
    client,
  ))
  Ok(Issued(session, entry))
}

/// Hand a committed session to the external store, if there is one.
pub fn publish(config: Config, issued: Issued) -> service.Result(Session) {
  case issued {
    Pending(_) -> Error(service.Forbidden)
    Issued(session, entry) ->
      case config.sessions {
        InDatabase -> Ok(session)
        External(external) -> external.insert(entry) |> result.replace(session)
      }
  }
}

pub fn publish_step(
  config: Config,
  issued: Issued,
) -> service.Result(LoginStep) {
  case issued {
    Pending(challenge) -> Ok(SecondFactor(challenge))
    Issued(_, _) -> publish(config, issued) |> result.map(SignedIn)
  }
}

// -- Authenticating -----------------------------------------------------------

pub fn authenticate_from(
  config: Config,
  secret: String,
  client: String,
) -> service.Result(Principal) {
  use _ <- result.try(common.valid_token(secret))
  let authenticated = authenticate_digest(config, token.digest(secret), client)
  // Say whose request this is on the request's span.
  case authenticated {
    Ok(principal) ->
      trace.set_attributes([trace.string("enduser.id", principal.user.id)])
    Error(_) -> Nil
  }
  authenticated
}

pub fn authenticate_digest(
  config: Config,
  digest: String,
  client: String,
) -> service.Result(Principal) {
  let now = token.now()
  let seen_after = case config.policy.session_idle_seconds {
    0 -> -1
    idle -> now - idle
  }
  let touch_due = fn(last_seen_at) { last_seen_at <= now - touch_seconds }
  // Renewal rides on the throttled touch, so it costs no further writes. The
  // expiry was last set `session_seconds` before it falls due; one that is
  // already later than renewal would make it (a lowered policy) is kept.
  let renewed = fn(created_at, expires_at) {
    let policy = config.policy
    let due =
      policy.session_renew_seconds > 0
      && expires_at - now
      <= policy.session_seconds - policy.session_renew_seconds
    let target = case policy.session_max_seconds {
      0 -> now + policy.session_seconds
      max -> int.min(now + policy.session_seconds, created_at + max)
    }
    case due {
      True -> int.max(expires_at, target)
      False -> expires_at
    }
  }
  use user <- result.try(case config.sessions {
    InDatabase -> {
      use conn <- db.connect(config.repo)
      use found <- result.try(store.session_user(conn, digest, now, seen_after))
      case found {
        [#(user, last_seen_at, created_at, expires_at)] ->
          case touch_due(last_seen_at) {
            True ->
              store.touch_session(
                conn,
                digest,
                now,
                renewed(created_at, expires_at),
              )
            False -> Ok(Nil)
          }
          |> result.replace(user)
        _ -> Error(service.Unauthorized)
      }
    }
    External(external) -> {
      use entry <- result.try(external.get(digest))
      use entry <- result.try(case entry {
        Some(entry)
          if entry.expires_at > now && entry.last_seen_at > seen_after
        -> Ok(entry)
        _ -> Error(service.Unauthorized)
      })
      // The store says who; the database says whether they still may.
      use users <- result.try(
        db.connect(config.repo, store.active_user_version(
          _,
          entry.user_id,
          locking: False,
        )),
      )
      case users {
        [#(user, version)] if version == entry.version ->
          case touch_due(entry.last_seen_at) {
            True ->
              external.touch(
                digest,
                now,
                renewed(entry.created_at, entry.expires_at),
              )
            False -> Ok(Nil)
          }
          |> result.replace(user)
        _ -> Error(service.Unauthorized)
      }
    }
  })
  use _ <- result.try(common.in_bound_group(config, user.group_id))
  Ok(Principal(user, digest, client))
}

/// The request guard behind `howdy/auth.required_from`.
pub fn required_from(
  config: Config,
  key: fn(Context(a)) -> Option(String),
) -> fn(Context(a)) -> service.Result(Principal) {
  fn(ctx: Context(a)) {
    let client = option.unwrap(key(ctx), "")
    let headers =
      list.filter(ctx.request.headers, fn(h) {
        string.lowercase(h.0) == "authorization"
      })
    let cookies =
      request.get_cookies(ctx.request)
      |> list.filter(fn(c) { c.0 == common.cookie_name(config) })
    case headers, cookies {
      [#(_, "Bearer " <> secret)], [] ->
        authenticate_from(config, secret, client)
      [], [#(_, secret)] -> {
        use _ <- result.try(case ctx.request.method {
          http.Get | http.Head | http.Options -> Ok(Nil)
          _ -> origin.check(config.origin, ctx)
        })
        authenticate_from(config, secret, client)
      }
      _, _ -> Error(service.Unauthorized)
    }
  }
}

/// The principal for a request's session cookie, without the origin check a
/// write would need: only for reading, such as the user's locale.
pub fn cookie_principal(
  config: Config,
  request: Request(Body),
) -> service.Result(Principal) {
  case
    request.get_cookies(request)
    |> list.filter(fn(c) { c.0 == common.cookie_name(config) })
  {
    [#(_, secret)] -> authenticate_from(config, secret, "")
    _ -> Error(service.Unauthorized)
  }
}

/// The principal again, only if its session was created recently enough to
/// take a sensitive step such as linking a provider.
pub fn fresh_principal(
  config: Config,
  principal: Principal,
) -> service.Result(Principal) {
  use current <- result.try(authenticate_digest(
    config,
    principal.session_id,
    principal.client,
  ))
  use sessions <- result.try(sessions(config, current))
  case
    current.user.id == principal.user.id
    && list.any(sessions, fn(s) {
      s.current
      && s.created_at >= token.now() - config.policy.fresh_session_seconds
    })
  {
    True -> Ok(current)
    False -> Error(service.Forbidden)
  }
}

// -- Listing and revoking -----------------------------------------------------

pub fn logout(config: Config, principal: Principal) -> service.Result(Nil) {
  use _ <- result.try(
    common.externally(config, fn(external) {
      external.delete(principal.session_id, principal.user.id)
    }),
  )
  use conn <- db.transaction(config.repo)
  use _ <- result.try(store.delete_session(
    conn,
    principal.session_id,
    principal.user.id,
  ))
  audit.event(conn, principal.user.id, "session.revoked", Acting(principal), "")
}

pub fn sessions(
  config: Config,
  principal: Principal,
) -> service.Result(List(SessionInfo)) {
  use listed <- result.try(sessions_of(config, principal.user.id))
  Ok(
    list.map(listed, fn(session) {
      SessionInfo(..session, current: session.id == principal.session_id)
    }),
  )
}

pub fn sessions_of(
  config: Config,
  user_id: String,
) -> service.Result(List(SessionInfo)) {
  let now = token.now()
  use rows <- result.try(case config.sessions {
    InDatabase ->
      db.connect(config.repo, store.sessions_for_user(_, user_id, now))
    External(external) -> {
      use entries <- result.try(external.list(user_id))
      use version <- result.try(
        db.connect(config.repo, account_store.version(_, user_id)),
      )
      entries
      |> list.filter(fn(entry) {
        entry.expires_at > now && entry.version == version
      })
      |> list.sort(fn(a, b) {
        int.compare(b.created_at, a.created_at)
        |> order.break_tie(string.compare(a.digest, b.digest))
      })
      |> list.map(fn(entry) {
        store.SessionRow(
          digest: entry.digest,
          method: entry.method,
          created_at: entry.created_at,
          last_seen_at: entry.last_seen_at,
          expires_at: entry.expires_at,
          client: entry.client,
        )
      })
      |> Ok
    }
  })
  Ok(
    list.map(rows, fn(row) {
      SessionInfo(
        id: row.digest,
        method: labels.method_from(row.method),
        created_at: row.created_at,
        last_seen_at: row.last_seen_at,
        expires_at: row.expires_at,
        current: False,
        client: row.client,
      )
    }),
  )
}

pub fn revoke_session_of(
  config: Config,
  user_id: String,
  session_id: String,
  actor: Actor,
) -> service.Result(Nil) {
  use _ <- result.try(
    common.externally(config, fn(external) {
      external.delete(session_id, user_id)
    }),
  )
  use conn <- db.transaction(config.repo)
  use _ <- result.try(store.require_user(conn, user_id))
  use _ <- result.try(store.delete_session(conn, session_id, user_id))
  audit.event(conn, user_id, "session.revoked", actor, "")
}

pub fn revoke_session(
  config: Config,
  principal: Principal,
  session_id: String,
) -> service.Result(Nil) {
  use _ <- result.try(
    common.externally(config, fn(external) {
      external.delete(session_id, principal.user.id)
    }),
  )
  use conn <- db.transaction(config.repo)
  use _ <- result.try(store.delete_session(conn, session_id, principal.user.id))
  audit.event(conn, principal.user.id, "session.revoked", Acting(principal), "")
}

pub fn revoke_sessions(
  config: Config,
  user_id: String,
  actor: Actor,
) -> service.Result(Nil) {
  use <- common.after_commit(config, fn(external) {
    external.delete_for_user(user_id, None)
  })
  use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
  use _ <- result.try(store.require_user(conn, user_id))
  use _ <- result.try(store.delete_sessions(conn, user_id))
  audit.event(conn, user_id, "sessions.revoked", actor, "")
}

pub fn suspend(
  config: Config,
  user_id: String,
  actor: Actor,
) -> service.Result(Nil) {
  use <- common.after_commit(config, fn(external) {
    external.delete_for_user(user_id, None)
  })
  // Runs in the process holding the transaction: the dirty flag is
  // process-local (see `cache.changing`).
  use <- cache.changing
  use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
  use _ <- result.try(store.require_user(conn, user_id))
  use _ <- result.try(store.set_suspended(conn, user_id, True))
  use _ <- result.try(store.delete_sessions(conn, user_id))
  use _ <- result.try(store.delete_challenges_for_user(conn, user_id))
  use _ <- result.try(account_store.clear_pending(conn, user_id))
  audit.event(conn, user_id, "user.suspended", actor, "")
}

pub fn resume(
  config: Config,
  user_id: String,
  actor: Actor,
) -> service.Result(Nil) {
  // A suspension whose external revocation failed must not come back to life.
  use _ <- result.try(
    common.externally(config, fn(external) {
      external.delete_for_user(user_id, None)
    }),
  )
  // Runs in the process holding the transaction: the dirty flag is
  // process-local (see `cache.changing`).
  use <- cache.changing
  use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
  use _ <- result.try(store.require_user(conn, user_id))
  use _ <- result.try(store.set_suspended(conn, user_id, False))
  audit.event(conn, user_id, "user.resumed", actor, "")
}

pub fn impersonate(
  config: Config,
  user_id: String,
  actor: Actor,
) -> service.Result(Session) {
  use issued <- result.try({
    use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
    use users <- result.try(store.active_user(conn, user_id, locking: True))
    use user <- result.try(case users {
      [value] -> Ok(value)
      _ -> Error(service.NotFound("user"))
    })
    use _ <- result.try(common.in_bound_group(config, user.group_id))
    use _ <- result.try(audit.event(
      conn,
      user.id,
      "session.impersonated",
      actor,
      "",
    ))
    create_session(
      conn,
      config,
      user,
      labels.method_name(Impersonation),
      user.actor_client(actor),
    )
  })
  publish(config, issued)
}

// -- Housekeeping -------------------------------------------------------------

pub fn prune_expired(config: Config) -> service.Result(Nil) {
  use _ <- result.try(
    common.externally(config, fn(external) { external.prune(token.now()) }),
  )
  use conn <- db.transaction(config.repo)
  use _ <- result.try(rate_limit_store.delete_expired(conn, token.now() * 1000))
  store.delete_expired(conn, token.now(), config.policy)
}

pub fn prune_events(config: Config, before: Int) -> service.Result(Nil) {
  use conn <- db.transaction(config.repo)
  store.delete_events_before(conn, before)
}

// -- The current account ------------------------------------------------------

/// Re-read the account under its row lock, then check the exact session against
/// current state. A Principal is a snapshot, not authority to mutate forever.
pub fn current_account(
  conn: Repo,
  config: Config,
  principal: Principal,
  fresh: Bool,
) -> service.Result(#(User, Method)) {
  use users <- result.try(store.active_user_version(
    conn,
    principal.user.id,
    locking: True,
  ))
  use #(user, version) <- result.try(case users {
    [found] -> Ok(found)
    _ -> Error(service.Unauthorized)
  })
  use _ <- result.try(common.in_bound_group(config, user.group_id))
  let now = token.now()
  use row <- result.try(case config.sessions {
    InDatabase -> {
      use rows <- result.try(store.session_for_user(
        conn,
        user.id,
        principal.session_id,
        now,
      ))
      case rows {
        [row] -> Ok(row)
        _ -> Error(service.Unauthorized)
      }
    }
    External(external) -> {
      use found <- result.try(external.get(principal.session_id))
      case found {
        Some(entry) if entry.user_id == user.id && entry.version == version ->
          Ok(store.SessionRow(
            entry.digest,
            entry.method,
            entry.created_at,
            entry.last_seen_at,
            entry.expires_at,
            entry.client,
          ))
        _ -> Error(service.Unauthorized)
      }
    }
  })
  use _ <- result.try(
    case
      row.expires_at > now
      && {
        config.policy.session_idle_seconds == 0
        || row.last_seen_at > now - config.policy.session_idle_seconds
      }
    {
      True -> Ok(Nil)
      False -> Error(service.Unauthorized)
    },
  )
  use _ <- result.try(
    case !fresh || row.created_at > now - config.policy.fresh_session_seconds {
      True -> Ok(Nil)
      False -> Error(service.Forbidden)
    },
  )
  let method = labels.method_from(row.method)
  use enabled <- result.try(case method {
    Passkey ->
      case config.passkeys {
        None -> Ok(False)
        Some(_) ->
          security_store.passkeys(conn, user.id)
          |> result.map(fn(keys) { keys != [] })
      }
    EmailToken -> Ok(config.email_tokens)
    Impersonation -> Ok(False)
    Password ->
      case config.passwords {
        None -> Ok(False)
        Some(_) -> account_store.has_password(conn, user.id)
      }
    Provider(id) -> {
      use links <- result.try(account_store.linked(conn, user.id))
      use enabled <- result.try(common.provider_enabled(conn, config, id))
      Ok(enabled && list.any(links, fn(link) { link.0 == id }))
    }
  })
  case enabled {
    True -> Ok(#(user, method))
    False -> Error(service.Forbidden)
  }
}

/// The stored method of the caller's own session, for flows that need to
/// know whether it passed a second factor.
pub fn session_method(
  conn: Repo,
  config: Config,
  principal: Principal,
  user: User,
) -> service.Result(String) {
  case config.sessions {
    InDatabase -> {
      use rows <- result.try(store.session_for_user(
        conn,
        user.id,
        principal.session_id,
        token.now(),
      ))
      case rows {
        [row] -> Ok(row.method)
        _ -> Error(service.Unauthorized)
      }
    }
    External(store) -> {
      use entry <- result.try(store.get(principal.session_id))
      case entry {
        Some(entry) -> Ok(entry.method)
        None -> Error(service.Unauthorized)
      }
    }
  }
}
