//// Optional second-factor configuration. Keep the encryption key outside the
//// auth database; all nodes must use the same stable, 32-byte base64url key.
//// Rotate it with `with_decryption_keys` and `auth.reseal_mfa`.

import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import howdy/auth/internal/keyring.{type Keyring}
import howdy/auth/secret
import howdy/auth/user.{type User}
import howdy/service

pub opaque type Config {
  Config(
    issuer: String,
    keys: Keyring,
    deliver: Option(fn(User, secret.Secret) -> Result(Nil, Nil)),
    trust_seconds: Int,
    trust_renewal: Bool,
    recovery_codes: Int,
  )
}

/// Default remembered-device lifetime: 30 days.
pub const default_trust_seconds = 2_592_000

pub fn new(issuer: String, encryption_key: String) -> service.Result(Config) {
  use keys <- result.try(
    keyring.new(encryption_key) |> result.replace_error(invalid_key),
  )
  case string.trim(issuer) != "" && string.byte_size(issuer) <= 128 {
    True -> Ok(Config(issuer, keys, None, default_trust_seconds, False, 10))
    False -> Error(service.Invalid("MFA issuer must contain 1 to 128 bytes"))
  }
}

const invalid_key = service.Invalid(
  "MFA encryption key must be 32 random bytes encoded as base64url",
)

/// Keys that still decrypt authenticator secrets but never encrypt new ones,
/// replacing any given before. To rotate without failing a sign-in:
///
/// 1. On every node, add the new key here, keeping the old key in `new`.
/// 2. On every node, swap them: the new key in `new`, the old key here.
/// 3. Run `auth.reseal_mfa` once, then drop the old key.
///
/// The first step lets a node still sealing with the old key read what an
/// updated node seals; skip it only if all nodes restart together.
pub fn with_decryption_keys(
  config: Config,
  keys: List(String),
) -> service.Result(Config) {
  use keys <- result.map(
    keyring.with_decryption_keys(config.keys, keys)
    |> result.replace_error(invalid_key),
  )
  Config(..config, keys:)
}

/// Deliver to a separately verified channel owned by this user. The application
/// chooses the address/phone; never take the destination from the login request.
/// An email-token login cannot use delivered OTP as its second factor.
pub fn with_delivery(
  config: Config,
  deliver: fn(User, secret.Secret) -> Result(Nil, Nil),
) -> Config {
  Config(..config, deliver: Some(deliver))
}

/// How long a remembered device skips the second factor: 30 days by default,
/// at least five minutes and at most a year. With `renew`, each successful use
/// restarts the lifetime, so only a device left unused this long is forgotten;
/// without it, trust ends this long after the second factor was last verified.
/// Devices already remembered keep the expiry they were issued with.
pub fn with_device_trust(
  config: Config,
  seconds seconds: Int,
  renew renew: Bool,
) -> service.Result(Config) {
  case seconds >= 300 && seconds <= 31_536_000 {
    True -> Ok(Config(..config, trust_seconds: seconds, trust_renewal: renew))
    False ->
      Error(service.Invalid(
        "MFA device trust must last 300 to 31536000 seconds",
      ))
  }
}

/// Recovery codes issued per enrollment or regeneration: 10 by default, 4 to 32.
pub fn with_recovery_codes(
  config: Config,
  count: Int,
) -> service.Result(Config) {
  case count >= 4 && count <= 32 {
    True -> Ok(Config(..config, recovery_codes: count))
    False -> Error(service.Invalid("MFA recovery codes must number 4 to 32"))
  }
}

@internal
pub fn trust_seconds(config: Config) -> Int {
  config.trust_seconds
}

@internal
pub fn trust_renewal(config: Config) -> Bool {
  config.trust_renewal
}

@internal
pub fn recovery_codes(config: Config) -> Int {
  config.recovery_codes
}

@internal
pub fn issuer(config: Config) -> String {
  config.issuer
}

@internal
pub fn can_deliver(config: Config) -> Bool {
  option.is_some(config.deliver)
}

@internal
pub fn deliver(
  config: Config,
  user: User,
  code: secret.Secret,
) -> service.Result(Nil) {
  case config.deliver {
    Some(send) ->
      send(user, code)
      |> result.replace_error(service.Internal("MFA code delivery failed"))
    None -> Error(service.Forbidden)
  }
}

@external(erlang, "howdy_auth_mfa_ffi", "new_secret")
@internal
pub fn new_secret() -> String

@external(erlang, "howdy_auth_mfa_ffi", "otp")
@internal
pub fn otp() -> String

@external(erlang, "howdy_auth_mfa_ffi", "backup")
@internal
pub fn backup() -> String

@external(erlang, "howdy_auth_mfa_ffi", "verify_totp")
@internal
pub fn verify_totp(
  seed: String,
  code: String,
  after: Int,
  now: Int,
) -> Result(Int, Nil)

/// An SVG QR code of `text`, error correction level M. Fails only beyond the
/// 2331 bytes a QR code can hold at that level.
@external(erlang, "howdy_auth_qr_ffi", "svg")
@internal
pub fn qr_code(text: String) -> Result(String, Nil)

@internal
pub fn keys(config: Config) -> Keyring {
  config.keys
}

@internal
pub fn seal(
  config: Config,
  user_id: String,
  value: String,
) -> service.Result(String) {
  keyring.seal(config.keys, user_id, value)
  |> result.replace_error(service.Internal("MFA encryption failed"))
}

@internal
pub fn open(
  config: Config,
  user_id: String,
  value: String,
) -> service.Result(String) {
  keyring.open(config.keys, user_id, value)
  |> result.replace_error(service.Internal("MFA secret could not be decrypted"))
}
