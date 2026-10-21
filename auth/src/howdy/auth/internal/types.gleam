//// Internal counterparts of the value types `howdy/auth` exports: what a
//// flow returns before the public face converts it. They exist because
//// Gleam cannot re-export constructors: the public types must be defined in
//// `howdy/auth`, and the flows cannot import that module without a cycle.
//// Keep each in step with its public twin.

import gleam/json
import gleam/option.{type Option}
import howdy/auth/internal/labels.{type Method, type Purpose}
import howdy/auth/secret
import howdy/auth/user.{type User}

/// See `howdy/auth.Delivery`.
pub type Delivery {
  Delivery(
    email: String,
    token: secret.Secret,
    purpose: Purpose,
    link: Option(secret.Secret),
    code: Option(secret.Secret),
    locale: Option(String),
  )
}

/// See `howdy/auth.Session`.
pub type Session {
  Session(user: User, token: secret.Secret, expires_at: Int)
}

/// See `howdy/auth.SessionInfo`.
pub type SessionInfo {
  SessionInfo(
    id: String,
    method: Method,
    created_at: Int,
    last_seen_at: Int,
    expires_at: Int,
    current: Bool,
    client: String,
  )
}

/// See `howdy/auth.MfaChallenge`.
pub type MfaChallenge {
  MfaChallenge(token: secret.Secret)
}

/// See `howdy/auth.LoginStep`.
pub type LoginStep {
  SignedIn(Session)
  SecondFactor(MfaChallenge)
}

/// See `howdy/auth.MfaSetup`.
pub type MfaSetup {
  MfaSetup(
    challenge: secret.Secret,
    key: Option(secret.Secret),
    uri: Option(secret.Secret),
    qr_code: Option(secret.Secret),
  )
}

/// See `howdy/auth.MfaSession`.
pub type MfaSession {
  MfaSession(session: Session, trusted_device: Option(secret.Secret))
}

/// See `howdy/auth.PasskeyChallenge`.
pub type PasskeyChallenge {
  PasskeyChallenge(challenge: secret.Secret, options: json.Json)
}

/// See `howdy/auth.ProviderStart`.
pub type ProviderStart {
  ProviderStart(url: String, browser_token: secret.Secret)
}

/// See `howdy/auth.ProviderOutcome`.
pub type ProviderOutcome {
  ProviderSession(Session)
  ProviderLinked
  ProviderSecondFactor(MfaChallenge)
}
