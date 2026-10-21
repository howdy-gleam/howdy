//// The one place Howdy reaches into glasslock's `internal` module.
////
//// Registration needs the attestation object's authenticator data (for the
//// backup flags and AAGUID) and a stable string form of transports, which
//// glasslock 1.0.0-rc1 exposes only from `glasslock/internal`. That module
//// carries no stability promise, so `gleam.toml` pins the exact version.
//// On upgrade: check whether `glasslock/registration` (or `glasslock`) has
//// grown public equivalents of the functions below and move to them, then
//// loosen the pin; otherwise re-verify these signatures against the new
//// release and move the pin. Nothing outside this module may import
//// `glasslock/internal`.

import glasslock.{type Transport}
import glasslock/internal as webauthn
import gleam/result

/// The authenticator data bytes of a CBOR attestation object.
pub fn attestation_auth_data(object: BitArray) -> Result(BitArray, Nil) {
  use object <- result.try(
    webauthn.parse_attestation_object(object) |> result.replace_error(Nil),
  )
  use #(data, _, _) <- result.try(
    webauthn.extract_attestation_fields(object) |> result.replace_error(Nil),
  )
  Ok(data)
}

/// The AAGUID of the credential attested in authenticator data.
pub fn aaguid(data: BitArray) -> Result(BitArray, Nil) {
  use parsed <- result.try(
    webauthn.parse_registration_auth_data(data) |> result.replace_error(Nil),
  )
  Ok(parsed.attested_credential.aaguid)
}

pub fn transport_to_string(transport: Transport) -> String {
  webauthn.transport_to_string(transport)
}

pub fn transport_from_string(value: String) -> Result(Transport, Nil) {
  webauthn.transport_from_string(value)
}
