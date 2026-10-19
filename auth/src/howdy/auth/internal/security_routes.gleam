//// JSON transport for passkeys and MFA, under the main auth API's Origin,
//// content-type and no-store middleware and its shared rate-limit budgets.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import howdy/auth
import howdy/auth/internal/codes
import howdy/auth/internal/login_transport as login
import howdy/auth/passkey
import howdy/auth/secret
import howdy/body
import howdy/controller
import howdy/guard
import howdy/locale
import howdy/service

pub fn add(
  routes: controller.Controller,
  identity: auth.Auth,
  strict: fn(controller.Handler) -> controller.Handler,
  signed_in: fn(controller.Handler) -> controller.Handler,
  required,
  client,
) -> controller.Controller {
  routes
  |> controller.get(
    "/security",
    signed_in(fn(ctx) {
      use principal <- guard.require(ctx, required)
      auth.mfa_status(identity, principal)
      |> service.respond(ctx, fn(status) {
        json.object([
          #("mfa", json.nullable(status, json.string)),
          #("mfa_available", json.bool(auth.mfa_enabled(identity))),
          #("passkeys_available", json.bool(auth.passkeys_enabled(identity))),
        ])
      })
    }),
  )
  |> controller.get(
    "/passkeys",
    signed_in(fn(ctx) {
      use principal <- guard.require(ctx, required)
      auth.passkeys(identity, principal)
      |> service.respond(ctx, json.array(_, key_json))
    }),
  )
  |> controller.post(
    "/passkeys/register",
    strict(fn(ctx) {
      use principal <- guard.require(ctx, required)
      use name <- body.json_with_limit(ctx, 4096, field("name"))
      auth.begin_passkey_registration(identity, principal, name)
      |> service.respond(ctx, challenge_json)
    }),
  )
  |> controller.post(
    "/passkeys/register/confirm",
    strict(fn(ctx) {
      use principal <- guard.require(ctx, required)
      use #(challenge, credential) <- body.json_with_limit(
        ctx,
        70_000,
        credential(),
      )
      auth.finish_passkey_registration(
        identity,
        principal,
        challenge,
        credential,
      )
      |> service.no_content(ctx)
    }),
  )
  |> controller.post(
    "/passkeys/signup",
    strict(fn(ctx) {
      use _ <- guard.require(ctx, fn(ctx) { auth.check_origin(identity, ctx) })
      use #(email, name, group) <- body.json_with_limit(ctx, 4096, {
        use email <- decode.field("email", decode.string)
        use name <- decode.field("name", decode.string)
        use group <- decode.optional_field(
          "group",
          None,
          decode.optional(decode.string),
        )
        decode.success(#(email, name, group))
      })
      let scoped = case auth.bound_group(identity), group {
        None, Some(g) -> auth.in_group(identity, g)
        _, _ -> identity
      }
      auth.begin_passkey_signup(scoped, email, name)
      |> service.respond(ctx, challenge_json)
    }),
  )
  |> controller.post(
    "/passkeys/signup/confirm",
    strict(fn(ctx) {
      use _ <- guard.require(ctx, fn(ctx) { auth.check_origin(identity, ctx) })
      use #(challenge, credential) <- body.json_with_limit(
        ctx,
        70_000,
        credential(),
      )
      case
        auth.finish_passkey_signup(
          auth.in_locale(
            identity,
            locale.to_string(auth.request_locale(identity, ctx)),
          ),
          challenge,
          credential,
          client(ctx),
        )
      {
        Ok(Nil) ->
          controller.json(
            ctx,
            codes.message(
              "signup_token_sent",
              "Check your email for a token to finish creating your account.",
            ),
          )
          |> controller.with_status(202)
        Error(error) -> service.error_response(ctx, error)
      }
    }),
  )
  |> controller.post(
    "/passkeys/login",
    strict(fn(ctx) {
      use _ <- guard.require(ctx, fn(ctx) { auth.check_origin(identity, ctx) })
      use group <- body.json_with_limit(
        ctx,
        4096,
        decode.optional_field(
          "group",
          None,
          decode.optional(decode.string),
          decode.success,
        ),
      )
      let scoped = case auth.bound_group(identity), group {
        None, Some(g) -> auth.in_group(identity, g)
        _, _ -> identity
      }
      auth.begin_passkey_login(scoped) |> service.respond(ctx, challenge_json)
    }),
  )
  |> controller.post(
    "/passkeys/session",
    strict(fn(ctx) {
      use _ <- guard.require(ctx, fn(ctx) { auth.check_origin(identity, ctx) })
      use #(challenge, credential) <- body.json_with_limit(
        ctx,
        70_000,
        credential(),
      )
      login.browser(
        identity,
        ctx,
        auth.finish_passkey_login(identity, challenge, credential, client(ctx)),
        required,
      )
    }),
  )
  |> controller.post(
    "/passkeys/rename",
    strict(fn(ctx) {
      use principal <- guard.require(ctx, required)
      use #(id, name) <- body.json_with_limit(ctx, 4096, pair("id", "name"))
      auth.rename_passkey(identity, principal, id, name)
      |> service.no_content(ctx)
    }),
  )
  |> controller.post(
    "/passkeys/delete",
    strict(fn(ctx) {
      use principal <- guard.require(ctx, required)
      use id <- body.json_with_limit(ctx, 4096, field("id"))
      retire(identity, ctx, auth.delete_passkey(identity, principal, id))
    }),
  )
  |> controller.post(
    "/mfa/enroll",
    strict(fn(ctx) {
      use principal <- guard.require(ctx, required)
      use method <- body.json_with_limit(ctx, 4096, method())
      auth.begin_mfa(identity, principal, method)
      |> service.respond(ctx, fn(setup) {
        json.object([
          #("challenge", json.string(secret.reveal(setup.challenge))),
          #(
            "key",
            json.nullable(setup.key, fn(s) { json.string(secret.reveal(s)) }),
          ),
          #(
            "uri",
            json.nullable(setup.uri, fn(s) { json.string(secret.reveal(s)) }),
          ),
          #(
            "qr_code",
            json.nullable(setup.qr_code, fn(s) { json.string(secret.reveal(s)) }),
          ),
        ])
      })
    }),
  )
  |> controller.post(
    "/mfa/enroll/confirm",
    strict(fn(ctx) {
      use principal <- guard.require(ctx, required)
      use #(challenge, code) <- body.json_with_limit(
        ctx,
        4096,
        pair("challenge", "code"),
      )
      codes(
        identity,
        ctx,
        auth.confirm_mfa(identity, principal, challenge, code),
      )
    }),
  )
  |> controller.post(
    "/mfa/send",
    strict(fn(ctx) {
      use _ <- body.json_with_limit(ctx, 4096, decode.dynamic)
      use challenge <- guard.require(ctx, login.challenge(identity, _))
      auth.send_mfa_code(identity, challenge) |> service.no_content(ctx)
    }),
  )
  |> controller.post(
    "/mfa/verify",
    strict(fn(ctx) {
      use challenge <- guard.require(ctx, login.challenge(identity, _))
      use #(method, code, remember) <- body.json_with_limit(
        ctx,
        4096,
        verification(),
      )
      login.completed(
        identity,
        ctx,
        auth.verify_mfa(identity, challenge, method, code, remember),
        required,
      )
    }),
  )
  |> controller.post(
    "/mfa/token",
    strict(fn(ctx) {
      use #(challenge, verification) <- body.json_with_limit(ctx, 4096, {
        use challenge <- decode.field("challenge", decode.string)
        use verification <- decode.then(verification())
        decode.success(#(challenge, verification))
      })
      let #(method, code, remember) = verification
      auth.verify_mfa(identity, challenge, method, code, remember)
      |> service.respond(ctx, fn(completed) {
        json.object([
          #("session", login.token_json(identity, completed.session)),
          #(
            "trusted_device",
            json.nullable(completed.trusted_device, fn(s) {
              json.string(secret.reveal(s))
            }),
          ),
        ])
      })
    }),
  )
  |> controller.post(
    "/mfa/token/send",
    strict(fn(ctx) {
      use challenge <- body.json_with_limit(ctx, 4096, field("challenge"))
      auth.send_mfa_code(identity, challenge) |> service.no_content(ctx)
    }),
  )
  |> controller.post(
    "/mfa/disable",
    strict(fn(ctx) {
      use principal <- guard.require(ctx, required)
      use _ <- body.json_with_limit(ctx, 4096, decode.dynamic)
      retire(identity, ctx, auth.disable_mfa(identity, principal))
    }),
  )
  |> controller.post(
    "/mfa/recovery",
    strict(fn(ctx) {
      use principal <- guard.require(ctx, required)
      use _ <- body.json_with_limit(ctx, 4096, decode.dynamic)
      codes(identity, ctx, auth.regenerate_recovery_codes(identity, principal))
    }),
  )
  |> controller.get(
    "/mfa/devices",
    signed_in(fn(ctx) {
      use principal <- guard.require(ctx, required)
      auth.trusted_devices(identity, principal)
      |> service.respond(
        ctx,
        json.array(_, fn(device) {
          json.object([
            #("id", json.string(device.0)),
            #("created_at", json.int(device.1)),
            #("expires_at", json.int(device.2)),
          ])
        }),
      )
    }),
  )
  |> controller.post(
    "/mfa/devices/revoke",
    strict(fn(ctx) {
      use principal <- guard.require(ctx, required)
      use id <- body.json_with_limit(ctx, 4096, field("id"))
      auth.revoke_trusted_device(identity, principal, id)
      |> service.no_content(ctx)
    }),
  )
}

fn field(name: String) {
  decode.field(name, decode.string, decode.success)
}

fn pair(a: String, b: String) {
  use a <- decode.field(a, decode.string)
  use b <- decode.field(b, decode.string)
  decode.success(#(a, b))
}

fn credential() {
  pair("challenge", "credential")
}

fn method() {
  use name <- decode.field("method", decode.string)
  case name {
    "totp" -> decode.success(auth.Totp)
    "otp" -> decode.success(auth.DeliveredCode)
    "recovery" -> decode.success(auth.RecoveryCode)
    _ -> decode.failure(auth.Totp, "totp, otp or recovery")
  }
}

fn verification() {
  use method <- decode.then(method())
  use code <- decode.field("code", decode.string)
  use remember <- decode.optional_field("remember", False, decode.bool)
  decode.success(#(method, code, remember))
}

fn challenge_json(challenge: auth.PasskeyChallenge) {
  json.object([
    #("challenge", json.string(secret.reveal(challenge.challenge))),
    #("options", challenge.options),
  ])
}

fn key_json(key: passkey.Passkey) {
  json.object([
    #("id", json.string(key.id)),
    #("name", json.string(key.name)),
    #("created_at", json.int(key.created_at)),
    #("aaguid", json.string(key.aaguid)),
    #("backup_eligible", json.bool(key.backup_eligible)),
    #("backed_up", json.bool(key.backed_up)),
  ])
}

fn retire(identity: auth.Auth, ctx, answer) {
  case answer {
    Ok(Nil) ->
      service.no_content(answer, ctx) |> login.signed_out(identity, ctx, _)
    Error(error) -> service.error_response(ctx, error)
  }
}

fn codes(
  identity: auth.Auth,
  ctx,
  answer: service.Result(List(secret.Secret)),
) {
  case answer {
    Ok(codes) ->
      controller.json(
        ctx,
        json.object([
          #(
            "recovery_codes",
            json.array(codes, fn(code) { json.string(secret.reveal(code)) }),
          ),
        ]),
      )
      |> login.signed_out(identity, ctx, _)
    Error(error) -> service.error_response(ctx, error)
  }
}
