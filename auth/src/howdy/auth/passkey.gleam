//// WebAuthn verification through the pinned glasslock dependency (its
//// unstable parts only via `internal/webauthn_adapter`). Howdy owns expiry,
//// one-time challenges, account/session binding and atomic persistence.

import glasslock
import glasslock/authentication
import glasslock/registration
import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import howdy/auth/internal/webauthn_adapter as webauthn
import howdy/service

pub type Passkey {
  Passkey(
    id: String,
    name: String,
    created_at: Int,
    aaguid: String,
    backup_eligible: Bool,
    backed_up: Bool,
  )
}

@internal
pub type Stored {
  Stored(
    info: Passkey,
    user_id: String,
    key: String,
    counter: Int,
    transports: String,
  )
}

/// A verified credential held with an email challenge until its account exists.
@internal
pub fn encode(stored: Stored) -> String {
  json.object([
    #("id", json.string(stored.info.id)),
    #("name", json.string(stored.info.name)),
    #("created_at", json.int(stored.info.created_at)),
    #("aaguid", json.string(stored.info.aaguid)),
    #("backup_eligible", json.bool(stored.info.backup_eligible)),
    #("backed_up", json.bool(stored.info.backed_up)),
    #("user_id", json.string(stored.user_id)),
    #("key", json.string(stored.key)),
    #("counter", json.int(stored.counter)),
    #("transports", json.string(stored.transports)),
  ])
  |> json.to_string
}

@internal
pub fn decode(encoded: String) -> service.Result(Stored) {
  json.parse(encoded, {
    use id <- decode.field("id", decode.string)
    use name <- decode.field("name", decode.string)
    use created_at <- decode.field("created_at", decode.int)
    use aaguid <- decode.field("aaguid", decode.string)
    use backup_eligible <- decode.field("backup_eligible", decode.bool)
    use backed_up <- decode.field("backed_up", decode.bool)
    use user_id <- decode.field("user_id", decode.string)
    use key <- decode.field("key", decode.string)
    use counter <- decode.field("counter", decode.int)
    use transports <- decode.field("transports", decode.string)
    decode.success(Stored(
      Passkey(id, name, created_at, aaguid, backup_eligible, backed_up),
      user_id,
      key,
      counter,
      transports,
    ))
  })
  |> result.replace_error(service.Internal("stored passkey is unreadable"))
}

@internal
pub fn registration_options(
  rp: String,
  name: String,
  origin: String,
  origins: List(String),
  user_id: String,
  email: String,
  existing: List(Stored),
) -> #(json.Json, String) {
  let assert Ok(builder) =
    registration.new(
      registration.RelyingParty(rp, name),
      registration.User(<<user_id:utf8>>, email, email),
      origin,
    )
    |> registration.user_verification(glasslock.VerificationRequired)
    |> registration.resident_key(registration.ResidentKeyRequired)
    |> registration.algorithms([
      registration.Es256,
      registration.Ed25519,
      registration.Rs256,
    ])
  let builder = list.fold(origins, builder, registration.origin)
  let builder =
    list.fold(existing, builder, fn(builder, stored) {
      case bit_array.base64_url_decode(stored.info.id) {
        Ok(id) ->
          registration.exclude_credential(
            builder,
            id,
            transports(stored.transports),
          )
        Error(_) -> builder
      }
    })
  let #(options, challenge) = registration.build(builder)
  #(options, registration.encode_challenge(challenge))
}

@internal
pub fn authentication_options(
  rp: String,
  origin: String,
  origins: List(String),
) -> #(json.Json, String) {
  let #(options, challenge) =
    authentication.new(rp, origin)
    |> authentication.user_verification(glasslock.VerificationRequired)
    |> list.fold(origins, _, authentication.origin)
    |> authentication.build
  #(options, authentication.encode_challenge(challenge))
}

@internal
pub fn credential_id(response: String) -> service.Result(String) {
  authentication.parse_response_json(response)
  |> result.try(authentication.response_info)
  |> result.map(fn(info) {
    bit_array.base64_url_encode(info.credential_id, False)
  })
  |> result.replace_error(service.Unauthorized)
}

@internal
pub fn register(
  challenge: String,
  response: String,
  user_id: String,
  name: String,
  now: Int,
) -> service.Result(Stored) {
  use challenge <- result.try(
    registration.parse_challenge(challenge)
    |> result.replace_error(service.Unauthorized),
  )
  use parsed <- result.try(
    registration.parse_response_json(response)
    |> result.replace_error(service.Unauthorized),
  )
  use credential <- result.try(
    registration.verify(parsed, challenge)
    |> result.replace_error(service.Unauthorized),
  )
  use encoded <- result.try(
    json.parse(
      response,
      decode.subfield(
        ["response", "attestationObject"],
        decode.string,
        decode.success,
      ),
    )
    |> result.replace_error(service.Unauthorized),
  )
  use object <- result.try(
    bit_array.base64_url_decode(encoded)
    |> result.replace_error(service.Unauthorized),
  )
  use data <- result.try(
    webauthn.attestation_auth_data(object)
    |> result.replace_error(service.Unauthorized),
  )
  use #(eligible, backed_up) <- result.try(backup_flags(data))
  use aaguid <- result.try(
    webauthn.aaguid(data) |> result.replace_error(service.Unauthorized),
  )
  Ok(Stored(
    Passkey(
      bit_array.base64_url_encode(credential.id, False),
      name,
      now,
      bit_array.base64_url_encode(aaguid, False),
      eligible,
      backed_up,
    ),
    user_id,
    bit_array.base64_url_encode(
      glasslock.encode_public_key(credential.public_key),
      False,
    ),
    credential.sign_count,
    string.join(
      list.map(credential.transports, webauthn.transport_to_string),
      ",",
    ),
  ))
}

@internal
pub fn verify(
  challenge: String,
  response: String,
  stored: Stored,
) -> service.Result(Stored) {
  use challenge <- result.try(
    authentication.parse_challenge(challenge)
    |> result.replace_error(service.Unauthorized),
  )
  use parsed <- result.try(
    authentication.parse_response_json(response)
    |> result.replace_error(service.Unauthorized),
  )
  use id <- result.try(
    bit_array.base64_url_decode(stored.info.id)
    |> result.replace_error(service.Unauthorized),
  )
  use key <- result.try(
    bit_array.base64_url_decode(stored.key)
    |> result.replace_error(service.Unauthorized),
  )
  use key <- result.try(
    glasslock.parse_public_key(key)
    |> result.replace_error(service.Unauthorized),
  )
  use updated <- result.try(
    authentication.verify(
      parsed,
      challenge,
      glasslock.Credential(
        id,
        key,
        stored.counter,
        transports(stored.transports),
      ),
      authentication.DiscoveredUser(<<stored.user_id:utf8>>),
    )
    |> result.replace_error(service.Unauthorized),
  )
  use data <- result.try(
    json.parse(
      response,
      decode.subfield(
        ["response", "authenticatorData"],
        decode.string,
        decode.success,
      ),
    )
    |> result.replace_error(service.Unauthorized),
  )
  use data <- result.try(
    bit_array.base64_url_decode(data)
    |> result.replace_error(service.Unauthorized),
  )
  use #(eligible, backed_up) <- result.try(backup_flags(data))
  case eligible == stored.info.backup_eligible {
    True ->
      Ok(
        Stored(
          ..stored,
          counter: updated.sign_count,
          info: Passkey(..stored.info, backed_up:),
        ),
      )
    False -> Error(service.Unauthorized)
  }
}

fn backup_flags(data: BitArray) -> service.Result(#(Bool, Bool)) {
  case data {
    <<_:bytes-size(32), flags:8, _:bits>> ->
      Ok(#(int.bitwise_and(flags, 8) != 0, int.bitwise_and(flags, 16) != 0))
    _ -> Error(service.Unauthorized)
  }
}

fn transports(value: String) -> List(glasslock.Transport) {
  value |> string.split(",") |> list.filter_map(webauthn.transport_from_string)
}
