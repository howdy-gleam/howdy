//// Email-token, password and built-in provider authentication. This package owns its tables; applications
//// keep small facts in `howdy/auth/field` and anything relational in their own tables.
//// Authorization lives in howdy/authorization.
////
//// This module is the public face. Each flow is implemented under
//// `howdy/auth/internal`: `config` holds the configuration record and its one
//// constructor, `email_flow`, `password_flow`, `provider_flow`, `sso_flow`,
//// `passkey_flow`, `mfa_flow`, `account_flow` and `session_flow` hold the
//// operations, `labels` the stored method and ceremony names, and `common`
//// what several flows share. The types here are the ones applications see;
//// the flows return their `internal/types` twins, converted at this boundary.

import howdy/auth/secret

import gleam/http/request.{type Request}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gloo/repo.{type Repo}
import howdy/auth/connection
import howdy/auth/field.{type Change}
import howdy/auth/group.{type Mode}
import howdy/auth/internal/account_flow
import howdy/auth/internal/address
import howdy/auth/internal/audit
import howdy/auth/internal/common
import howdy/auth/internal/config.{type Config, Config}
import howdy/auth/internal/email_flow
import howdy/auth/internal/labels
import howdy/auth/internal/mfa_flow
import howdy/auth/internal/origin as origin_check
import howdy/auth/internal/passkey_flow
import howdy/auth/internal/password as password_hash
import howdy/auth/internal/password_flow
import howdy/auth/internal/provider_flow
import howdy/auth/internal/rate_limit_store
import howdy/auth/internal/session_flow
import howdy/auth/internal/sso_flow
import howdy/auth/internal/types
import howdy/auth/mfa
import howdy/auth/passkey
import howdy/auth/password_hasher.{type PasswordHasher}
import howdy/auth/policy.{type Policy}
import howdy/auth/provider
import howdy/auth/session_store.{type SessionStore}
import howdy/auth/user.{type Actor, type Principal, type User}
import howdy/context.{type Body, type Context}
import howdy/locale.{type Locale, type Negotiator}
import howdy/migration
import howdy/rate_limit
import howdy/service

pub type Intent {
  Login
  Register
}

/// What the email should tell its reader. Derived from the request and from
/// whether the address already has an account; the HTTP response is the same
/// either way, so this reveals nothing to anyone but the inbox owner.
pub type Purpose {
  /// Sign in to the account that already owns this address.
  SignIn
  /// Create the account that redeeming this token will verify.
  Registration
  /// Someone asked to register an address that already has an account. Say so
  /// rather than inviting them to register again: redeeming the token signs
  /// that existing account in, and no password from the request was kept.
  AlreadyRegistered
  /// Confirm a change of the signed-in account’s email, not a login token.
  EmailChange
  /// Sent to the CURRENT address when `with_email_change_approval` is on:
  /// someone signed in asked to move the account to another address. The token
  /// approves that on the account page; it cannot sign in. Tell a reader who
  /// did not ask to ignore it and secure the account.
  EmailChangeApproval
  /// A notice to the OLD address: the account now signs in with a different
  /// one. `token` is empty. Tell a reader who did not do this to contact
  /// support, because this mailbox can no longer recover the account.
  EmailChanged
  /// A notice, not a request: the account's password was just replaced using
  /// its current password. `token` is empty. Tell the reader to reset the
  /// password from a fresh email login if this was not them.
  PasswordChanged
}

/// Deliver the token privately. Never log it or expose it in a public response.
/// The token expires after `policy.challenge_seconds` (ten minutes by default)
/// and must be exchanged via POST.
pub type Delivery {
  Delivery(
    email: String,
    token: secret.Secret,
    purpose: Purpose,
    /// With `with_email_links`, a page URL that fills in `token` for its
    /// reader to confirm. `None` for notices, which carry no token.
    link: Option(secret.Secret),
    /// With `with_email_codes`, a six-digit code that signs in like `token`
    /// when entered with this address. Only for `SignIn`, `Registration` and
    /// `AlreadyRegistered`, and only until three wrong guesses.
    code: Option(secret.Secret),
    /// The locale to write the email in, as a BCP 47 tag: the recipient's
    /// own if they chose or registered with one, otherwise the locale of
    /// the request that caused the email; `None` when neither is known.
    /// See `with_locales`.
    locale: Option(String),
  )
}

/// The configured authentication runtime. Construct with `new` or
/// `new_without_email`, then the `with_*` builders. The record itself lives in
/// `howdy/auth/internal/config`, where every flow reads it.
pub opaque type Auth {
  Auth(config: Config)
}

/// How a session was authenticated.
pub type Method {
  EmailToken
  Password
  Provider(id: String)
  Passkey
  /// Issued by `impersonate` for an operator, never by a credential.
  Impersonation
}

/// Returned by a successful sign-in. Keep the token secret. Browser
/// routes put it in an HttpOnly cookie; native API clients use Bearer auth.
pub type Session {
  Session(user: User, token: secret.Secret, expires_at: Int)
}

/// One of a user's live sessions. `id` identifies it for `revoke_session`;
/// it is a digest and cannot be used to authenticate.
pub type SessionInfo {
  SessionInfo(
    id: String,
    method: Method,
    created_at: Int,
    last_seen_at: Int,
    expires_at: Int,
    current: Bool,
    /// Where the session was created from, as the transport reported it.
    /// Empty when it did not report one.
    client: String,
  )
}

pub fn schema() -> migration.Package {
  config.schema()
}

/// Accept an already-configured Gloo Repo; the application owns its lifecycle.
/// Construct once after running migrations. HTTPS is required except for
/// loopback development origins. Origin must contain only scheme/host/port.
pub fn new(
  repo repo: Repo,
  origin origin: String,
  deliver deliver: fn(Delivery) -> Result(Nil, Nil),
) -> service.Result(Auth) {
  use origin <- result.try(address.canonical_origin(origin))
  config.new(repo:, origin:, deliver: delivering(deliver))
  |> result.map(Auth)
}

/// Keep sessions in a store of your own instead of the auth database; see
/// `howdy/auth/session_store`. Construct once at startup. Sessions are not
/// copied between stores, so changing store signs everyone out.
///
/// Users, credentials and suspension stay in the database, and every request
/// still confirms there that the session's user is active, so a suspended
/// user is refused even if the store still holds their sessions. What changes
/// is atomicity. The database commits first and the store is written second,
/// so if the store fails in between, the operation returns its error with
/// the database change already made: a registration or sign-in without a
/// session (request another token), or a suspension, `revoke_sessions` or
/// `set_password` whose sessions are not yet removed (call it again, or
/// `revoke_sessions`).
pub fn with_session_store(auth: Auth, store: SessionStore) -> Auth {
  Auth(Config(..auth.config, sessions: config.External(store)))
}

/// Choose how users relate to groups; see `howdy/auth/group`. Construct once
/// at startup, like the rest of the configuration:
///
/// ```gleam
/// let assert Ok(identity) = auth.new(repo:, origin:, deliver:)
/// let assert Ok(identity) = auth.with_groups(identity, group.OneGroupPerUser)
/// ```
///
/// The choice is recorded in the database, and an installation that never
/// calls this keeps whatever was recorded, `Single` to begin with. Choosing a
/// different mode converts the installation in one transaction, or refuses
/// with Conflict when the users already there do not fit it: `Single` needs
/// everyone in the default group, and leaving `AccountPerGroup` needs no
/// address to have accounts in two groups. Sessions survive a conversion;
/// emailed tokens not yet redeemed do not. Change modes with every other
/// node stopped, since a running node keeps the mode it started with.
pub fn with_groups(auth: Auth, mode: Mode) -> service.Result(Auth) {
  config.with_groups(auth.config, mode) |> result.map(Auth)
}

pub fn group_mode(auth: Auth) -> Mode {
  auth.config.groups
}

/// The same configuration, acting in one group. Token requests, registration
/// and password login made through the returned value apply to that group,
/// and it authenticates only that group's users, so
/// `auth.required(auth.in_group(identity, id))` guards a group's routes.
///
/// `AccountPerGroup` needs this for every sign-in and registration, because
/// an address alone does not name an account. `OneGroupPerUser` needs it to
/// register, which is how a new user's group is chosen; signing in works
/// without it. `Single` never needs it. It costs nothing: call it per request.
pub fn in_group(auth: Auth, group_id: String) -> Auth {
  Auth(config.in_group(auth.config, group_id))
}

@internal
pub fn repo(auth: Auth) -> Repo {
  auth.config.repo
}

/// The group chosen with `in_group`, if any.
@internal
pub fn bound_group(auth: Auth) -> Option(String) {
  auth.config.group
}

// -- Locales -------------------------------------------------------------------

/// Write the bundled pages and emails in the locales `negotiator` supports,
/// detecting each request's locale the way it says. Without this they are
/// in English. Translations ship for en, ar, de, es, fr, it, ja, nl, pl, pt
/// and zh; any other supported locale falls back along its parents, and
/// then to English.
///
/// ```gleam
/// let locales =
///   locale.negotiator(["en", "de", "fr"], default: "en")
///   |> locale.from(auth.locale_source(identity))
///   |> locale.from_cookie("locale")
///   |> locale.from_accept_language
/// let identity = auth.with_locales(identity, locales)
/// ```
///
/// A new account remembers the locale of the request that registered it,
/// and its emails use that locale from then on; see `set_locale`.
pub fn with_locales(auth: Auth, negotiator: Negotiator) -> Auth {
  Auth(Config(..auth.config, locales: negotiator))
}

/// The negotiator given to `with_locales`.
pub fn locales(auth: Auth) -> Negotiator {
  auth.config.locales
}

/// The locale `with_locales` chooses for a request.
pub fn request_locale(auth: Auth, ctx: Context(a)) -> Locale {
  locale.detect(ctx, auth.config.locales)
}

/// The same configuration, acting for a request in `locale`, a BCP 47 tag.
/// An account registered through the returned value remembers the locale,
/// and emails sent through it use the locale unless their recipient has one
/// of their own. The bundled routes call this for every request; call it
/// per request in routes of your own.
pub fn in_locale(auth: Auth, locale: String) -> Auth {
  Auth(Config(..auth.config, locale: Some(locale)))
}

/// Set, or with `None` clear, the locale the signed-in user's pages and
/// emails use. A tag the negotiator from `with_locales` does not support
/// is refused.
pub fn set_locale(
  auth: Auth,
  principal: Principal,
  locale tag: Option(String),
) -> service.Result(Nil) {
  use tag <- result.try(case tag {
    None -> Ok(None)
    Some(tag) ->
      case locale.parse(tag) {
        Ok(parsed) ->
          case list.contains(locale.supported(auth.config.locales), parsed) {
            True -> Ok(Some(locale.to_string(parsed)))
            False ->
              Error(service.Coded(
                "locale_unsupported",
                service.Invalid("unsupported locale"),
              ))
          }
        Error(Nil) ->
          Error(service.Coded(
            "locale_unsupported",
            service.Invalid("unsupported locale"),
          ))
      }
  })
  account_flow.set_locale(auth.config, principal, tag)
}

/// A source for `locale.from` that answers the signed-in user's own
/// locale, from their session cookie. Bearer tokens are not read: API
/// clients say what they want with `accept-language`.
pub fn locale_source(auth: Auth) -> fn(Request(Body)) -> Option(String) {
  fn(request) {
    session_flow.cookie_principal(auth.config, request)
    |> option.from_result
    |> option.then(fn(principal: Principal) { principal.user.locale })
  }
}

/// Enable password registration and login, hashed with PBKDF2-HMAC-SHA256
/// (see `howdy/auth/password_hasher`). Construct once at startup. Email
/// tokens remain available; this is an additional method, not a second factor.
pub fn with_passwords(auth: Auth) -> service.Result(Auth) {
  with_password_hasher(auth, password_hasher.pbkdf2_sha256())
}

/// Enable passwords as `with_passwords` does, storing them with another
/// algorithm. Existing credentials must be readable by `hasher`: Howdy does
/// not fall back to the built-in one.
pub fn with_password_hasher(
  auth: Auth,
  hasher: PasswordHasher,
) -> service.Result(Auth) {
  use passwords <- result.try(password_hash.new(hasher))
  Ok(Auth(Config(..auth.config, passwords: Some(passwords))))
}

/// Replace the default limits and lifetimes. See `howdy/auth/policy`.
pub fn with_policy(auth: Auth, policy: Policy) -> service.Result(Auth) {
  use policy <- result.try(policy.validate(policy))
  Ok(Auth(Config(..auth.config, policy:)))
}

pub fn policy(auth: Auth) -> Policy {
  auth.config.policy
}

/// Supplement the built-in common-password check with a local breached-password
/// corpus or a privacy-preserving service. Receives NFC-normalized new passwords
/// only. Errors fail closed; never log this argument or send plaintext remotely.
pub fn with_password_check(
  auth: Auth,
  check: fn(String) -> service.Result(Nil),
) -> Auth {
  Auth(Config(..auth.config, password_check: check))
}

pub fn passwords_enabled(auth: Auth) -> Bool {
  auth.config.passwords != None
}

/// Public registration is disabled unless explicitly enabled.
pub fn allow_registration(auth: Auth) -> Auth {
  Auth(Config(..auth.config, registration: True))
}

pub fn registration_enabled(auth: Auth) -> Bool {
  auth.config.registration
}

pub fn origin(auth: Auth) -> String {
  auth.config.origin
}

pub fn secure(auth: Auth) -> Bool {
  common.secure(auth.config)
}

/// Max-Age for the session cookie. Without renewal it matches the session. With
/// it the cookie must outlive any one expiry, so it lasts to
/// `policy.session_max_seconds`, or the 400 days browsers allow when there is
/// no ceiling. The cookie only carries the token; expiry is decided here.
pub fn session_cookie_seconds(auth: Auth) -> Int {
  let policy = auth.config.policy
  case policy.session_renew_seconds, policy.session_max_seconds {
    0, _ -> policy.session_seconds
    _, 0 -> 34_560_000
    _, max -> int.min(max, 34_560_000)
  }
}

/// Let one browser hold several signed-in accounts and switch between them.
/// Signing in while signed in then adds an account instead of replacing the
/// session; signing out returns to another account that is still signed in.
/// `max` accounts per browser, from 2 to 10: signing in to one more signs the
/// oldest out. Only the cookie transport changes. Every account remains an
/// ordinary session that is listed, renewed, expired and revoked as any other,
/// and bearer clients are unaffected.
pub fn with_multi_session(auth: Auth, max max: Int) -> service.Result(Auth) {
  case max >= 2 && max <= 10 {
    True -> Ok(Auth(Config(..auth.config, multi_session: Some(max))))
    False ->
      Error(service.Invalid("multi-session allows 2 to 10 accounts per browser"))
  }
}

/// The most accounts one browser may hold, when multi-session is on.
pub fn multi_session(auth: Auth) -> Option(Int) {
  auth.config.multi_session
}

/// The second cookie of a multi-session browser: every session token it holds,
/// the active one included, joined by `.`. It is as sensitive as the session
/// cookie and takes the same options.
pub fn accounts_cookie_name(auth: Auth) -> String {
  case secure(auth) {
    True -> "__Host-howdy_accounts"
    False -> "howdy_dev_accounts"
  }
}

/// The session tokens that still authenticate, in the order given, each with
/// its principal. Anything else is dropped without error: expired, revoked,
/// suspended or malformed entries are what a long-lived cookie accumulates.
pub fn device_sessions(
  auth: Auth,
  tokens: List(String),
  client: String,
) -> List(#(String, Principal)) {
  account_flow.device_sessions(auth.config, tokens, client)
}

/// The tokens a browser should hold after signing in to `session`: the live
/// ones it had, then the new one. An earlier session of the same user is
/// revoked and replaced, and so are the oldest beyond the configured maximum.
pub fn add_device_session(
  auth: Auth,
  tokens: List(String),
  session: Session,
  client: String,
) -> List(String) {
  account_flow.add_device_session(
    auth.config,
    tokens,
    types.Session(session.user, session.token, session.expires_at),
    client,
  )
}

pub fn cookie_name(auth: Auth) -> String {
  common.cookie_name(auth.config)
}

/// Headless operation for custom UI or another transport. Delivery is
/// identical for known and unknown addresses; account eligibility is checked
/// at exchange. This shares one client bucket with every other headless
/// caller; pass the request's client to `request_token_from` instead.
pub fn request_token(
  auth: Auth,
  email: String,
  intent: Intent,
) -> service.Result(Nil) {
  request_token_from(auth, email, intent, "headless")
}

/// As `request_token`, with the requesting client for throttling and audit.
///
/// A request that finds a usable token already waiting for that address sends
/// no second email and still reports success, because one is already in the
/// inbox. That is deliberate: it means a third party asking for tokens can
/// neither flood the inbox nor stop its owner from receiving one, since every
/// request leaves the owner holding exactly one live token. Tune the window
/// with `policy.email_coalesce_margin_seconds`.
pub fn request_token_from(
  auth: Auth,
  email: String,
  intent: Intent,
  client: String,
) -> service.Result(Nil) {
  email_flow.request_challenge(
    auth.config,
    email,
    case intent {
      Login -> labels.Login
      Register -> labels.Register
    },
    client,
    email_flow.TokenOnly,
  )
}

/// Register with an email address and password. The email challenge must be
/// exchanged before the account or credential becomes usable. Never replaces
/// an existing user's credential or attaches one based only on email equality.
/// Shares one headless client bucket; prefer `register_password_from`.
pub fn register_password(
  auth: Auth,
  email: String,
  password: String,
) -> service.Result(Nil) {
  register_password_from(auth, email, password, "headless")
}

/// As `register_password`, with the requesting client for throttling and audit.
pub fn register_password_from(
  auth: Auth,
  email: String,
  password: String,
  client: String,
) -> service.Result(Nil) {
  password_flow.register(auth.config, email, password, client)
}

/// Consume a challenge, verify/create the account and issue a session. The
/// token is spent first, in its own transaction: it can create at most one
/// session even under concurrency, and an exchange that then fails (account
/// exists, suspended, method disabled) does not leave it usable.
pub fn exchange(auth: Auth, secret: String) -> service.Result(Session) {
  exchange_from(auth, secret, "")
}

/// As `exchange`, recording the requesting client on the new session and on
/// the audit events the exchange writes.
pub fn exchange_from(
  auth: Auth,
  secret: String,
  client: String,
) -> service.Result(Session) {
  use <- audit.traced("auth.exchange", [])
  email_flow.redeem(auth.config, secret, client)
  |> result.try(session_flow.publish(auth.config, _))
  |> result.map(session)
}

/// Authenticate by email and password. Wrong, unknown, email-only and suspended
/// accounts all receive Unauthorized. This compatibility entry point uses a
/// shared headless client bucket. Custom transports should isolate clients with
/// `login_password_from` and enforce their own overall client/load limits.
pub fn login_password(
  auth: Auth,
  email: String,
  password: String,
) -> service.Result(Session) {
  login_password_from(auth, email, password, "headless")
}

/// Use a trusted, stable client identity (normally the socket IP or an ingress
/// header) to isolate password back-off. The compatibility wrapper shares a
/// headless bucket; custom transports should call this operation instead.
pub fn login_password_from(
  auth: Auth,
  email: String,
  password: String,
  client: String,
) -> service.Result(Session) {
  use <- audit.traced("auth.login_password", [])
  password_flow.verify(auth.config, email, password, client)
  |> result.try(session_flow.publish(auth.config, _))
  |> result.map(session)
}

/// Set, replace or reset the caller's password. One operation covers all three
/// because the proof is the same: the session must have been created by an
/// email-token exchange within `policy.fresh_session_seconds`. A password
/// session or an older session receives Forbidden; request a login token,
/// exchange it, then call this. Every other session of the user is revoked.
pub fn set_password(
  auth: Auth,
  principal: Principal,
  password: String,
) -> service.Result(Nil) {
  password_flow.set(auth.config, principal, password)
}

/// Replace the caller's password by proving the current one. Unlike
/// `set_password` this needs no fresh email login, so it also serves
/// deployments without email tokens. A wrong current password is Invalid, not
/// Unauthorized: the session itself is still good. Guesses spend the same
/// per-client and per-address budget as password logins, so a borrowed session
/// cannot search for the password faster than the login form could. An account
/// without a password receives Forbidden and must use `set_password`.
///
/// Every other session and remembered device of the user is revoked, and the
/// address is sent a `PasswordChanged` notice on a best-effort basis.
pub fn change_password(
  auth: Auth,
  principal: Principal,
  current current: String,
  new new: String,
) -> service.Result(Nil) {
  change_password_from(auth, principal, current, new, "headless")
}

/// As `change_password`, isolating back-off by a trusted client identity; see
/// `login_password_from`.
pub fn change_password_from(
  auth: Auth,
  principal: Principal,
  current current: String,
  new new: String,
  client client: String,
) -> service.Result(Nil) {
  password_flow.change(auth.config, principal, current, new, client)
}

/// Privileged operation: create a user without asking them, for an
/// invitation, an import or a directory sync. Authorize the caller first. It
/// works whether or not public registration is enabled, and sends nothing:
/// the user signs in with a login token when they are ready, which is also
/// what proves the address is theirs. The group is chosen as for
/// registration, so outside `Single` use `auth.in_group`:
///
/// ```gleam
/// auth.provision(auth.in_group(identity, "acme"), email, by: user.System)
/// ```
///
/// Conflict when the address already has an account where it must be unique.
pub fn provision(
  auth: Auth,
  email: String,
  by actor: Actor,
) -> service.Result(User) {
  provision_with(auth, email, fields: [], by: actor)
}

/// As `provision`, setting fields on the new user in the same transaction;
/// see `howdy/auth/field`. Conflict when a unique value is taken.
pub fn provision_with(
  auth: Auth,
  email: String,
  fields changes: List(Change),
  by actor: Actor,
) -> service.Result(User) {
  account_flow.provision_with(auth.config, email, changes, actor)
}

/// Verify a session token. The returned principal records no client, so audit
/// events it causes do not say where the request came from; prefer
/// `authenticate_from`, or `required`, which reads it from the request.
pub fn authenticate(auth: Auth, secret: String) -> service.Result(Principal) {
  authenticate_from(auth, secret, "")
}

/// As `authenticate`, recording the requesting client on the principal so the
/// operations it performs are audited with it.
pub fn authenticate_from(
  auth: Auth,
  secret: String,
  client: String,
) -> service.Result(Principal) {
  session_flow.authenticate_from(auth.config, secret, client)
}

/// A typed controller/endpoint guard. Ambiguous credentials are rejected.
/// Cookie-authenticated writes require the configured Origin, protecting
/// application routes as well as the module's own routes against CSRF.
/// Audit events record the socket address; behind a proxy that is the proxy
/// for everyone, so use `required_from` with the header your ingress sets.
pub fn required(auth: Auth) -> fn(Context(a)) -> service.Result(Principal) {
  required_from(auth, fn(ctx: Context(a)) { context.client_ip(ctx.request) })
}

/// As `required`, identifying the client with `key`. Only read a header your
/// ingress overwrites; a client-supplied value can claim to be anyone.
pub fn required_from(
  auth: Auth,
  key: fn(Context(a)) -> Option(String),
) -> fn(Context(a)) -> service.Result(Principal) {
  session_flow.required_from(auth.config, key)
}

/// Require an exact, single Origin. The configured origin is never inferred
/// from Host or forwarded headers.
pub fn check_origin(auth: Auth, ctx: Context(a)) -> service.Result(Nil) {
  origin_check.check(auth.config.origin, ctx)
}

pub fn logout(auth: Auth, principal: Principal) -> service.Result(Nil) {
  session_flow.logout(auth.config, principal)
}

/// The caller's own live sessions, newest first.
pub fn sessions(
  auth: Auth,
  principal: Principal,
) -> service.Result(List(SessionInfo)) {
  session_flow.sessions(auth.config, principal)
  |> result.map(list.map(_, session_info))
}

/// A user's live sessions, newest first, for operators and management
/// consoles. Privileged: authorize the caller first. No session is marked
/// `current`, since the caller is not the user.
pub fn sessions_of(
  auth: Auth,
  user_id: String,
) -> service.Result(List(SessionInfo)) {
  session_flow.sessions_of(auth.config, user_id)
  |> result.map(list.map(_, session_info))
}

/// Revoke one of a user's sessions by `SessionInfo.id`, as an operator.
/// Privileged: authorize the caller first. An unknown id is not an error.
pub fn revoke_session_of(
  auth: Auth,
  user_id: String,
  session_id: String,
  by actor: Actor,
) -> service.Result(Nil) {
  session_flow.revoke_session_of(auth.config, user_id, session_id, actor)
}

/// Revoke one of the caller's own sessions by `SessionInfo.id`. Another
/// user's session is never affected; an unknown id is not an error.
pub fn revoke_session(
  auth: Auth,
  principal: Principal,
  session_id: String,
) -> service.Result(Nil) {
  session_flow.revoke_session(auth.config, principal, session_id)
}

/// Privileged operation: authorize the caller before invoking it.
pub fn revoke_sessions(
  auth: Auth,
  user_id: String,
  by actor: Actor,
) -> service.Result(Nil) {
  session_flow.revoke_sessions(auth.config, user_id, actor)
}

/// Privileged operation. Suspension revokes all sessions atomically; resuming
/// the user never restores old sessions.
pub fn suspend(
  auth: Auth,
  user_id: String,
  by actor: Actor,
) -> service.Result(Nil) {
  session_flow.suspend(auth.config, user_id, actor)
}

/// Privileged operation: authorize the caller before invoking it.
pub fn resume(
  auth: Auth,
  user_id: String,
  by actor: Actor,
) -> service.Result(Nil) {
  session_flow.resume(auth.config, user_id, actor)
}

/// A session for `user_id` without a credential, for operators and
/// development tooling that act as a user. Privileged: authorize the caller
/// before invoking it, and never expose it over an unauthenticated route.
/// The session's method is `Impersonation`, and the audit trail records
/// `session.impersonated` with the actor. It skips second factors and SSO
/// enforcement, which is why it must not be reachable by the user. Suspended
/// users cannot be impersonated.
pub fn impersonate(
  auth: Auth,
  user_id: String,
  by actor: Actor,
) -> service.Result(Session) {
  session_flow.impersonate(auth.config, user_id, actor) |> result.map(session)
}

/// Count the per-client limits of every auth route (`routes.api`,
/// `routes.providers`, `routes.sso`) in the auth database, so that nodes
/// behind a load balancer share them and a restart does not reset them. Each
/// limited request then costs one write. Without this, each node counts on
/// its own. Needs migration **17**. Password, code and second-factor guessing
/// limits are always shared; this is the coarser per-client ceiling in front.
pub fn with_shared_rate_limits(auth: Auth) -> Auth {
  Auth(Config(..auth.config, rate_limits: Some(rate_limit_store(auth))))
}

/// As `with_shared_rate_limits`, counting in a store of your own, such as
/// Redis, instead of the auth database.
pub fn with_rate_limit_store(auth: Auth, store: rate_limit.Store) -> Auth {
  Auth(Config(..auth.config, rate_limits: Some(store)))
}

/// The auth database as a `rate_limit.Store`, for sharing the application's
/// own limiters between nodes too. Give each `rate_limit.shared` limiter a
/// name not starting `howdy_auth.`.
pub fn rate_limit_store(auth: Auth) -> rate_limit.Store {
  rate_limit_store.new(auth.config.repo)
}

/// A limiter for the auth routes: shared when configured, else this node's.
@internal
pub fn limiter(
  auth: Auth,
  name: String,
  limit: Int,
  per_seconds: Int,
) -> rate_limit.Limiter {
  case auth.config.rate_limits {
    Some(store) ->
      rate_limit.shared(
        limit:,
        per_seconds:,
        name: "howdy_auth." <> name,
        store:,
      )
    None -> rate_limit.fixed_window(limit:, per_seconds:)
  }
}

/// Housekeeping for a scheduled job. Expired rows are already removed as a
/// side effect of normal traffic; this covers quiet installations.
pub fn prune_expired(auth: Auth) -> service.Result(Nil) {
  session_flow.prune_expired(auth.config)
}

/// Apply an audit retention period: delete events that occurred before the
/// given Unix time in seconds. Export them first if they must be kept.
pub fn prune_events(auth: Auth, before before: Int) -> service.Result(Nil) {
  session_flow.prune_events(auth.config, before)
}

/// Record an audit event on the caller's connection, so it commits or rolls
/// back with the change it describes. The client is taken from the actor,
/// which for `Acting` is the principal's own request.
@internal
pub fn event(
  conn: Repo,
  user_id: String,
  action: String,
  actor: Actor,
  detail: String,
) -> service.Result(Nil) {
  audit.event(conn, user_id, action, actor, detail)
}

/// As `event`, for the self-service flows that know the request's client
/// before there is a principal to carry it.
@internal
pub fn event_from(
  conn: Repo,
  user_id: String,
  action: String,
  actor: Actor,
  detail: String,
  client: String,
) -> service.Result(Nil) {
  audit.event_from(conn, user_id, action, actor, detail, client)
}

/// Construct auth without email tokens. Add built-in providers with
/// `with_provider`. Registration remains disabled until explicitly enabled.
pub fn new_without_email(
  repo repo: Repo,
  origin origin: String,
) -> service.Result(Auth) {
  use auth <- result.try(new(repo, origin, fn(_) { Error(Nil) }))
  Ok(Auth(Config(..auth.config, email_tokens: False)))
}

/// Enable email tokens on a runtime constructed without email.
pub fn with_email_tokens(
  auth: Auth,
  deliver deliver: fn(Delivery) -> Result(Nil, Nil),
) -> Auth {
  Auth(Config(..auth.config, deliver: delivering(deliver), email_tokens: True))
}

pub fn email_tokens_enabled(auth: Auth) -> Bool {
  auth.config.email_tokens
}

/// Put a link in each emailed token's `Delivery`, beside the token, to the
/// starter pages mounted `at` this path, such as "/auth". A sign-in link opens
/// `<path>/login`; an email-change link opens `<path>/account`. The token
/// travels in the URL fragment (`#token=`, `#email-confirm=` or
/// `#email-approve=`), which browsers never send to a server, so it stays out
/// of access logs and `Referer` headers. The pages fill it in and wait for a
/// click, so a mail scanner that opens links spends nothing. Custom pages at
/// that path can read the same fragments.
pub fn with_email_links(auth: Auth, at path: String) -> service.Result(Auth) {
  case
    string.starts_with(path, "/")
    && !string.ends_with(path, "/")
    && list.all(string.to_graphemes(path), fn(c) {
      string.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/-_",
        c,
      )
    })
  {
    True -> Ok(Auth(Config(..auth.config, email_links: Some(path))))
    False ->
      Error(service.Invalid(
        "email link path must be absolute, without a trailing slash, using letters, digits, '/', '-' and '_'",
      ))
  }
}

/// Email a six-digit code beside each sign-in or registration token, for a
/// reader who would rather type than paste; see `exchange_code_step`. A code
/// is weaker than a token, so it only works with its address, dies after
/// three wrong guesses, and every guess counts against the same per-address
/// and per-client limits as a password. Anyone who can read the auth database
/// can recover a live code from its digest by trying all million, which a
/// token's digest does not allow; leave codes off if that matters.
pub fn with_email_codes(auth: Auth) -> Auth {
  Auth(Config(..auth.config, email_codes: True))
}

pub fn email_codes_enabled(auth: Auth) -> Bool {
  common.email_codes_enabled(auth.config)
}

/// Install a built-in provider once at startup. Duplicate IDs are rejected.
pub fn with_provider(
  auth: Auth,
  provider: provider.Provider,
) -> service.Result(Auth) {
  provider_flow.add(auth.config, provider) |> result.map(Auth)
}

/// The enabled provider IDs and display names, for custom sign-in pages.
pub fn providers(auth: Auth) -> List(#(String, String)) {
  list.map(auth.config.providers, fn(p) { #(provider.id(p), provider.name(p)) })
}

/// Store `browser_token` in a Secure, HttpOnly, SameSite=Lax cookie before
/// redirecting to `url`. Prefer `routes.providers`, which owns these details.
pub type ProviderStart {
  ProviderStart(url: String, browser_token: secret.Secret)
}

pub type ProviderOutcome {
  ProviderSession(Session)
  ProviderLinked
  ProviderSecondFactor(MfaChallenge)
}

/// Begin browser sign-in. `callback_path` is trusted application configuration,
/// never a request parameter. The attempt captures the current group selection.
pub fn begin_provider(
  auth: Auth,
  id: String,
  callback_path: String,
  client: String,
) -> service.Result(ProviderStart) {
  provider_flow.begin(auth.config, id, callback_path, client)
  |> result.map(provider_start)
}

/// Linking requires a live, recently created session. The callback must present
/// that same session as well as the browser token and Google's response.
pub fn begin_provider_link(
  auth: Auth,
  principal: Principal,
  id: String,
  callback_path: String,
) -> service.Result(ProviderStart) {
  provider_flow.begin_link(auth.config, principal, id, callback_path)
  |> result.map(provider_start)
}

/// Consume a browser-bound attempt, verify the external identity, and apply
/// local policy. `None` code means cancelled/denied consent and still spends the
/// attempt. Custom transports must enforce request limits. No Google token is
/// returned. Linking never changes the current session.
pub fn finish_provider(
  auth: Auth,
  id: String,
  callback_path: String,
  state: String,
  browser_token: String,
  code: Option(String),
  principal: Option(Principal),
) -> service.Result(ProviderOutcome) {
  provider_flow.finish(
    auth.config,
    id,
    callback_path,
    state,
    browser_token,
    code,
    principal,
  )
  |> result.map(provider_outcome)
}

/// Enable enterprise single sign-on connections; see `howdy/auth/connection`.
/// Construct once at startup, then manage them with `howdy/auth/connections`.
pub fn with_sso(auth: Auth, config: connection.Config) -> Auth {
  Auth(Config(..auth.config, sso: Some(config)))
}

pub fn sso_enabled(auth: Auth) -> Bool {
  option.is_some(auth.config.sso)
}

@internal
pub fn sso_config(auth: Auth) -> service.Result(connection.Config) {
  common.sso_config(auth.config)
}

/// Sign out every member a newly enforced connection covers, in the caller's
/// transaction and then in an external session store. Their next sign-in is
/// through the connection.
@internal
pub fn end_covered_sessions(
  auth: Auth,
  connection_id: String,
  commit: fn(Repo) -> service.Result(a),
) -> service.Result(a) {
  sso_flow.end_covered_sessions(auth.config, connection_id, commit)
}

/// The enabled connection that serves an address's domain, for a sign-in page
/// that asks for the address first. Which domains use SSO is not a secret: the
/// redirect that follows reveals it to anyone who asks.
pub fn sso_for_email(
  auth: Auth,
  email: String,
) -> service.Result(Option(String)) {
  sso_flow.for_email(auth.config, email)
}

/// Begin browser sign-in through an SSO connection, as `begin_provider` does
/// for a built-in provider. The user signs in to the connection's group.
pub fn begin_sso(
  auth: Auth,
  connection_id: String,
  callback_path: String,
  client: String,
) -> service.Result(ProviderStart) {
  sso_flow.begin(auth.config, connection_id, callback_path, client)
  |> result.map(provider_start)
}

/// As `begin_provider_link`. Only a member of the connection's group can link
/// to it.
pub fn begin_sso_link(
  auth: Auth,
  principal: Principal,
  connection_id: String,
  callback_path: String,
) -> service.Result(ProviderStart) {
  sso_flow.begin_link(auth.config, principal, connection_id, callback_path)
  |> result.map(provider_start)
}

/// As `finish_provider`. An identity the connection has not seen before
/// becomes a new account in the connection's group when its address is in the
/// connection's domains, whether or not public registration is enabled. It is
/// never attached to an existing account: that takes `begin_sso_link`.
pub fn finish_sso(
  auth: Auth,
  connection_id: String,
  callback_path: String,
  state: String,
  browser_token: String,
  code: Option(String),
  principal: Option(Principal),
) -> service.Result(ProviderOutcome) {
  sso_flow.finish(
    auth.config,
    connection_id,
    callback_path,
    state,
    browser_token,
    code,
    principal,
  )
  |> result.map(provider_outcome)
}

/// Conservative paths for callback mounts and fixed post-login destinations.
@internal
pub fn provider_path(path: String) -> Bool {
  provider_flow.provider_path(path)
}

/// Enable self-service deletion. The callback runs inside the deletion
/// transaction with its Repo and current user. Clean up application-owned rows
/// there, or return an error to veto deletion. Use only that Repo, not another
/// auth operation or external side effect. Foreign-key failures roll back all
/// database changes. Auth audit events are retained under the retention policy.
pub fn with_account_deletion(
  auth: Auth,
  before_delete: fn(Repo, User) -> service.Result(Nil),
) -> Auth {
  Auth(Config(..auth.config, before_delete: Some(before_delete)))
}

pub fn account_deletion_enabled(auth: Auth) -> Bool {
  option.is_some(auth.config.before_delete)
}

/// Require the CURRENT mailbox to approve an email change before the new one
/// is asked to confirm it. Without this, a hijacked fresh session can move the
/// account to a mailbox the attacker controls; with it, they also need the
/// owner's inbox. `request_email_change` then emails an `EmailChangeApproval`
/// token to the current address, and `approve_email_change` continues to the
/// usual `EmailChange` token. A user who has lost the old mailbox cannot change
/// address by themselves; trusted administration still can.
pub fn with_email_change_approval(auth: Auth) -> Auth {
  Auth(Config(..auth.config, email_change_approval: True))
}

pub fn email_change_approval_enabled(auth: Auth) -> Bool {
  auth.config.email_change_approval
}

/// Request proof of the new mailbox, or first of the current one under
/// `with_email_change_approval`. Requires an enabled email delivery flow and a
/// recent, live sign-in. Every later step must use the same session.
/// Only a digest is stored; the email change token cannot sign anyone in.
pub fn request_email_change(
  auth: Auth,
  principal: Principal,
  email: String,
) -> service.Result(Nil) {
  account_flow.request_email_change(auth.config, principal, email)
}

/// Redeem the token sent to the current address, from the requesting session,
/// then email the confirmation token to the new one. Single-use even on a later
/// failure. Forbidden unless `with_email_change_approval` is configured.
pub fn approve_email_change(
  auth: Auth,
  principal: Principal,
  secret: String,
) -> service.Result(Nil) {
  account_flow.approve_email_change(auth.config, principal, secret)
}

/// Confirm the new mailbox from the requesting session. Revalidates freshness,
/// account/group state and uniqueness, then signs out every session, including
/// this one. A correctly bound token is single-use even on a later failure.
/// The old address is sent an `EmailChanged` notice on a best-effort basis.
pub fn confirm_email_change(
  auth: Auth,
  principal: Principal,
  secret: String,
) -> service.Result(Nil) {
  account_flow.confirm_email_change(auth.config, principal, secret)
}

/// The caller's linked providers as #(provider id, issuer). Subjects and
/// provider tokens are not disclosed. Also includes disabled providers so
/// obsolete links can be removed using a different enabled sign-in method.
pub fn linked_providers(
  auth: Auth,
  principal: Principal,
) -> service.Result(List(#(String, String))) {
  account_flow.linked_providers(auth.config, principal)
}

/// Remove a provider by issuer. First sign in recently with a DIFFERENT enabled
/// method; that proves an alternative works, and prevents last-method lockout.
/// All sessions are revoked, including this one. A missing own link is NotFound.
pub fn unlink_provider(
  auth: Auth,
  principal: Principal,
  issuer: String,
) -> service.Result(Nil) {
  account_flow.unlink_provider(auth.config, principal, issuer)
}

/// Delete the caller after a recent sign-in and explicit confirmation of their
/// current address. Disabled until `with_account_deletion` is configured.
/// Credentials, fields, provider links, sessions and authz assignments cascade;
/// pending challenges are removed, and audit records follow their own retention.
pub fn delete_account(
  auth: Auth,
  principal: Principal,
  confirm_email confirm_email: String,
) -> service.Result(Nil) {
  account_flow.delete_account(auth.config, principal, confirm_email)
}

/// Delete a user's account as an operator: an erasure request, or a test
/// account in development. Privileged: authorize the caller first. Needs
/// `with_account_deletion`, whose callback cleans up application-owned rows
/// in the same transaction; without it, `Forbidden`. Suspended accounts can
/// be deleted. Every session and pending challenge ends with the account,
/// and the audit trail keeps `user.deleted` with the actor.
pub fn delete_user(
  auth: Auth,
  user_id: String,
  by actor: Actor,
) -> service.Result(Nil) {
  account_flow.delete_user(auth.config, user_id, actor)
}

// --- Passkeys and second factors --------------------------------------------

pub type MfaChallenge {
  MfaChallenge(token: secret.Secret)
}

pub type LoginStep {
  SignedIn(Session)
  SecondFactor(MfaChallenge)
}

pub type MfaMethod {
  Totp
  DeliveredCode
  RecoveryCode
}

pub type MfaSetup {
  MfaSetup(
    challenge: secret.Secret,
    key: Option(secret.Secret),
    uri: Option(secret.Secret),
    /// `uri` as a standalone SVG QR code for an authenticator app to scan.
    /// It contains the key: show it only to the user enrolling, never cache it.
    qr_code: Option(secret.Secret),
  )
}

pub type MfaSession {
  MfaSession(session: Session, trusted_device: Option(secret.Secret))
}

pub type PasskeyChallenge {
  PasskeyChallenge(challenge: secret.Secret, options: json.Json)
}

/// All nodes need the same stable encryption key. Removing this configuration
/// never bypasses MFA for an enrolled account; those sign-ins fail closed.
pub fn with_mfa(auth: Auth, config: mfa.Config) -> Auth {
  Auth(Config(..auth.config, mfa: Some(config)))
}

pub fn mfa_enabled(auth: Auth) -> Bool {
  option.is_some(auth.config.mfa)
}

/// Remembered-device lifetime in seconds, for transports setting the cookie.
pub fn mfa_trust_seconds(auth: Auth) -> Int {
  case auth.config.mfa {
    Some(config) -> mfa.trust_seconds(config)
    None -> mfa.default_trust_seconds
  }
}

/// Whether using a remembered device restarts its lifetime; a transport then
/// re-sets the device cookie with a fresh `mfa_trust_seconds` max-age.
pub fn mfa_trust_renewal(auth: Auth) -> Bool {
  case auth.config.mfa {
    Some(config) -> mfa.trust_renewal(config)
    None -> False
  }
}

pub fn mfa_delivery_enabled(auth: Auth) -> Bool {
  case auth.config.mfa {
    Some(config) -> mfa.can_deliver(config)
    None -> False
  }
}

/// Passkeys use the exact public-origin hostname as RP ID unless
/// `with_passkey_relying_party` says otherwise, and require user verification
/// (PIN/biometric). Enable once at startup with the displayed name.
pub fn with_passkeys(
  auth: Auth,
  relying_party_name: String,
) -> service.Result(Auth) {
  passkey_flow.enable(auth.config, relying_party_name) |> result.map(Auth)
}

pub fn passkeys_enabled(auth: Auth) -> Bool {
  option.is_some(auth.config.passkeys)
}

/// Re-encrypt every stored authenticator secret, and every enrollment still in
/// progress, with the key given to `mfa.new`: the last step of a rotation (see
/// `mfa.with_decryption_keys`). Returns how many needed it; once every node
/// seals with the new key, a rerun returns 0 and the old key can be dropped.
/// Safe to run while serving. A secret no configured key opens stops it with
/// an error naming the user, since dropping any key would not change that.
pub fn reseal_mfa(auth: Auth) -> service.Result(Int) {
  mfa_flow.reseal(auth.config)
}

/// Share passkeys across subdomains. `id` is the RP ID: the public origin's
/// hostname or a parent domain of it, such as `example.com` for
/// `https://app.example.com`. `origins` lists further HTTPS origins under that
/// domain whose ceremonies `finish_passkey_registration` and
/// `finish_passkey_login` also accept; the public origin always is. Call after
/// `with_passkeys`.
///
/// Browsers refuse a public suffix (`com`, `co.uk`) as RP ID; that is not
/// checked here. A passkey is bound to the RP ID it was created under, so
/// changing it later strands every existing passkey: choose it before launch.
/// The bundled JSON routes still answer only the public origin, so another
/// origin needs its own deployment or transport calling these functions.
pub fn with_passkey_relying_party(
  auth: Auth,
  id id: String,
  origins origins: List(String),
) -> service.Result(Auth) {
  passkey_flow.relying_party(auth.config, id, origins) |> result.map(Auth)
}

/// MFA-aware replacements for transports that previously called exchange_from
/// and login_password_from. A SecondFactor token is NOT a session credential.
pub fn exchange_step(
  auth: Auth,
  token: String,
  client: String,
) -> service.Result(LoginStep) {
  email_flow.redeem(auth.config, token, client)
  |> result.try(session_flow.publish_step(auth.config, _))
  |> result.map(login_step)
}

/// As `exchange_step`, redeeming the six-digit code from `Delivery.code`
/// with the address it was sent to. Forbidden unless `with_email_codes`.
/// A wrong code, or one already retired by three wrong guesses, is
/// Unauthorized; too many guesses at an address or from a client are
/// TooManyRequests, as for passwords. The emailed token still works.
pub fn exchange_code_step(
  auth: Auth,
  email: String,
  code: String,
  client: String,
) -> service.Result(LoginStep) {
  email_flow.redeem_code(auth.config, email, code, client)
  |> result.try(session_flow.publish_step(auth.config, _))
  |> result.map(login_step)
}

pub fn login_password_step(
  auth: Auth,
  email: String,
  password: String,
  client: String,
) -> service.Result(LoginStep) {
  password_flow.verify(auth.config, email, password, client)
  |> result.try(session_flow.publish_step(auth.config, _))
  |> result.map(login_step)
}

pub fn passkeys(
  auth: Auth,
  principal: Principal,
) -> service.Result(List(passkey.Passkey)) {
  passkey_flow.list_keys(auth.config, principal)
}

pub fn begin_passkey_registration(
  auth: Auth,
  principal: Principal,
  name: String,
) -> service.Result(PasskeyChallenge) {
  passkey_flow.begin_registration(auth.config, principal, name)
  |> result.map(passkey_challenge)
}

pub fn finish_passkey_registration(
  auth: Auth,
  principal: Principal,
  challenge: String,
  credential: String,
) -> service.Result(Nil) {
  passkey_flow.finish_registration(
    auth.config,
    principal,
    challenge,
    credential,
  )
}

/// Whether `begin_passkey_signup` is available: passkeys, registration and
/// email tokens must all be enabled.
pub fn passkey_signup_enabled(auth: Auth) -> Bool {
  passkey_flow.signup_enabled(auth.config)
}

/// Register a new account with a passkey and no password. The ceremony runs
/// first, signed out; `finish_passkey_signup` then emails a `Registration`
/// token, and the account and its passkey are created together when that token
/// is exchanged. As everywhere else, no account exists before its address is
/// verified, and the reply never says whether the address already has one.
/// Nothing is excluded from the ceremony, for the same reason.
pub fn begin_passkey_signup(
  auth: Auth,
  email: String,
  name: String,
) -> service.Result(PasskeyChallenge) {
  passkey_flow.begin_signup(auth.config, email, name)
  |> result.map(passkey_challenge)
}

/// Verify the new credential, then send the registration token. The passkey
/// works only after that token is exchanged; for an address that already has an
/// account it is discarded and the email says `AlreadyRegistered`. Subject to
/// the same per-address cooldown as password registration.
pub fn finish_passkey_signup(
  auth: Auth,
  challenge: String,
  credential: String,
  client: String,
) -> service.Result(Nil) {
  passkey_flow.finish_signup(auth.config, challenge, credential, client)
}

pub fn begin_passkey_login(auth: Auth) -> service.Result(PasskeyChallenge) {
  passkey_flow.begin_login(auth.config) |> result.map(passkey_challenge)
}

pub fn finish_passkey_login(
  auth: Auth,
  challenge: String,
  credential: String,
  client: String,
) -> service.Result(LoginStep) {
  passkey_flow.finish_login(auth.config, challenge, credential, client)
  |> result.map(login_step)
}

pub fn rename_passkey(
  auth: Auth,
  principal: Principal,
  id: String,
  name: String,
) -> service.Result(Nil) {
  passkey_flow.rename(auth.config, principal, id, name)
}

pub fn delete_passkey(
  auth: Auth,
  principal: Principal,
  id: String,
) -> service.Result(Nil) {
  passkey_flow.delete(auth.config, principal, id)
}

pub fn mfa_status(
  auth: Auth,
  principal: Principal,
) -> service.Result(Option(String)) {
  mfa_flow.status(auth.config, principal)
}

/// Begin enrollment; it is NOT enabled until the code is confirmed. The key
/// and URI are secrets; render locally, never through a third-party QR service.
pub fn begin_mfa(
  auth: Auth,
  principal: Principal,
  method: MfaMethod,
) -> service.Result(MfaSetup) {
  mfa_flow.begin(auth.config, principal, mfa_method(method))
  |> result.map(mfa_setup)
}

/// Successful enrollment revokes all sessions. Save the returned recovery
/// codes once, then sign in again using the new second factor.
pub fn confirm_mfa(
  auth: Auth,
  principal: Principal,
  challenge: String,
  code: String,
) -> service.Result(List(secret.Secret)) {
  mfa_flow.confirm(auth.config, principal, challenge, code)
}

/// Optional delivered-code fallback. Refused after email-token primary proof,
/// so the same inbox cannot serve as both authentication factors.
pub fn send_mfa_code(auth: Auth, challenge: String) -> service.Result(Nil) {
  mfa_flow.send_code(auth.config, challenge)
}

pub fn verify_mfa(
  auth: Auth,
  challenge: String,
  method: MfaMethod,
  code: String,
  remember: Bool,
) -> service.Result(MfaSession) {
  mfa_flow.verify(auth.config, challenge, mfa_method(method), code, remember)
  |> result.map(fn(verified) {
    MfaSession(session(verified.session), verified.trusted_device)
  })
}

/// Redeem a remembered device only AFTER a successful primary login challenge.
/// Tokens are user- and generation-bound and last as long as
/// `mfa.with_device_trust` says (30 days by default), restarting on each use
/// only when renewal is enabled.
pub fn use_trusted_device(
  auth: Auth,
  challenge: String,
  device: String,
) -> service.Result(Session) {
  mfa_flow.use_trusted_device(auth.config, challenge, device)
  |> result.map(session)
}

pub fn disable_mfa(auth: Auth, principal: Principal) -> service.Result(Nil) {
  mfa_flow.disable(auth.config, principal)
}

pub fn regenerate_recovery_codes(
  auth: Auth,
  principal: Principal,
) -> service.Result(List(secret.Secret)) {
  mfa_flow.regenerate_recovery_codes(auth.config, principal)
}

pub fn trusted_devices(
  auth: Auth,
  principal: Principal,
) -> service.Result(List(#(String, Int, Int))) {
  mfa_flow.trusted_devices(auth.config, principal)
}

pub fn revoke_trusted_device(
  auth: Auth,
  principal: Principal,
  id: String,
) -> service.Result(Nil) {
  mfa_flow.revoke_trusted_device(auth.config, principal, id)
}

// --- Boundary conversions ---------------------------------------------------
//
// The flows return `internal/types` values; these turn them into the public
// twins above, and public arguments into theirs.

/// Wrap the application's delivery callback so the flows can hand it their
/// own `Delivery`.
fn delivering(
  deliver: fn(Delivery) -> Result(Nil, Nil),
) -> fn(types.Delivery) -> Result(Nil, Nil) {
  fn(delivery: types.Delivery) {
    deliver(Delivery(
      email: delivery.email,
      token: delivery.token,
      purpose: purpose(delivery.purpose),
      link: delivery.link,
      code: delivery.code,
      locale: delivery.locale,
    ))
  }
}

fn purpose(purpose: labels.Purpose) -> Purpose {
  case purpose {
    labels.SignIn -> SignIn
    labels.Registration -> Registration
    labels.AlreadyRegistered -> AlreadyRegistered
    labels.EmailChange -> EmailChange
    labels.EmailChangeApproval -> EmailChangeApproval
    labels.EmailChanged -> EmailChanged
    labels.PasswordChanged -> PasswordChanged
  }
}

fn method(method: labels.Method) -> Method {
  case method {
    labels.EmailToken -> EmailToken
    labels.Password -> Password
    labels.Provider(id) -> Provider(id)
    labels.Passkey -> Passkey
    labels.Impersonation -> Impersonation
  }
}

fn mfa_method(method: MfaMethod) -> labels.MfaMethod {
  case method {
    Totp -> labels.TotpCode
    DeliveredCode -> labels.DeliveredCode
    RecoveryCode -> labels.RecoveryCode
  }
}

fn session(session: types.Session) -> Session {
  Session(session.user, session.token, session.expires_at)
}

fn session_info(info: types.SessionInfo) -> SessionInfo {
  SessionInfo(
    id: info.id,
    method: method(info.method),
    created_at: info.created_at,
    last_seen_at: info.last_seen_at,
    expires_at: info.expires_at,
    current: info.current,
    client: info.client,
  )
}

fn mfa_challenge(challenge: types.MfaChallenge) -> MfaChallenge {
  MfaChallenge(challenge.token)
}

fn login_step(step: types.LoginStep) -> LoginStep {
  case step {
    types.SignedIn(signed_in) -> SignedIn(session(signed_in))
    types.SecondFactor(challenge) -> SecondFactor(mfa_challenge(challenge))
  }
}

fn mfa_setup(setup: types.MfaSetup) -> MfaSetup {
  MfaSetup(setup.challenge, setup.key, setup.uri, setup.qr_code)
}

fn passkey_challenge(challenge: types.PasskeyChallenge) -> PasskeyChallenge {
  PasskeyChallenge(challenge.challenge, challenge.options)
}

fn provider_start(start: types.ProviderStart) -> ProviderStart {
  ProviderStart(start.url, start.browser_token)
}

fn provider_outcome(outcome: types.ProviderOutcome) -> ProviderOutcome {
  case outcome {
    types.ProviderSession(signed_in) -> ProviderSession(session(signed_in))
    types.ProviderLinked -> ProviderLinked
    types.ProviderSecondFactor(challenge) ->
      ProviderSecondFactor(mfa_challenge(challenge))
  }
}
