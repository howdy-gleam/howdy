//// A credential that requires an explicit reveal at a transport boundary.
//// The closure keeps ordinary Gleam/Erlang inspection from printing its value.
//// This prevents accidental logging; it is not encryption or memory isolation.

pub opaque type Secret {
  Secret(reveal: fn() -> String)
}

@internal
pub fn wrap(value: String) -> Secret {
  Secret(fn() { value })
}

/// Only reveal when delivering, exchanging or transporting a credential.
pub fn reveal(secret: Secret) -> String {
  secret.reveal()
}
