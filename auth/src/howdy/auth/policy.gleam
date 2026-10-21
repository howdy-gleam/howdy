//// Every tunable limit in one place. Start from `default()` and change only
//// what the application needs:
////
//// ```gleam
//// let policy = policy.Policy(..policy.default(), session_seconds: 3600)
//// let assert Ok(identity) = auth.with_policy(identity, policy)
//// ```

import gleam/list
import howdy/service

pub type Policy {
  Policy(
    /// Session lifetime: absolute, unless `session_renew_seconds` extends it.
    session_seconds: Int,
    /// Sliding renewal. When a session is used and at least this long has
    /// passed since its expiry was last set, the expiry moves to
    /// `session_seconds` from now. Zero, the default, disables renewal;
    /// otherwise at least 60 and less than `session_seconds`. With a week-long
    /// session, 86_400 keeps anyone who returns within a week signed in, at
    /// the cost of one extra write per session per day.
    session_renew_seconds: Int,
    /// Hard ceiling on a renewed session, measured from its creation: however
    /// active, it ends then. Zero means no ceiling; otherwise at least
    /// `session_seconds`. Set one whenever renewal is on unless sessions
    /// really should be able to live forever.
    session_max_seconds: Int,
    /// Revoke a session unused for this long. Zero disables the idle timeout;
    /// otherwise at least 300, because last use is recorded once a minute.
    session_idle_seconds: Int,
    /// How recently a session must have been created by an email-token
    /// exchange for it to set or replace a password.
    fresh_session_seconds: Int,
    /// Lifetime of an emailed token.
    challenge_seconds: Int,
    /// Unexpired emailed tokens kept per address. A new request discards only
    /// the oldest beyond this, so it cannot invalidate a token in transit.
    live_challenges: Int,
    /// A token request sends nothing when the address already has a live token
    /// with at least this long left; the caller still receives success, because
    /// a usable token is already in that inbox. This is what stops a third
    /// party both flooding an inbox and locking its owner out: whoever asks,
    /// the owner ends up with exactly one live token. Raising it sends more
    /// email and allows a sooner resend; `challenge_seconds` disables
    /// coalescing entirely.
    email_coalesce_margin_seconds: Int,
    /// Wait after the first email to an address. It doubles with every further
    /// request, up to `email_cooldown_max_seconds`.
    email_cooldown_seconds: Int,
    email_cooldown_max_seconds: Int,
    /// The doubling starts over once an address has been left alone this long
    /// after its cooldown ended. A successful exchange resets it immediately.
    email_quiet_seconds: Int,
    /// Initial guesses per client/address before exponential back-off.
    password_attempts: Int,
    /// High shared ceiling per address; the lower budget is per client/address.
    password_account_attempts: Int,
    password_backoff_max_seconds: Int,
    password_quiet_seconds: Int,
    password_window_seconds: Int,
    /// Minimum new password length in Unicode code points.
    password_min_length: Int,
  )
}

pub fn default() -> Policy {
  Policy(
    session_seconds: 86_400,
    session_renew_seconds: 0,
    session_max_seconds: 0,
    session_idle_seconds: 0,
    fresh_session_seconds: 600,
    challenge_seconds: 600,
    live_challenges: 3,
    email_coalesce_margin_seconds: 300,
    email_cooldown_seconds: 60,
    email_cooldown_max_seconds: 3600,
    email_quiet_seconds: 900,
    password_attempts: 5,
    password_account_attempts: 100,
    password_backoff_max_seconds: 3600,
    password_quiet_seconds: 86_400,
    password_window_seconds: 60,
    password_min_length: 15,
  )
}

/// Passwords longer than this are rejected before hashing.
pub const password_max_bytes = 1024

@internal
pub fn validate(policy: Policy) -> service.Result(Policy) {
  let positive =
    list.all(
      [
        policy.session_seconds,
        policy.fresh_session_seconds,
        policy.challenge_seconds,
        policy.live_challenges,
        policy.email_coalesce_margin_seconds,
        policy.email_cooldown_seconds,
        policy.email_quiet_seconds,
        policy.password_attempts,
        policy.password_account_attempts,
        policy.password_backoff_max_seconds,
        policy.password_quiet_seconds,
        policy.password_window_seconds,
      ],
      fn(value) { value > 0 },
    )
  case
    positive
    && {
      policy.session_idle_seconds == 0 || policy.session_idle_seconds >= 300
    }
    && {
      policy.session_renew_seconds == 0
      || {
        policy.session_renew_seconds >= 60
        && policy.session_renew_seconds < policy.session_seconds
      }
    }
    && {
      policy.session_max_seconds == 0
      || policy.session_max_seconds >= policy.session_seconds
    }
    && policy.email_coalesce_margin_seconds <= policy.challenge_seconds
    && policy.email_cooldown_max_seconds >= policy.email_cooldown_seconds
    && policy.password_account_attempts >= policy.password_attempts
    && policy.password_backoff_max_seconds >= policy.password_window_seconds
    && policy.password_quiet_seconds >= policy.password_backoff_max_seconds
    && policy.password_min_length >= 8
  {
    True -> Ok(policy)
    False ->
      Error(service.Invalid(
        "auth policy values must be positive; idle timeout 0 or at least 300 seconds; session renewal 0 or from 60 seconds to below the session lifetime; maximum session 0 or at least the session lifetime; coalesce margin at most the challenge lifetime; maximum cooldown at least the cooldown; minimum password length at least 8",
      ))
  }
}
