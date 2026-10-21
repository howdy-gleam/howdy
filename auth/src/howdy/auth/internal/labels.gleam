//// The strings the auth database and audit trail use to name sign-in
//// methods, challenge intents, email purposes, ceremonies and second
//// factors, with the one parser for each. Every flow module builds and
//// matches these through this module, so a label is spelled in one place.
//// `howdy/auth` is the public face; it mirrors `Method`, `Intent`, `Purpose`
//// and `MfaMethod` as public types.

import gleam/option.{type Option, None, Some}
import gleam/string
import howdy/service

/// How a session was authenticated.
pub type Method {
  EmailToken
  Password
  Provider(id: String)
  Passkey
  Impersonation
}

/// The stored name of a first-factor method.
pub fn method_name(method: Method) -> String {
  case method {
    EmailToken -> "email"
    Password -> "password"
    Provider(id) -> "provider:" <> id
    Passkey -> "passkey"
    Impersonation -> "impersonation"
  }
}

/// The method a stored name records, ignoring a second-factor mark. Anything
/// unknown reads as an email token, the method the table began with.
pub fn method_from(name: String) -> Method {
  case name {
    "mfa:" <> base -> method_from(base)
    "passkey" -> Passkey
    "impersonation" -> Impersonation
    "password" -> Password
    "provider:" <> id -> Provider(id)
    _ -> EmailToken
  }
}

/// After a second factor the method is recorded as `mfa:` <> the first.
pub fn with_second_factor(first: String) -> String {
  "mfa:" <> first
}

/// The first-factor name a stored method carries, with any second-factor
/// mark removed.
pub fn first_factor(name: String) -> String {
  case name {
    "mfa:" <> first -> first
    first -> first
  }
}

/// Whether a stored method records a verified second factor.
pub fn second_factor_verified(name: String) -> Bool {
  string.starts_with(name, "mfa:")
}

/// The connection id behind a provider id `connection.identity_issuer` made,
/// `None` for a built-in provider.
pub fn sso_connection_id(provider_id: String) -> Option(String) {
  case provider_id {
    "sso:" <> connection_id -> Some(connection_id)
    _ -> None
  }
}

/// What an emailed challenge was asked for.
pub type Intent {
  Login
  Register
}

pub fn intent_name(intent: Intent) -> String {
  case intent {
    Login -> "login"
    Register -> "register"
  }
}

pub fn intent_from(name: String) -> service.Result(Intent) {
  case name {
    "login" -> Ok(Login)
    "register" -> Ok(Register)
    _ -> Error(service.Internal("unknown auth challenge intent"))
  }
}

/// What an email should tell its reader; see `howdy/auth.Purpose`.
pub type Purpose {
  SignIn
  Registration
  AlreadyRegistered
  EmailChange
  EmailChangeApproval
  EmailChanged
  PasswordChanged
}

/// The audit detail recorded for a token request.
pub fn purpose_name(purpose: Purpose) -> String {
  case purpose {
    SignIn -> "sign-in"
    Registration -> "registration"
    AlreadyRegistered -> "already-registered"
    EmailChange -> "email-change"
    EmailChangeApproval -> "email-change-approval"
    EmailChanged -> "email-changed"
    PasswordChanged -> "password-changed"
  }
}

/// The kinds of single-use ceremony `security_store` keeps; a ceremony is
/// consumed only under the kind it was begun with.
pub type Ceremony {
  PasskeyRegister
  PasskeySignup
  PasskeyLogin
  MfaEnrolment
}

pub fn ceremony_name(ceremony: Ceremony) -> String {
  case ceremony {
    PasskeyRegister -> "passkey-register"
    PasskeySignup -> "passkey-signup"
    PasskeyLogin -> "passkey-login"
    MfaEnrolment -> "mfa-setup"
  }
}

/// The kinds of enrolled second factor.
pub type Factor {
  Totp
  Otp
}

pub fn factor_name(factor: Factor) -> String {
  case factor {
    Totp -> "totp"
    Otp -> "otp"
  }
}

pub fn factor_from(name: String) -> Result(Factor, Nil) {
  case name {
    "totp" -> Ok(Totp)
    "otp" -> Ok(Otp)
    _ -> Error(Nil)
  }
}

/// How a second factor is proven; see `howdy/auth.MfaMethod`.
pub type MfaMethod {
  TotpCode
  DeliveredCode
  RecoveryCode
}

/// The audit detail recorded when a second factor is verified.
pub fn mfa_method_name(method: MfaMethod) -> String {
  case method {
    RecoveryCode -> "recovery"
    TotpCode -> "totp"
    DeliveredCode -> "otp"
  }
}
