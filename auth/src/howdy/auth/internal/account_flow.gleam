//// The account itself: enrolment and provisioning, changing the address,
//// linked providers, deletion, and the multi-session cookie a browser holds
//// several accounts in. `howdy/auth` is the public face.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gloo/repo.{type Repo}
import howdy/auth/field.{type Change}
import howdy/auth/group.{Single}
import howdy/auth/internal/account_store
import howdy/auth/internal/address
import howdy/auth/internal/audit
import howdy/auth/internal/cache
import howdy/auth/internal/common
import howdy/auth/internal/config.{type Config}
import howdy/auth/internal/database as db
import howdy/auth/internal/labels.{
  EmailChange, EmailChangeApproval, EmailChanged, Provider,
}
import howdy/auth/internal/session_flow
import howdy/auth/internal/store
import howdy/auth/internal/token
import howdy/auth/internal/types.{type Delivery, type Session}
import howdy/auth/secret
import howdy/auth/user.{type Actor, type Principal, type User, Acting, System}
import howdy/service

// -- Enrolment ----------------------------------------------------------------

/// Registration through a redeemed challenge, if registration is open.
pub fn register(
  conn: Repo,
  config: Config,
  id: Option(String),
  email: String,
  within: Option(String),
  client: String,
) -> service.Result(Nil) {
  use _ <- result.try(case config.registration {
    True -> Ok(Nil)
    False -> Error(service.Forbidden)
  })
  enroll_as(
    conn,
    config,
    option.lazy_unwrap(id, token.new),
    email,
    within,
    client,
  )
}

/// Registration itself, once the caller has decided it is allowed.
pub fn enroll(
  conn: Repo,
  config: Config,
  email: String,
  within: Option(String),
  client: String,
) -> service.Result(Nil) {
  enroll_as(conn, config, token.new(), email, within, client)
}

fn enroll_as(
  conn: Repo,
  config: Config,
  id: String,
  email: String,
  within: Option(String),
  client: String,
) -> service.Result(Nil) {
  // A token from before groups existed names none.
  use group_id <- result.try(case config.groups, within {
    _, Some(id) -> Ok(id)
    Single, None -> Ok(group.default_id)
    _, None -> Error(service.Unauthorized)
  })
  // Locked, so the group cannot be deleted before the user is in it.
  use found <- result.try(store.find_group(conn, group_id))
  use _ <- result.try(case found {
    [_] -> Ok(Nil)
    _ -> Error(service.Unauthorized)
  })
  let login_key = group.login_key(config.groups, group_id, email)
  use taken <- result.try(store.login_key_taken(conn, login_key))
  use _ <- result.try(case taken {
    False -> Ok(Nil)
    True -> Error(service.Unauthorized)
  })
  use _ <- result.try(store.insert_user(
    conn,
    id:,
    email:,
    group_id:,
    login_key:,
    locale: config.locale,
  ))
  audit.event_from(conn, id, "user.registered", System, group_id, client)
}

pub fn provision_with(
  config: Config,
  email: String,
  changes: List(Change),
  actor: Actor,
) -> service.Result(User) {
  use email <- result.try(address.normalize_email(email))
  use within <- result.try(common.target(config, True))
  let group_id = option.unwrap(within, group.default_id)
  use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
  // Locked, so the group cannot be deleted before the user is in it.
  use found <- result.try(store.find_group(conn, group_id))
  use _ <- result.try(case found {
    [_] -> Ok(Nil)
    _ -> Error(service.NotFound("group"))
  })
  let login_key = group.login_key(config.groups, group_id, email)
  use taken <- result.try(store.login_key_taken(conn, login_key))
  use _ <- result.try(case taken {
    False -> Ok(Nil)
    True ->
      Error(service.Coded(
        "email_taken",
        service.Conflict("an account already exists for this address"),
      ))
  })
  use writes <- result.try(field.writes(changes, Some(group_id)))
  let id = token.new()
  use created <- result.try(store.insert_user(
    conn,
    id:,
    email:,
    group_id:,
    login_key:,
    locale: config.locale,
  ))
  use _ <- result.try(case writes {
    [] -> Ok(Nil)
    _ ->
      store.write_fields(conn, store.of_user, id, writes)
      |> result.replace(Nil)
  })
  use _ <- result.try(audit.event(conn, id, "user.provisioned", actor, group_id))
  Ok(created)
}

// -- Email change -------------------------------------------------------------

// Approval tokens live in the same table as confirmation tokens. Hashing them
// under a prefix keeps the two apart: neither can be redeemed as the other.
fn approval_digest(secret: String) -> String {
  token.digest("email-change-approval:" <> secret)
}

pub fn request_email_change(
  config: Config,
  principal: Principal,
  email: String,
) -> service.Result(Nil) {
  use _ <- result.try(common.require_email_tokens(config))
  use email <- result.try(address.normalize_email(email))
  let secret = token.new()
  let digest = case config.email_change_approval {
    True -> approval_digest(secret)
    False -> token.digest(secret)
  }
  use user <- result.try({
    use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
    use #(user, _) <- result.try(session_flow.current_account(
      conn,
      config,
      principal,
      True,
    ))
    use _ <- result.try(available_email(conn, config, user, email))
    // Bound both a caller changing destinations and many callers targeting one
    // mailbox. Reservations and the pending change commit together.
    use _ <- result.try(store.reserve_email(
      conn,
      token.keyed_digest(config.throttle_key, "email-change-user:" <> user.id),
      token.now(),
      config.policy,
    ))
    use _ <- result.try(store.reserve_email(
      conn,
      token.keyed_digest(config.throttle_key, "email-change-target:" <> email),
      token.now(),
      config.policy,
    ))
    use _ <- result.try(account_store.request_email(
      conn,
      user.id,
      principal.session_id,
      digest,
      account_store.EmailChange(
        user.email,
        email,
        user.group_id,
        group.mode_name(config.groups),
      ),
      token.now() + config.policy.challenge_seconds,
    ))
    use _ <- result.try(audit.event(
      conn,
      user.id,
      "email.change_requested",
      Acting(principal),
      "",
    ))
    Ok(user)
  })
  deliver_email_change(config, digest, case config.email_change_approval {
    True ->
      common.delivery(
        config,
        user.email,
        secret,
        EmailChangeApproval,
        None,
        common.recipient_locale(config, user.locale),
      )
    False ->
      common.delivery(
        config,
        email,
        secret,
        EmailChange,
        None,
        common.recipient_locale(config, user.locale),
      )
  })
}

fn deliver_email_change(
  config: Config,
  digest: String,
  delivery: Delivery,
) -> service.Result(Nil) {
  case config.deliver(delivery) {
    Ok(Nil) -> Ok(Nil)
    Error(Nil) -> {
      let _ = db.connect(config.repo, account_store.discard_email(_, digest))
      Error(service.Internal("auth email delivery failed"))
    }
  }
}

pub fn approve_email_change(
  config: Config,
  principal: Principal,
  secret: String,
) -> service.Result(Nil) {
  use _ <- result.try(common.require_email_tokens(config))
  use _ <- result.try(case config.email_change_approval {
    True -> Ok(Nil)
    False -> Error(service.Forbidden)
  })
  use _ <- result.try(common.valid_token(secret))
  use change <- result.try({
    use conn <- db.transaction(config.repo)
    account_store.consume_email(
      conn,
      principal.user.id,
      principal.session_id,
      approval_digest(secret),
    )
  })
  let confirmation = token.new()
  use _ <- result.try({
    use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
    use #(user, _) <- result.try(session_flow.current_account(
      conn,
      config,
      principal,
      True,
    ))
    use _ <- result.try(unchanged_since(config, user, change))
    use _ <- result.try(available_email(conn, config, user, change.new_email))
    use _ <- result.try(account_store.request_email(
      conn,
      user.id,
      principal.session_id,
      token.digest(confirmation),
      change,
      token.now() + config.policy.challenge_seconds,
    ))
    audit.event(conn, user.id, "email.change_approved", Acting(principal), "")
  })
  deliver_email_change(
    config,
    token.digest(confirmation),
    common.delivery(
      config,
      change.new_email,
      confirmation,
      EmailChange,
      None,
      common.recipient_locale(config, principal.user.locale),
    ),
  )
}

fn unchanged_since(
  config: Config,
  user: User,
  change: account_store.EmailChange,
) -> service.Result(Nil) {
  case
    user.email == change.old_email
    && user.group_id == change.group_id
    && group.mode_name(config.groups) == change.mode
  {
    True -> Ok(Nil)
    False -> Error(service.Forbidden)
  }
}

fn available_email(
  conn: Repo,
  config: Config,
  user: User,
  email: String,
) -> service.Result(Nil) {
  use _ <- result.try(case user.email == email {
    True ->
      Error(service.Coded(
        "email_unchanged",
        service.Invalid("choose a different email address"),
      ))
    False -> Ok(Nil)
  })
  use taken <- result.try(store.login_key_taken(
    conn,
    group.login_key(config.groups, user.group_id, email),
  ))
  case taken {
    True ->
      Error(service.Coded(
        "email_taken",
        service.Conflict("email address is unavailable"),
      ))
    False -> Ok(Nil)
  }
}

pub fn confirm_email_change(
  config: Config,
  principal: Principal,
  secret: String,
) -> service.Result(Nil) {
  use _ <- result.try(common.require_email_tokens(config))
  use _ <- result.try(common.valid_token(secret))
  use change <- result.try({
    use conn <- db.transaction(config.repo)
    account_store.consume_email(
      conn,
      principal.user.id,
      principal.session_id,
      token.digest(secret),
    )
  })
  // The notice follows the commit even when external session cleanup fails.
  use <- common.after_commit(config, fn(external) {
    external.delete_for_user(principal.user.id, None)
  })
  use _ <- result.try({
    use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
    use #(user, _) <- result.try(session_flow.current_account(
      conn,
      config,
      principal,
      True,
    ))
    use _ <- result.try(unchanged_since(config, user, change))
    use _ <- result.try(available_email(conn, config, user, change.new_email))
    use _ <- result.try(store.delete_challenges_for_user(conn, user.id))
    use _ <- result.try(account_store.change_email(
      conn,
      user.id,
      change.new_email,
      group.login_key(config.groups, user.group_id, change.new_email),
    ))
    // Challenges for the new address may predate this change too.
    use _ <- result.try(store.delete_challenges_for_user(conn, user.id))
    use _ <- result.try(account_store.clear_pending(conn, user.id))
    use _ <- result.try(account_store.revoke(conn, user.id))
    audit.event(conn, user.id, "email.changed", Acting(principal), "")
  })
  let _ =
    config.deliver(common.delivery(
      config,
      change.old_email,
      "",
      EmailChanged,
      None,
      common.recipient_locale(config, principal.user.locale),
    ))
  Ok(Nil)
}

// -- Linked providers ---------------------------------------------------------

pub fn linked_providers(
  config: Config,
  principal: Principal,
) -> service.Result(List(#(String, String))) {
  use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
  use #(user, _) <- result.try(session_flow.current_account(
    conn,
    config,
    principal,
    False,
  ))
  account_store.linked(conn, user.id)
}

pub fn unlink_provider(
  config: Config,
  principal: Principal,
  issuer: String,
) -> service.Result(Nil) {
  use <- common.after_commit(config, fn(external) {
    external.delete_for_user(principal.user.id, None)
  })
  use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
  use #(user, method) <- result.try(session_flow.current_account(
    conn,
    config,
    principal,
    True,
  ))
  use links <- result.try(account_store.linked(conn, user.id))
  use removed <- result.try(
    list.find(links, fn(link) { link.1 == issuer })
    |> result.replace_error(service.NotFound("provider link")),
  )
  use _ <- result.try(case method == Provider(removed.0) {
    True -> Error(service.Forbidden)
    False -> Ok(Nil)
  })
  use _ <- result.try(account_store.unlink(conn, user.id, issuer))
  use _ <- result.try(account_store.clear_pending(conn, user.id))
  use _ <- result.try(account_store.revoke(conn, user.id))
  audit.event(conn, user.id, "provider.unlinked", Acting(principal), removed.0)
}

// -- Deletion -----------------------------------------------------------------

pub fn delete_account(
  config: Config,
  principal: Principal,
  confirm_email: String,
) -> service.Result(Nil) {
  use cleanup <- result.try(case config.before_delete {
    Some(cleanup) -> Ok(cleanup)
    None -> Error(service.Forbidden)
  })
  use confirm_email <- result.try(address.normalize_email(confirm_email))
  use <- common.after_commit(config, fn(external) {
    external.delete_for_user(principal.user.id, None)
  })
  // Runs in the process holding the transaction: the dirty flag is
  // process-local (see `cache.changing`).
  use <- cache.changing
  use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
  use #(user, _) <- result.try(session_flow.current_account(
    conn,
    config,
    principal,
    True,
  ))
  use _ <- result.try(case user.email == confirm_email {
    True -> Ok(Nil)
    False ->
      Error(service.Coded(
        "email_mismatch",
        service.Invalid("confirm your current email address"),
      ))
  })
  use _ <- result.try(cleanup(conn, user))
  use _ <- result.try(store.delete_challenges_for_user(conn, user.id))
  use _ <- result.try(account_store.clear_pending(conn, user.id))
  use _ <- result.try(account_store.delete(conn, user.id))
  audit.event(conn, user.id, "user.deleted", Acting(principal), "")
}

pub fn delete_user(
  config: Config,
  user_id: String,
  actor: Actor,
) -> service.Result(Nil) {
  use cleanup <- result.try(case config.before_delete {
    Some(cleanup) -> Ok(cleanup)
    None -> Error(service.Forbidden)
  })
  use <- common.after_commit(config, fn(external) {
    external.delete_for_user(user_id, None)
  })
  // Runs in the process holding the transaction: the dirty flag is
  // process-local (see `cache.changing`).
  use <- cache.changing
  use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
  use users <- result.try(store.find_user(conn, user_id))
  use user <- result.try(case users {
    [user] -> Ok(user)
    _ -> Error(service.NotFound("user"))
  })
  use _ <- result.try(common.in_bound_group(config, user.group_id))
  use _ <- result.try(cleanup(conn, user))
  use _ <- result.try(store.delete_challenges_for_user(conn, user.id))
  use _ <- result.try(account_store.clear_pending(conn, user.id))
  use _ <- result.try(account_store.delete(conn, user.id))
  audit.event(conn, user.id, "user.deleted", actor, "")
}

// -- Multi-session ------------------------------------------------------------

/// The session tokens that still authenticate, in the order given, each with
/// its principal. Anything else is dropped without error.
pub fn device_sessions(
  config: Config,
  tokens: List(String),
  client: String,
) -> List(#(String, Principal)) {
  list.unique(tokens)
  |> list.take(10)
  |> list.filter_map(fn(secret) {
    session_flow.authenticate_from(config, secret, client)
    |> result.map(fn(principal) { #(secret, principal) })
  })
}

/// The tokens a browser should hold after signing in to `session`: the live
/// ones it had, then the new one. An earlier session of the same user is
/// revoked and replaced, and so are the oldest beyond the configured maximum.
pub fn add_device_session(
  config: Config,
  tokens: List(String),
  session: Session,
  client: String,
) -> List(String) {
  let new = secret.reveal(session.token)
  let #(replaced, others) =
    device_sessions(config, tokens, client)
    |> list.filter(fn(entry) { entry.0 != new })
    |> list.partition(fn(entry) { { entry.1 }.user.id == session.user.id })
  let room = option.unwrap(config.multi_session, 1) - 1
  let evicted = list.take(others, int.max(0, list.length(others) - room))
  list.each(list.append(replaced, evicted), fn(entry) {
    session_flow.logout(config, entry.1)
  })
  list.drop(others, list.length(evicted))
  |> list.map(fn(entry) { entry.0 })
  |> list.append([new])
}

// -- Locale -------------------------------------------------------------------

pub fn set_locale(
  config: Config,
  principal: Principal,
  locale: Option(String),
) -> service.Result(Nil) {
  use conn <- db.write_transaction(config.repo, touching: "howdy_auth_users")
  use _ <- result.try(store.set_locale(conn, principal.user.id, locale))
  audit.event(
    conn,
    principal.user.id,
    "user.locale_changed",
    Acting(principal),
    option.unwrap(locale, ""),
  )
}
