import glasslock/authentication
import glasslock/registration
import glasslock/testing as authenticator
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gloo/repo
import gloo/sql
import howdy/auth
import howdy/auth/internal/token
import howdy/auth/mfa
import howdy/auth/provider
import howdy/auth/secret
import howdy/auth/session_store
import howdy/service
import howdy/testing
import support.{count, exec, fixture, signup}

const password = "a distant orchard with seven moons 839!"

@external(erlang, "howdy_auth_test_ffi", "totp_code")
fn totp_code(seed: String, seconds: Int) -> String

fn configured(identity) {
  let assert Ok(config) = mfa.new("Howdy tests", token.new())
  let assert Ok(identity) = auth.with_passkeys(identity, "Howdy tests")
  auth.with_mfa(identity, config)
}

fn principal(identity, session: auth.Session) {
  let assert Ok(p) = auth.authenticate(identity, secret.reveal(session.token))
  p
}

fn pending(identity, mailbox: process.Subject(auth.Delivery)) {
  let assert Ok(_) = auth.request_token(identity, "ada@example.com", auth.Login)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let assert Ok(auth.SecondFactor(challenge)) =
    auth.exchange_step(identity, secret.reveal(delivery.token), "test")
  secret.reveal(challenge.token)
}

fn enroll(identity, session) {
  let p = principal(identity, session)
  let assert Ok(setup) = auth.begin_mfa(identity, p, auth.Totp)
  let assert Some(key) = setup.key
  let seed = secret.reveal(key)
  let assert Some(qr) = setup.qr_code
  assert string.starts_with(secret.reveal(qr), "<svg ")
  assert auth.mfa_status(identity, p) == Ok(None)
  let assert Ok(codes) =
    auth.confirm_mfa(
      identity,
      p,
      secret.reveal(setup.challenge),
      totp_code(seed, token.now()),
    )
  #(seed, codes)
}

fn state(database, challenge: auth.PasskeyChallenge) {
  let assert Ok([value]) =
    repo.all(
      database,
      "SELECT payload FROM howdy_auth_ceremonies WHERE digest = $1",
      [sql.string(token.digest(secret.reveal(challenge.challenge)))],
      decode.field(0, decode.string, decode.success),
    )
  value
}

fn registration_response(database, challenge, keypair, verified) {
  let assert Ok(c) = registration.parse_challenge(state(database, challenge))
  let response =
    authenticator.build_registration_response_with_keypair(c, keypair)
  let data =
    authenticator.build_registration_authenticator_data(
      "example.test",
      response.credential_id,
      authenticator.cose_key(keypair),
      authenticator.AuthenticatorFlags(True, verified),
      0,
    )
  authenticator.RegistrationResponse(
    ..response,
    attestation_object: authenticator.build_attestation_object("none", data, []),
  )
}

fn register(database, identity, session, keypair) {
  let p = principal(identity, session)
  let assert Ok(start) = auth.begin_passkey_registration(identity, p, "Laptop")
  let response = registration_response(database, start, keypair, True)
  let encoded = authenticator.to_registration_json(response)
  assert auth.finish_passkey_registration(
      identity,
      p,
      secret.reveal(start.challenge),
      encoded,
    )
    == Ok(Nil)
  assert auth.finish_passkey_registration(
      identity,
      p,
      secret.reveal(start.challenge),
      encoded,
    )
    == Error(service.Unauthorized)
  response.credential_id
}

fn assertion(database, challenge, keypair, credential_id, user_id, counter) {
  let assert Ok(c) = authentication.parse_challenge(state(database, challenge))
  let response =
    authenticator.build_authentication_response(
      c,
      credential_id,
      keypair,
      counter,
    )
  let data =
    authenticator.build_authentication_authenticator_data(
      "example.test",
      authenticator.AuthenticatorFlags(True, True),
      counter,
    )
  authenticator.AuthenticationResponse(
    ..response,
    authenticator_data: data,
    user_handle: Some(bit_array.from_string(user_id)),
    signature: authenticator.sign_authentication_message(
      keypair,
      data,
      response.client_data_json,
    ),
  )
}

pub fn totp_rfc6238_vectors_replay_and_authenticated_encryption_test() {
  let seed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
  assert mfa.verify_totp(seed, "287082", -1, 59) == Ok(1)
  assert mfa.verify_totp(seed, "081804", -1, 1_111_111_109) == Ok(37_037_036)
  assert mfa.verify_totp(seed, "050471", -1, 1_111_111_111) == Ok(37_037_037)
  assert mfa.verify_totp(seed, "005924", -1, 1_234_567_890) == Ok(41_152_263)
  assert mfa.verify_totp(seed, "279037", -1, 2_000_000_000) == Ok(66_666_666)
  assert mfa.verify_totp(seed, "353130", -1, 20_000_000_000) == Ok(666_666_666)
  assert mfa.verify_totp(seed, "287082", 1, 59) == Error(Nil)
  assert mfa.verify_totp(seed, "287082", -1, 120) == Error(Nil)
  assert mfa.verify_totp(seed, "abc123", -1, 59) == Error(Nil)
  let assert Ok(config) = mfa.new("Tests", token.new())
  let assert Ok(other) = mfa.new("Tests", token.new())
  let assert Ok(cipher) = mfa.seal(config, "user-a", seed)
  let assert Ok(second) = mfa.seal(config, "user-a", seed)
  assert cipher != second
  assert mfa.open(config, "user-a", cipher) == Ok(seed)
  assert result.is_error(mfa.open(config, "user-b", cipher))
  assert result.is_error(mfa.open(other, "user-a", cipher))
  assert result.is_error(mfa.open(config, "user-a", "AAAA" <> cipher))
}

pub fn qr_codes_fit_any_enrollment_uri_test() {
  // Version 1 is 21 modules plus a four-module quiet zone on each side.
  let assert Ok(small) = mfa.qr_code("otpauth://x")
  assert string.contains(small, "viewBox=\"0 0 29 29\"")
  // A 128-byte issuer and 254-byte address, both fully percent-encoded,
  // still fit well inside the 2331 bytes of version 40.
  let assert Ok(_) = mfa.qr_code(string.repeat("%41", 400))
  let assert Ok(_) = mfa.qr_code(string.repeat("a", 2331))
  assert mfa.qr_code(string.repeat("a", 2332)) == Error(Nil)
}

pub fn signed_passkeys_login_rename_ownership_and_safe_delete_test() {
  use database, identity, _, mailbox <- fixture
  let identity = configured(identity)
  let session = signup(identity, mailbox, "ada@example.com")
  let keypair = authenticator.generate_es256_keypair()
  let id = register(database, identity, session, keypair)
  let p = principal(identity, session)
  let assert Ok([key]) = auth.passkeys(identity, p)
  assert key.id == bit_array.base64_url_encode(id, False)
  assert auth.rename_passkey(identity, p, key.id, "Phone") == Ok(Nil)
  let other = signup(identity, mailbox, "other@example.com")
  assert auth.rename_passkey(
      identity,
      principal(identity, other),
      key.id,
      "Stolen",
    )
    == Error(service.NotFound("passkey"))
  let assert Ok(start) = auth.begin_passkey_login(identity)
  let response =
    assertion(database, start, keypair, id, session.user.id, 1)
    |> authenticator.to_authentication_json
  let assert Ok(auth.SignedIn(signed_in)) =
    auth.finish_passkey_login(
      identity,
      secret.reveal(start.challenge),
      response,
      "test",
    )
  assert signed_in.user.id == session.user.id
  assert auth.finish_passkey_login(
      identity,
      secret.reveal(start.challenge),
      response,
      "test",
    )
    == Error(service.Unauthorized)
  assert auth.delete_passkey(identity, principal(identity, signed_in), key.id)
    == Error(service.Forbidden)
  assert auth.delete_passkey(identity, p, key.id) == Ok(Nil)
  assert auth.authenticate(identity, secret.reveal(signed_in.token))
    == Error(service.Unauthorized)
  assert count(database, "SELECT count(*) FROM howdy_auth_passkeys") == 0
}

pub fn passkeys_require_uv_correct_owner_signature_and_monotonic_counter_test() {
  use database, identity, _, mailbox <- fixture
  let identity = configured(identity)
  let session = signup(identity, mailbox, "ada@example.com")
  let p = principal(identity, session)
  let keypair = authenticator.generate_ed25519_keypair()
  let assert Ok(start) = auth.begin_passkey_registration(identity, p, "No UV")
  let invalid =
    registration_response(database, start, keypair, False)
    |> authenticator.to_registration_json
  assert auth.finish_passkey_registration(
      identity,
      p,
      secret.reveal(start.challenge),
      invalid,
    )
    == Error(service.Unauthorized)
  let id = register(database, identity, session, keypair)
  list.each(
    ["wrong-owner", "signature", "origin", "challenge", "uv", "rp"],
    fn(reason) {
      let assert Ok(start) = auth.begin_passkey_login(identity)
      let valid = assertion(database, start, keypair, id, session.user.id, 1)
      let invalid = case reason {
        "wrong-owner" ->
          authenticator.AuthenticationResponse(
            ..valid,
            user_handle: Some(<<"other">>),
          )
        "signature" ->
          authenticator.AuthenticationResponse(..valid, signature: <<0:512>>)
        "origin" | "challenge" -> {
          let assert Ok(c) =
            authentication.parse_challenge(state(database, start))
          let bytes = case reason {
            "challenge" -> <<"wrong challenge">>
            _ -> authentication.challenge_data(c).bytes
          }
          let origin = case reason {
            "origin" -> "https://evil.test"
            _ -> "https://example.test"
          }
          let client = authenticator.build_client_data_get(bytes, origin, False)
          authenticator.AuthenticationResponse(
            ..valid,
            client_data_json: client,
            signature: authenticator.sign_authentication_message(
              keypair,
              valid.authenticator_data,
              client,
            ),
          )
        }
        "uv" -> {
          let data =
            authenticator.build_authentication_authenticator_data(
              "example.test",
              authenticator.AuthenticatorFlags(True, False),
              1,
            )
          authenticator.AuthenticationResponse(
            ..valid,
            authenticator_data: data,
            signature: authenticator.sign_authentication_message(
              keypair,
              data,
              valid.client_data_json,
            ),
          )
        }
        _ -> {
          let data =
            authenticator.build_authentication_authenticator_data(
              "evil.test",
              authenticator.AuthenticatorFlags(True, True),
              1,
            )
          authenticator.AuthenticationResponse(
            ..valid,
            authenticator_data: data,
            signature: authenticator.sign_authentication_message(
              keypair,
              data,
              valid.client_data_json,
            ),
          )
        }
      }
      assert auth.finish_passkey_login(
          identity,
          secret.reveal(start.challenge),
          authenticator.to_authentication_json(invalid),
          "test",
        )
        == Error(service.Unauthorized)
    },
  )
  list.each([#(1, True), #(1, False), #(2, True)], fn(pair) {
    let #(counter, succeeds) = pair
    let assert Ok(start) = auth.begin_passkey_login(identity)
    let response =
      assertion(database, start, keypair, id, session.user.id, counter)
      |> authenticator.to_authentication_json
    let outcome =
      auth.finish_passkey_login(
        identity,
        secret.reveal(start.challenge),
        response,
        "test",
      )
    assert result.is_ok(outcome) == succeeds
  })
  let assert Ok(start) = auth.begin_passkey_login(identity)
  let response =
    assertion(database, start, keypair, id, session.user.id, 2)
    |> authenticator.to_authentication_json
  assert auth.finish_passkey_login(
      identity,
      secret.reveal(start.challenge),
      response,
      "test",
    )
    == Error(service.Unauthorized)
}

pub fn mfa_recovery_is_one_use_pending_is_not_a_session_and_trust_is_revocable_test() {
  use database, identity, _, mailbox <- fixture
  let identity = configured(identity)
  let session = signup(identity, mailbox, "ada@example.com")
  let #(seed, codes) = enroll(identity, session)
  assert list.length(codes) == 10
  assert auth.authenticate(identity, secret.reveal(session.token))
    == Error(service.Unauthorized)
  let assert Ok([stored]) =
    repo.all(
      database,
      "SELECT secret FROM howdy_auth_mfa",
      [],
      decode.field(0, decode.string, decode.success),
    )
  assert !string.contains(stored, seed)
  let challenge = pending(identity, mailbox)
  assert auth.authenticate(identity, challenge) == Error(service.Unauthorized)
  assert auth.verify_mfa(
      identity,
      challenge,
      auth.Totp,
      totp_code(seed, token.now()),
      False,
    )
    == Error(service.Unauthorized)
  let assert [first, second, ..] = codes
  let assert Ok(completed) =
    auth.verify_mfa(
      identity,
      challenge,
      auth.RecoveryCode,
      secret.reveal(first),
      True,
    )
  let assert Some(device) = completed.trusted_device
  let p = principal(identity, completed.session)
  assert auth.mfa_status(identity, p) == Ok(Some("totp"))
  assert result.is_error(auth.verify_mfa(
    identity,
    challenge,
    auth.RecoveryCode,
    secret.reveal(second),
    False,
  ))
  let next = pending(identity, mailbox)
  assert auth.verify_mfa(
      identity,
      next,
      auth.RecoveryCode,
      secret.reveal(first),
      False,
    )
    == Error(service.Unauthorized)
  let assert Ok(trusted) =
    auth.use_trusted_device(identity, next, secret.reveal(device))
  let assert Ok([#(device_id, _, _)]) = auth.trusted_devices(identity, p)
  assert auth.revoke_trusted_device(identity, p, device_id) == Ok(Nil)
  let next = pending(identity, mailbox)
  assert auth.use_trusted_device(identity, next, secret.reveal(device))
    == Error(service.Unauthorized)
  assert auth.disable_mfa(identity, principal(identity, trusted)) == Ok(Nil)
  assert result.is_error(auth.verify_mfa(
    identity,
    next,
    auth.RecoveryCode,
    secret.reveal(second),
    False,
  ))
  assert count(database, "SELECT count(*) FROM howdy_auth_recovery_codes") == 0
}

pub fn guesses_cannot_be_reset_by_starting_a_new_login_test() {
  use _, identity, _, mailbox <- fixture
  let identity = configured(identity)
  let session = signup(identity, mailbox, "ada@example.com")
  let #(_, codes) = enroll(identity, session)
  list.each(list.repeat(Nil, 5), fn(_) {
    assert result.is_error(auth.verify_mfa(
      identity,
      pending(identity, mailbox),
      auth.RecoveryCode,
      "wrong",
      False,
    ))
  })
  let assert [code, ..] = codes
  assert result.is_error(auth.verify_mfa(
    identity,
    pending(identity, mailbox),
    auth.RecoveryCode,
    secret.reveal(code),
    False,
  ))
}

pub fn password_and_passkey_logins_and_legacy_apis_cannot_bypass_mfa_test() {
  use database, identity, _, mailbox <- fixture
  let assert Ok(identity) = configured(identity) |> auth.with_passwords
  let session = signup(identity, mailbox, "ada@example.com")
  assert auth.set_password(identity, principal(identity, session), password)
    == Ok(Nil)
  let keypair = authenticator.generate_es256_keypair()
  let id = register(database, identity, session, keypair)
  let _ = enroll(identity, session)
  assert auth.login_password(identity, "ada@example.com", password)
    == Error(service.Forbidden)
  let assert Ok(auth.SecondFactor(_)) =
    auth.login_password_step(identity, "ada@example.com", password, "test")
  let assert Ok(start) = auth.begin_passkey_login(identity)
  let response =
    assertion(database, start, keypair, id, session.user.id, 0)
    |> authenticator.to_authentication_json
  let assert Ok(auth.SecondFactor(_)) =
    auth.finish_passkey_login(
      identity,
      secret.reveal(start.challenge),
      response,
      "test",
    )
  assert count(database, "SELECT count(*) FROM howdy_auth_sessions") == 0
}

pub fn mfa_external_sessions_and_regenerated_recovery_codes_are_revoked_test() {
  use _, identity, _, mailbox <- fixture
  let identity =
    configured(identity) |> auth.with_session_store(session_store.memory())
  let session = signup(identity, mailbox, "ada@example.com")
  let #(_, codes) = enroll(identity, session)
  assert auth.authenticate(identity, secret.reveal(session.token))
    == Error(service.Unauthorized)
  let assert [first, second, ..] = codes
  let assert Ok(completed) =
    auth.verify_mfa(
      identity,
      pending(identity, mailbox),
      auth.RecoveryCode,
      secret.reveal(first),
      True,
    )
  let assert Some(device) = completed.trusted_device
  let assert Ok(new_codes) =
    auth.regenerate_recovery_codes(
      identity,
      principal(identity, completed.session),
    )
  assert list.length(new_codes) == 10
  assert auth.authenticate(identity, secret.reveal(completed.session.token))
    == Error(service.Unauthorized)
  let next = pending(identity, mailbox)
  assert auth.use_trusted_device(identity, next, secret.reveal(device))
    == Error(service.Unauthorized)
  assert auth.verify_mfa(
      identity,
      next,
      auth.RecoveryCode,
      secret.reveal(second),
      False,
    )
    == Error(service.Unauthorized)
  let assert [new_code, ..] = new_codes
  let assert Ok(_) =
    auth.verify_mfa(
      identity,
      next,
      auth.RecoveryCode,
      secret.reveal(new_code),
      False,
    )
}

pub fn expired_ceremonies_and_mfa_challenges_fail_closed_test() {
  use database, identity, _, mailbox <- fixture
  let identity = configured(identity)
  let session = signup(identity, mailbox, "ada@example.com")
  let p = principal(identity, session)
  let keypair = authenticator.generate_es256_keypair()
  let assert Ok(start) = auth.begin_passkey_registration(identity, p, "Expired")
  let response =
    registration_response(database, start, keypair, True)
    |> authenticator.to_registration_json
  exec(database, "UPDATE howdy_auth_ceremonies SET expires_at = 0")
  assert auth.finish_passkey_registration(
      identity,
      p,
      secret.reveal(start.challenge),
      response,
    )
    == Error(service.Unauthorized)
  let #(_, codes) = enroll(identity, session)
  let assert [code, ..] = codes
  let next = pending(identity, mailbox)
  exec(database, "UPDATE howdy_auth_mfa_pending SET expires_at = 0")
  assert auth.verify_mfa(
      identity,
      next,
      auth.RecoveryCode,
      secret.reveal(code),
      False,
    )
    == Error(service.Unauthorized)
}

pub fn delivered_otp_enrollment_and_login_are_separate_from_email_tokens_test() {
  use database, identity, _, mailbox <- fixture
  let deliveries = process.new_subject()
  let assert Ok(config) = mfa.new("Tests", token.new())
  let config =
    mfa.with_delivery(config, fn(_, code) {
      process.send(deliveries, code)
      Ok(Nil)
    })
  let assert Ok(identity) =
    auth.with_mfa(identity, config) |> auth.with_passwords
  let session = signup(identity, mailbox, "ada@example.com")
  let p = principal(identity, session)
  assert auth.begin_mfa(identity, p, auth.DeliveredCode)
    == Error(service.Forbidden)
  assert auth.set_password(identity, p, password) == Ok(Nil)
  let assert Ok(session) =
    auth.login_password(identity, "ada@example.com", password)
  let p = principal(identity, session)
  let assert Ok(setup) = auth.begin_mfa(identity, p, auth.DeliveredCode)
  assert setup.key == None
  let assert Ok(code) = process.receive(deliveries, 1000)
  let assert Ok(_) =
    auth.confirm_mfa(
      identity,
      p,
      secret.reveal(setup.challenge),
      secret.reveal(code),
    )
  let assert Ok(auth.SecondFactor(next)) =
    auth.login_password_step(identity, "ada@example.com", password, "test")
  let next = secret.reveal(next.token)
  assert auth.send_mfa_code(identity, next) == Ok(Nil)
  let assert Ok(code) = process.receive(deliveries, 1000)
  let assert Ok(completed) =
    auth.verify_mfa(
      identity,
      next,
      auth.DeliveredCode,
      secret.reveal(code),
      False,
    )
  assert auth.mfa_status(identity, principal(identity, completed.session))
    == Ok(Some("otp"))
  assert auth.send_mfa_code(identity, pending(identity, mailbox))
    == Error(service.Forbidden)
  assert count(
      database,
      "SELECT count(*) FROM howdy_auth_mfa_pending WHERE otp_digest <> ''",
    )
    == 0
}

pub fn provider_login_is_mfa_gated_test() {
  use database, identity, _, mailbox <- fixture
  let identity = configured(identity)
  let adapter =
    provider.new("test", "Test", Ok(Nil), fn(a) { a.state }, fn(_) {
      Ok(provider.Identity(
        "https://provider.test",
        "ada",
        "ada@example.com",
        True,
        None,
      ))
    })
  let assert Ok(identity) = auth.with_provider(identity, adapter)
  let session = signup(identity, mailbox, "ada@example.com")
  let p = principal(identity, session)
  let callback = "/auth/providers/test/callback"
  let assert Ok(start) = auth.begin_provider_link(identity, p, "test", callback)
  assert auth.finish_provider(
      identity,
      "test",
      callback,
      start.url,
      secret.reveal(start.browser_token),
      Some("valid"),
      Some(p),
    )
    == Ok(auth.ProviderLinked)
  let _ = enroll(identity, session)
  let assert Ok(start) = auth.begin_provider(identity, "test", callback, "test")
  let assert Ok(auth.ProviderSecondFactor(next)) =
    auth.finish_provider(
      identity,
      "test",
      callback,
      start.url,
      secret.reveal(start.browser_token),
      Some("valid"),
      None,
    )
  assert auth.authenticate(identity, secret.reveal(next.token))
    == Error(service.Unauthorized)
  assert count(database, "SELECT count(*) FROM howdy_auth_sessions") == 0
}

pub fn browser_mfa_requires_origin_and_pending_cookie_never_authenticates_test() {
  use _, identity, permissions, mailbox <- fixture
  let identity = configured(identity)
  let session = signup(identity, mailbox, "ada@example.com")
  let #(_, codes) = enroll(identity, session)
  let app = support.app(identity, permissions)
  let assert Ok(_) = auth.request_token(identity, "ada@example.com", auth.Login)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let response =
    testing.post(
      "/api/auth/session",
      json.object([#("token", json.string(secret.reveal(delivery.token)))]),
    )
    |> testing.header("origin", "https://example.test")
    |> testing.send(app)
  assert response.status == 202
  assert !string.contains(testing.text(response), "mfa_token")
  let assert Ok(#(_, challenge)) =
    testing.cookies(response) |> list.find(fn(c) { c.0 == "__Host-howdy_mfa" })
  assert testing.get("/api/auth/me")
    |> testing.cookie("__Host-howdy_session", challenge)
    |> testing.send(app)
    |> fn(r) { r.status }
    == 401
  let assert [code, ..] = codes
  let body =
    json.object([
      #("method", json.string("recovery")),
      #("code", json.string(secret.reveal(code))),
      #("remember", json.bool(True)),
    ])

  assert testing.post("/api/auth/mfa/verify", body)
    |> testing.cookie("__Host-howdy_mfa", challenge)
    |> testing.send(app)
    |> fn(r) { r.status }
    == 403
  let verified =
    testing.post("/api/auth/mfa/verify", body)
    |> testing.cookie("__Host-howdy_mfa", challenge)
    |> testing.header("origin", "https://example.test")
    |> testing.send(app)
  assert verified.status == 200
  let assert Ok(#(_, session_token)) =
    testing.cookies(verified)
    |> list.find(fn(c) { c.0 == "__Host-howdy_session" })
  let assert Ok(#(_, device)) =
    testing.cookies(verified)
    |> list.find(fn(c) { c.0 == "__Host-howdy_trusted" })
  assert result.is_ok(auth.authenticate(identity, session_token))
  assert auth.authenticate(identity, device) == Error(service.Unauthorized)
  assert testing.get("/auth/mfa") |> testing.send(app) |> fn(r) { r.status }
    == 200
}

pub fn successful_totp_cannot_be_replayed_in_another_pending_login_test() {
  use database, identity, _, mailbox <- fixture
  let identity = configured(identity)
  let session = signup(identity, mailbox, "ada@example.com")
  let #(seed, _) = enroll(identity, session)
  // Simulate the next time interval without sleeping or weakening the verifier.
  exec(database, "UPDATE howdy_auth_mfa SET last_step = -1")
  let code = totp_code(seed, token.now())
  let assert Ok(_) =
    auth.verify_mfa(
      identity,
      pending(identity, mailbox),
      auth.Totp,
      code,
      False,
    )
  assert auth.verify_mfa(
      identity,
      pending(identity, mailbox),
      auth.Totp,
      code,
      False,
    )
    == Error(service.Unauthorized)
}

pub fn registration_is_bound_to_the_enrolling_session_test() {
  use database, identity, _, mailbox <- fixture
  let identity = configured(identity)
  let first = signup(identity, mailbox, "ada@example.com")
  let assert Ok(_) = auth.request_token(identity, "ada@example.com", auth.Login)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let assert Ok(second) = auth.exchange(identity, secret.reveal(delivery.token))
  let assert Ok(start) =
    auth.begin_passkey_registration(
      identity,
      principal(identity, first),
      "Bound",
    )
  let response =
    registration_response(
      database,
      start,
      authenticator.generate_es256_keypair(),
      True,
    )
    |> authenticator.to_registration_json
  assert auth.finish_passkey_registration(
      identity,
      principal(identity, second),
      secret.reveal(start.challenge),
      response,
    )
    == Error(service.Unauthorized)
}

pub fn simultaneous_recovery_redemptions_issue_only_one_session_test() {
  use _, identity, _, mailbox <- fixture
  let identity = configured(identity)
  let session = signup(identity, mailbox, "ada@example.com")
  let #(_, codes) = enroll(identity, session)
  let assert [code, ..] = codes
  let first = pending(identity, mailbox)
  let second = pending(identity, mailbox)
  let replies = process.new_subject()
  list.each([first, second], fn(challenge) {
    let _ =
      process.spawn(fn() {
        process.send(
          replies,
          auth.verify_mfa(
            identity,
            challenge,
            auth.RecoveryCode,
            secret.reveal(code),
            False,
          ),
        )
      })
  })
  let assert Ok(first) = process.receive(replies, 5000)
  let assert Ok(second) = process.receive(replies, 5000)
  assert list.length(list.filter([first, second], result.is_ok)) == 1
}

fn backed(data: BitArray, flags: Int) {
  let assert <<rp:bytes-size(32), _:8, rest:bits>> = data
  <<rp:bits, flags:8, rest:bits>>
}

pub fn synced_rsa_passkeys_keep_backup_eligibility_and_allow_zero_counters_test() {
  use database, identity, _, mailbox <- fixture
  let identity = configured(identity)
  let session = signup(identity, mailbox, "ada@example.com")
  let p = principal(identity, session)
  let pair = authenticator.generate_rs256_keypair()
  let assert Ok(start) = auth.begin_passkey_registration(identity, p, "Synced")
  let response = registration_response(database, start, pair, True)
  let data =
    authenticator.build_registration_authenticator_data(
      "example.test",
      response.credential_id,
      authenticator.cose_key(pair),
      authenticator.AuthenticatorFlags(True, True),
      0,
    )
  let response =
    authenticator.RegistrationResponse(
      ..response,
      attestation_object: authenticator.build_attestation_object(
        "none",
        backed(data, 93),
        [],
      ),
    )
  assert auth.finish_passkey_registration(
      identity,
      p,
      secret.reveal(start.challenge),
      authenticator.to_registration_json(response),
    )
    == Ok(Nil)
  let assert Ok([key]) = auth.passkeys(identity, p)
  assert key.backup_eligible && key.backed_up
  list.each([#(29, True), #(13, True), #(5, False)], fn(example) {
    let assert Ok(start) = auth.begin_passkey_login(identity)
    let valid =
      assertion(
        database,
        start,
        pair,
        response.credential_id,
        session.user.id,
        0,
      )
    let data = backed(valid.authenticator_data, example.0)
    let signed =
      authenticator.AuthenticationResponse(
        ..valid,
        authenticator_data: data,
        signature: authenticator.sign_authentication_message(
          pair,
          data,
          valid.client_data_json,
        ),
      )
    assert result.is_ok(auth.finish_passkey_login(
        identity,
        secret.reveal(start.challenge),
        authenticator.to_authentication_json(signed),
        "test",
      ))
      == example.1
  })
  let assert Ok([key]) = auth.passkeys(identity, p)
  assert key.backup_eligible && !key.backed_up
}

pub fn native_bearer_mfa_flow_never_returns_access_before_verification_test() {
  use _, identity, permissions, mailbox <- fixture
  let identity = configured(identity)
  let session = signup(identity, mailbox, "ada@example.com")
  let #(_, codes) = enroll(identity, session)
  let app = support.app(identity, permissions)
  let assert Ok(_) = auth.request_token(identity, "ada@example.com", auth.Login)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let response =
    testing.post(
      "/api/auth/token",
      json.object([#("token", json.string(secret.reveal(delivery.token)))]),
    )
    |> testing.send(app)
  assert response.status == 202
  assert !string.contains(testing.text(response), "access_token")
  let assert Ok(challenge) =
    json.parse(
      testing.text(response),
      decode.field("mfa_token", decode.string, decode.success),
    )
  let assert [code, ..] = codes
  let response =
    testing.post(
      "/api/auth/mfa/token",
      json.object([
        #("challenge", json.string(challenge)),
        #("method", json.string("recovery")),
        #("code", json.string(secret.reveal(code))),
      ]),
    )
    |> testing.send(app)
  assert response.status == 200
  let assert Ok(session_token) =
    json.parse(
      testing.text(response),
      decode.subfield(
        ["session", "access_token"],
        decode.string,
        decode.success,
      ),
    )
  assert result.is_ok(auth.authenticate(identity, session_token))
  assert testing.cookies(response) == []
}

fn device_expiry(database) {
  let assert Ok([#(created, expires)]) =
    repo.all(
      database,
      "SELECT created_at, expires_at FROM howdy_auth_trusted_devices",
      [],
      {
        use created <- decode.field(0, decode.int)
        use expires <- decode.field(1, decode.int)
        decode.success(#(created, expires))
      },
    )
  expires - created
}

pub fn device_trust_lifetime_renewal_and_recovery_count_are_configurable_test() {
  use database, identity, permissions, mailbox <- fixture
  let assert Ok(config) = mfa.new("Howdy tests", token.new())
  assert result.is_error(mfa.with_device_trust(config, 299, False))
  assert result.is_error(mfa.with_device_trust(config, 31_536_001, True))
  assert result.is_error(mfa.with_recovery_codes(config, 3))
  assert result.is_error(mfa.with_recovery_codes(config, 33))
  let assert Ok(fixed) = mfa.with_device_trust(config, 3600, False)
  let assert Ok(fixed) = mfa.with_recovery_codes(fixed, 4)
  let assert Ok(renewing) = mfa.with_device_trust(fixed, 3600, True)
  let fixed = auth.with_mfa(identity, fixed)
  let renewing = auth.with_mfa(identity, renewing)
  assert auth.mfa_trust_seconds(identity) == mfa.default_trust_seconds
  assert auth.mfa_trust_seconds(fixed) == 3600
  assert !auth.mfa_trust_renewal(fixed)
  assert auth.mfa_trust_renewal(renewing)

  let session = signup(fixed, mailbox, "ada@example.com")
  let #(_, codes) = enroll(fixed, session)
  let assert [code, _, _, _] = codes
  let assert Ok(completed) =
    auth.verify_mfa(
      fixed,
      pending(fixed, mailbox),
      auth.RecoveryCode,
      secret.reveal(code),
      True,
    )
  let assert Some(device) = completed.trusted_device
  let device = secret.reveal(device)
  assert device_expiry(database) == 3600

  // Half the lifetime has passed. Using the device leaves a fixed expiry alone.
  exec(
    database,
    "UPDATE howdy_auth_trusted_devices SET created_at = created_at - 1800, expires_at = expires_at - 1800",
  )
  let assert Ok(_) =
    auth.use_trusted_device(fixed, pending(fixed, mailbox), device)
  assert device_expiry(database) == 3600
  let assert Ok(_) =
    auth.use_trusted_device(renewing, pending(renewing, mailbox), device)
  let renewed = device_expiry(database)
  assert renewed >= 5400 && renewed <= 5402

  // The browser keeps a renewed device exactly as long as the server does.
  let login = fn(identity) {
    let assert Ok(_) =
      auth.request_token(identity, "ada@example.com", auth.Login)
    let assert Ok(delivery) = process.receive(mailbox, 1000)
    testing.post(
      "/api/auth/session",
      json.object([#("token", json.string(secret.reveal(delivery.token)))]),
    )
    |> testing.header("origin", "https://example.test")
    |> testing.cookie("__Host-howdy_trusted", device)
    |> testing.send(support.app(identity, permissions))
  }
  let kept = login(fixed)
  assert kept.status == 200
  assert testing.cookies(kept)
    |> list.all(fn(c) { c.0 != "__Host-howdy_trusted" })
  let again = login(renewing)
  assert again.status == 200
  assert testing.cookies(again)
    |> list.contains(#("__Host-howdy_trusted", device))
  let assert Ok(header) =
    list.find(again.headers, fn(h) {
      h.0 == "set-cookie" && string.contains(h.1, "__Host-howdy_trusted")
    })
  assert string.contains(header.1, "Max-Age=3600")

  // An expired device is refused even when renewal is on.
  exec(database, "UPDATE howdy_auth_trusted_devices SET expires_at = 1")
  assert auth.use_trusted_device(renewing, pending(renewing, mailbox), device)
    == Error(service.Unauthorized)
}

fn subdomain(database, mailbox: process.Subject(auth.Delivery)) {
  let assert Ok(identity) =
    auth.new(database, "https://app.example.test", fn(delivery) {
      process.send(mailbox, delivery)
      Ok(Nil)
    })
  let assert Ok(identity) =
    auth.with_passkeys(auth.allow_registration(identity), "Howdy tests")
  identity
}

pub fn passkey_relying_party_must_cover_every_origin_test() {
  use database, identity, _, mailbox <- fixture
  assert result.is_error(
    auth.with_passkey_relying_party(identity, "example.test", []),
  )
  let identity = subdomain(database, mailbox)
  let rp = fn(id, origins) {
    auth.with_passkey_relying_party(identity, id, origins)
  }
  assert result.is_ok(rp("example.test", []))
  assert result.is_ok(rp(" Example.Test ", ["https://admin.example.test"]))
  assert result.is_ok(rp("app.example.test", []))
  assert result.is_error(rp("", []))
  assert result.is_error(rp(".test", []))
  assert result.is_error(rp("ample.test", []))
  assert result.is_error(rp("other.test", []))
  assert result.is_error(rp("admin.example.test", []))
  assert result.is_error(rp("example.test", ["https://example.test.evil.test"]))
  assert result.is_error(rp("example.test", ["http://admin.example.test"]))
  assert result.is_error(rp("example.test", ["https://admin.example.test/x"]))
}

pub fn parent_domain_passkeys_register_and_login_from_a_subdomain_test() {
  use database, _, _, mailbox <- fixture
  let exact = subdomain(database, mailbox)
  let session = signup(exact, mailbox, "ada@example.com")
  let keypair = authenticator.generate_es256_keypair()

  // The authenticator below is scoped to `example.test`. Without the parent
  // RP ID the subdomain deployment expects `app.example.test` and refuses it.
  let p = principal(exact, session)
  let assert Ok(start) = auth.begin_passkey_registration(exact, p, "Laptop")
  assert auth.finish_passkey_registration(
      exact,
      p,
      secret.reveal(start.challenge),
      registration_response(database, start, keypair, True)
        |> authenticator.to_registration_json,
    )
    == Error(service.Unauthorized)

  let assert Ok(shared) =
    auth.with_passkey_relying_party(exact, "example.test", [])
  let id = register(database, shared, session, keypair)
  let assert Ok(start) = auth.begin_passkey_login(shared)
  let response =
    assertion(database, start, keypair, id, session.user.id, 1)
    |> authenticator.to_authentication_json
  let assert Ok(auth.SignedIn(signed_in)) =
    auth.finish_passkey_login(
      shared,
      secret.reveal(start.challenge),
      response,
      "test",
    )
  assert signed_in.user.id == session.user.id

  // The same credential is refused where the RP ID is the exact hostname.
  let assert Ok(start) = auth.begin_passkey_login(exact)
  assert auth.finish_passkey_login(
      exact,
      secret.reveal(start.challenge),
      assertion(database, start, keypair, id, session.user.id, 2)
        |> authenticator.to_authentication_json,
      "test",
    )
    == Error(service.Unauthorized)
}

fn assertion_from(
  database,
  challenge,
  origin,
  keypair,
  credential_id,
  user_id,
  counter,
) {
  let assert Ok(c) = authentication.parse_challenge(state(database, challenge))
  let signed =
    assertion(database, challenge, keypair, credential_id, user_id, counter)
  let client_data_json =
    authenticator.build_client_data_get(
      challenge: authentication.challenge_data(c).bytes,
      origin:,
      cross_origin: False,
    )
  authenticator.AuthenticationResponse(
    ..signed,
    client_data_json:,
    signature: authenticator.sign_authentication_message(
      keypair,
      signed.authenticator_data,
      client_data_json,
    ),
  )
  |> authenticator.to_authentication_json
}

pub fn further_passkey_origins_are_accepted_only_when_listed_test() {
  use database, _, _, mailbox <- fixture
  let identity = subdomain(database, mailbox)
  let assert Ok(alone) =
    auth.with_passkey_relying_party(identity, "example.test", [])
  let assert Ok(listed) =
    auth.with_passkey_relying_party(identity, "example.test", [
      "https://admin.example.test",
    ])
  let session = signup(alone, mailbox, "ada@example.com")
  let keypair = authenticator.generate_es256_keypair()
  let id = register(database, alone, session, keypair)
  let attempt = fn(identity, origin, counter) {
    let assert Ok(start) = auth.begin_passkey_login(identity)
    auth.finish_passkey_login(
      identity,
      secret.reveal(start.challenge),
      assertion_from(
        database,
        start,
        origin,
        keypair,
        id,
        session.user.id,
        counter,
      ),
      "test",
    )
    |> result.is_ok
  }
  assert attempt(alone, "https://app.example.test", 1)
  assert !attempt(alone, "https://admin.example.test", 2)
  assert attempt(listed, "https://app.example.test", 3)
  assert attempt(listed, "https://admin.example.test", 4)
  assert !attempt(listed, "https://other.example.test", 5)
}

// Run the signed-out ceremony with a real keypair and return the credential id.
fn passkey_signup(database, identity, email, keypair) {
  let assert Ok(start) = auth.begin_passkey_signup(identity, email, "Laptop")
  let assert [_, _, ceremony] = string.split(state(database, start), "\n")
  let assert Ok(c) = registration.parse_challenge(ceremony)
  let response =
    authenticator.build_registration_response_with_keypair(c, keypair)
  let data =
    authenticator.build_registration_authenticator_data(
      "example.test",
      response.credential_id,
      authenticator.cose_key(keypair),
      authenticator.AuthenticatorFlags(True, True),
      0,
    )
  let encoded =
    authenticator.RegistrationResponse(
      ..response,
      attestation_object: authenticator.build_attestation_object(
        "none",
        data,
        [],
      ),
    )
    |> authenticator.to_registration_json
  #(start, encoded, response.credential_id)
}

pub fn passkey_signup_creates_the_account_only_when_the_email_is_verified_test() {
  use database, identity, _, mailbox <- fixture
  let identity = configured(identity)
  assert auth.passkey_signup_enabled(identity)
  let keypair = authenticator.generate_es256_keypair()
  let #(start, credential, id) =
    passkey_signup(database, identity, " Ada@Example.com ", keypair)
  assert auth.finish_passkey_signup(
      identity,
      secret.reveal(start.challenge),
      credential,
      "test",
    )
    == Ok(Nil)
  // The ceremony is single-use, and nothing exists until the inbox answers.
  assert auth.finish_passkey_signup(
      identity,
      secret.reveal(start.challenge),
      credential,
      "test",
    )
    == Error(service.Unauthorized)
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 0
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_passkeys") == 0
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert delivery.email == "ada@example.com"
  assert delivery.purpose == auth.Registration

  let assert Ok(session) =
    auth.exchange(identity, secret.reveal(delivery.token))
  let assert Ok([key]) = auth.passkeys(identity, principal(identity, session))
  assert key.id == bit_array.base64_url_encode(id, False)
  assert key.name == "Laptop"
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_events WHERE action = 'passkey.registered'",
    )
    == 1

  // The account was created under the ceremony's user handle, so the passkey
  // signs in to it.
  let assert Ok(login) = auth.begin_passkey_login(identity)
  let assert Ok(auth.SignedIn(signed_in)) =
    auth.finish_passkey_login(
      identity,
      secret.reveal(login.challenge),
      assertion(database, login, keypair, id, session.user.id, 1)
        |> authenticator.to_authentication_json,
      "test",
    )
  assert signed_in.user.id == session.user.id
}

pub fn passkey_signup_for_an_existing_address_keeps_nothing_and_says_nothing_test() {
  use database, identity, _, mailbox <- fixture
  let identity = configured(identity)
  let existing = signup(identity, mailbox, "ada@example.com")
  let keypair = authenticator.generate_es256_keypair()
  let #(start, credential, _) =
    passkey_signup(database, identity, "ada@example.com", keypair)
  // The caller sees the same answer as for a new address.
  assert auth.finish_passkey_signup(
      identity,
      secret.reveal(start.challenge),
      credential,
      "test",
    )
    == Ok(Nil)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert delivery.purpose == auth.AlreadyRegistered
  assert count(
      database,
      "SELECT COUNT(*) FROM howdy_auth_challenges WHERE passkey IS NOT NULL",
    )
    == 0
  let assert Ok(session) =
    auth.exchange(identity, secret.reveal(delivery.token))
  assert session.user.id == existing.user.id
  assert auth.passkeys(identity, principal(identity, session)) == Ok([])
}

pub fn passkey_signup_is_gated_verified_and_throttled_test() {
  use database, identity, _, mailbox <- fixture
  let keypair = authenticator.generate_es256_keypair()
  // Passkeys must be enabled, and so must registration.
  assert !auth.passkey_signup_enabled(identity)
  assert auth.begin_passkey_signup(identity, "ada@example.com", "Laptop")
    |> result.is_error
  let assert Ok(closed) =
    auth.new(database, "https://example.test", fn(_) { Ok(Nil) })
  let assert Ok(closed) = auth.with_passkeys(closed, "Howdy tests")
  assert !auth.passkey_signup_enabled(closed)
  assert auth.begin_passkey_signup(closed, "ada@example.com", "Laptop")
    == Error(service.Forbidden)

  let identity = configured(identity)
  assert auth.begin_passkey_signup(identity, "not an address", "Laptop")
    |> result.is_error
  assert auth.begin_passkey_signup(identity, "ada@example.com", "")
    |> result.is_error

  // A response for a different ceremony does not verify.
  let #(first, _, _) =
    passkey_signup(database, identity, "ada@example.com", keypair)
  let #(_, other, _) =
    passkey_signup(database, identity, "ada@example.com", keypair)
  assert auth.finish_passkey_signup(
      identity,
      secret.reveal(first.challenge),
      other,
      "test",
    )
    == Error(service.Unauthorized)
  assert process.receive(mailbox, 0) == Error(Nil)

  // A signup ceremony cannot be redeemed as a login, and trying does not
  // spend it.
  let #(start, credential, _) =
    passkey_signup(database, identity, "ada@example.com", keypair)
  assert auth.finish_passkey_login(
      identity,
      secret.reveal(start.challenge),
      credential,
      "test",
    )
    |> result.is_error
  assert auth.finish_passkey_signup(
      identity,
      secret.reveal(start.challenge),
      credential,
      "test",
    )
    == Ok(Nil)
  let assert Ok(_) = process.receive(mailbox, 1000)

  // Each completed signup emails the address, so it pays the same cooldown as
  // password registration.
  let finish = fn() {
    let #(start, credential, _) =
      passkey_signup(database, identity, "ada@example.com", keypair)
    auth.finish_passkey_signup(
      identity,
      secret.reveal(start.challenge),
      credential,
      "test",
    )
  }
  let assert Error(service.TooManyRequests(_)) = finish()
  assert process.receive(mailbox, 0) == Error(Nil)

  // Turning passkeys off strands a pending signup rather than half-creating it.
  let assert Ok(without) =
    auth.new(database, "https://example.test", fn(_) { Ok(Nil) })
  let without = auth.allow_registration(without)
  exec(database, "DELETE FROM howdy_auth_throttles")
  assert finish() == Ok(Nil)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert auth.exchange(without, secret.reveal(delivery.token))
    |> result.is_error
  assert count(database, "SELECT COUNT(*) FROM howdy_auth_users") == 0
}

pub fn passkey_signup_over_http_requires_origin_and_answers_202_test() {
  use database, identity, permissions, mailbox <- fixture
  let identity = configured(identity)
  let app = support.app(identity, permissions)
  let body =
    json.object([
      #("email", json.string("ada@example.com")),
      #("name", json.string("Laptop")),
    ])
  assert testing.post("/api/auth/passkeys/signup", body)
    |> testing.send(app)
    |> fn(r) { r.status }
    != 200
  let started =
    testing.post("/api/auth/passkeys/signup", body)
    |> testing.header("origin", "https://example.test")
    |> testing.send(app)
  assert started.status == 200
  let assert Ok(challenge) =
    json.parse(
      testing.text(started),
      decode.field("challenge", decode.string, decode.success),
    )
  let assert Ok([payload]) =
    repo.all(
      database,
      "SELECT payload FROM howdy_auth_ceremonies WHERE digest = $1",
      [sql.string(token.digest(challenge))],
      decode.field(0, decode.string, decode.success),
    )
  let assert [_, _, ceremony] = string.split(payload, "\n")
  let assert Ok(c) = registration.parse_challenge(ceremony)
  let keypair = authenticator.generate_es256_keypair()
  let response =
    authenticator.build_registration_response_with_keypair(c, keypair)
  let data =
    authenticator.build_registration_authenticator_data(
      "example.test",
      response.credential_id,
      authenticator.cose_key(keypair),
      authenticator.AuthenticatorFlags(True, True),
      0,
    )
  let credential =
    authenticator.RegistrationResponse(
      ..response,
      attestation_object: authenticator.build_attestation_object(
        "none",
        data,
        [],
      ),
    )
    |> authenticator.to_registration_json
  let confirmed =
    testing.post(
      "/api/auth/passkeys/signup/confirm",
      json.object([
        #("challenge", json.string(challenge)),
        #("credential", json.string(credential)),
      ]),
    )
    |> testing.header("origin", "https://example.test")
    |> testing.send(app)
  assert confirmed.status == 202
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  assert delivery.purpose == auth.Registration
  let page = testing.get("/auth/register") |> testing.send(app) |> testing.text
  assert string.contains(page, "passkey-signup")
  let login = testing.get("/auth/login") |> testing.send(app) |> testing.text
  assert string.contains(login, "username webauthn")
  assert !string.contains(login, "passkey-signup")
}

pub fn multi_session_keeps_the_current_account_while_another_passes_mfa_test() {
  use _, identity, permissions, mailbox <- fixture
  let assert Ok(identity) = auth.with_multi_session(configured(identity), 3)
  let ada = signup(identity, mailbox, "ada@example.com")
  let #(_, codes) = enroll(identity, ada)
  let bob = signup(identity, mailbox, "bob@example.com")
  let bob_token = secret.reveal(bob.token)
  let app = support.app(identity, permissions)
  let as_bob = fn(request) {
    request
    |> testing.header("origin", "https://example.test")
    |> testing.cookie("__Host-howdy_session", bob_token)
    |> testing.cookie("__Host-howdy_accounts", bob_token)
  }
  let assert Ok(_) = auth.request_token(identity, "ada@example.com", auth.Login)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let started =
    testing.post(
      "/api/auth/session",
      json.object([#("token", json.string(secret.reveal(delivery.token)))]),
    )
    |> as_bob
    |> testing.send(app)
  assert started.status == 202
  // Bob stays signed in, in the browser and on the server, and Ada's pending
  // challenge has joined nothing yet.
  assert testing.cookies(started)
    |> list.all(fn(c) { c.0 == "__Host-howdy_mfa" })
  assert result.is_ok(auth.authenticate(identity, bob_token))
  let assert Ok(#(_, challenge)) =
    testing.cookies(started) |> list.find(fn(c) { c.0 == "__Host-howdy_mfa" })
  let assert [code, ..] = codes
  let verified =
    testing.post(
      "/api/auth/mfa/verify",
      json.object([
        #("method", json.string("recovery")),
        #("code", json.string(secret.reveal(code))),
        #("remember", json.bool(False)),
      ]),
    )
    |> as_bob
    |> testing.cookie("__Host-howdy_mfa", challenge)
    |> testing.send(app)
  assert verified.status == 200
  let assert Ok(#(_, active)) =
    testing.cookies(verified)
    |> list.find(fn(c) { c.0 == "__Host-howdy_session" })
  let assert Ok(#(_, held)) =
    testing.cookies(verified)
    |> list.find(fn(c) { c.0 == "__Host-howdy_accounts" })
  assert held == bob_token <> "." <> active
  assert result.is_ok(auth.authenticate(identity, bob_token))
  let assert Ok(p) = auth.authenticate(identity, active)
  assert p.user.email == "ada@example.com"
}

pub fn mfa_key_rotates_without_failing_a_sign_in_test() {
  use database, identity, _, mailbox <- fixture
  let old = token.new()
  let new = token.new()
  let assert Ok(before) = mfa.new("Howdy tests", old)
  let assert Ok(identity) = auth.with_passkeys(identity, "Howdy tests")
  let session = signup(identity, mailbox, "ada@example.com")
  let #(seed, _) = enroll(auth.with_mfa(identity, before), session)
  let other = signup(identity, mailbox, "grace@example.com")
  let assert Ok(setup) =
    auth.begin_mfa(
      auth.with_mfa(identity, before),
      principal(identity, other),
      auth.Totp,
    )
  let secrets = fn() {
    let assert Ok(values) =
      repo.all(
        database,
        "SELECT secret FROM howdy_auth_mfa UNION ALL SELECT payload FROM howdy_auth_ceremonies WHERE kind = 'mfa-setup'",
        [],
        decode.field(0, decode.string, decode.success),
      )
    values
  }
  let original = secrets()

  // Step 1: every node learns the new key before any seals with it.
  let assert Ok(learning) = mfa.with_decryption_keys(before, [new])
  assert auth.reseal_mfa(auth.with_mfa(identity, learning)) == Ok(0)
  assert secrets() == original

  // Step 2: the new key seals; the old one still opens.
  let assert Ok(after) = mfa.new("Howdy tests", new)
  let assert Ok(rotating) = mfa.with_decryption_keys(after, [old])
  let rotating = auth.with_mfa(identity, rotating)
  let assert Error(service.Internal(_)) =
    auth.reseal_mfa(auth.with_mfa(identity, after))
  let challenge = pending(rotating, mailbox)
  let assert Ok(_) =
    auth.verify_mfa(
      rotating,
      challenge,
      auth.Totp,
      totp_code(seed, token.now() + 30),
      False,
    )

  // Step 3: reseal, then the old key can go.
  assert auth.reseal_mfa(rotating) == Ok(2)
  assert auth.reseal_mfa(rotating) == Ok(0)
  let resealed = secrets()
  assert list.all(resealed, fn(value) { !list.contains(original, value) })
  let finished = auth.with_mfa(identity, after)
  assert auth.reseal_mfa(finished) == Ok(0)
  // Only the replay fence stops the same code working twice.
  exec(database, "UPDATE howdy_auth_mfa SET last_step = -1")
  let challenge = pending(finished, mailbox)
  let assert Ok(_) =
    auth.verify_mfa(
      finished,
      challenge,
      auth.Totp,
      totp_code(seed, token.now()),
      False,
    )
  let assert Some(key) = setup.key
  let assert Ok(_) =
    auth.confirm_mfa(
      finished,
      principal(identity, other),
      secret.reveal(setup.challenge),
      totp_code(secret.reveal(key), token.now()),
    )
  assert mfa.with_decryption_keys(after, [old, "too-short"])
    |> result.is_error
}

pub fn digest_comparisons_are_constant_time_and_exact_test() {
  let a = token.digest("one")
  let b = token.digest("two")
  assert token.constant_time_equal(a, a)
  assert token.constant_time_equal("", "")
  assert !token.constant_time_equal(a, b)
  // Unequal lengths are unequal, never an error.
  assert !token.constant_time_equal(a, a <> "x")
  assert !token.constant_time_equal("", a)
  // Content, not prefix.
  assert !token.constant_time_equal("abc", "abd")
  assert token.constant_time_equal("héllo", "héllo")
}

pub fn provider_paths_are_plain_absolute_paths_test() {
  list.each(["/", "/account", "/auth/callback", "/a-b_c/D9"], fn(path) {
    assert auth.provider_path(path)
  })
  // Protocol-relative, backslash, query, fragment, space, scheme and
  // relative forms would all leave the site or change routing.
  list.each(
    [
      "",
      "//evil.example",
      "//evil.example/account",
      "/\\evil.example",
      "\\evil.example",
      "/account?next=x",
      "/account#frag",
      "/account with space",
      "/account%2F..",
      "https://evil.example",
      "account",
      "/account/../admin",
    ],
    fn(path) {
      assert !auth.provider_path(path)
    },
  )
}
