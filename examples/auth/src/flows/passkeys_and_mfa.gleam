//// Passkeys, and a second factor after any primary sign-in.
////
//// Passkeys are a primary way in: WebAuthn, discoverable, offered through the
//// browser's autofill, and usable to create an account that never has a
//// password. MFA is separate: once someone enrolls a factor, every sign-in
//// (email token, password, provider or passkey) needs it too.
////
//// The MFA key encrypts authenticator secrets at rest. Generate it **once**,
//// keep it outside the database and supply it on every start; a different key
//// cannot read existing enrollments.
////
////     export HOWDY_AUTH_MFA_KEY=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')
////     gleam run -m migrate
////     gleam run -m flows/passkeys_and_mfa
////
//// Register at http://localhost:8787/auth/password/register, then on
//// /auth/account add a passkey, and enroll an authenticator app (or a code
//// "delivered" to this terminal). Sign out and back in to see each step.

import database
import demo
import gleam/io
import gloo/repo.{type Repo}
import howdy
import howdy/auth
import howdy/auth/mfa
import howdy/auth/pages
import howdy/auth/routes
import howdy/auth/secret
import howdy/auth/user.{type User}
import howdy/controller

pub const database_file = "passkeys_and_mfa.sqlite"

pub fn configure(
  db: Repo,
  deliver: fn(auth.Delivery) -> Result(Nil, Nil),
  mfa_key mfa_key: String,
  send_code send_code: fn(User, secret.Secret) -> Result(Nil, Nil),
) -> auth.Auth {
  let assert Ok(identity) = auth.new(repo: db, origin: demo.origin, deliver:)
  let identity = auth.allow_registration(identity)
  let assert Ok(identity) = auth.with_passwords(identity)
  // The name is what authenticators show next to the saved passkey. The
  // relying-party ID defaults to the origin's host; to share passkeys across
  // subdomains, see `auth.with_passkey_relying_party`, and decide before launch.
  // With registration and email tokens on, this also enables passkey signup.
  let assert Ok(identity) = auth.with_passkeys(identity, "Howdy passkeys demo")

  let assert Ok(config) = mfa.new("Howdy passkeys demo", mfa_key)
  // Optional: codes sent to a contact your application has verified, as a
  // factor or a fallback for TOTP. Never take the destination from a request.
  // Not offered after an email-token sign-in, which would be one inbox twice.
  let config = mfa.with_delivery(config, send_code)
  // "Remember this device" skips the second factor for a week from its last use.
  let assert Ok(config) =
    mfa.with_device_trust(config, seconds: 604_800, renew: True)
  auth.with_mfa(identity, config)
}

pub fn app(identity: auth.Auth) -> howdy.App {
  // `auth.required` refuses a sign-in still waiting for its second factor, so
  // application routes need nothing extra.
  let account =
    controller.guarded("/account", auth.required(identity))
    |> controller.get("/me", fn(ctx) {
      controller.json(ctx, user.to_json(ctx.guard.user))
    })
    |> controller.build()

  // The API gains /passkeys/... and /mfa/...; the pages gain the matching
  // buttons, and /auth/mfa, where a pending sign-in completes its factor.
  howdy.new()
  |> howdy.controller(routes.api(identity, at: "/api/auth"))
  |> howdy.controller(pages.routes(identity, at: "/auth", api_at: "/api/auth"))
  |> howdy.controller(account)
}

/// Stands in for an SMS or authenticator push. Local demonstration only.
fn print_code(user: User, code: secret.Secret) -> Result(Nil, Nil) {
  io.println(
    "LOCAL DEMO sign-in code for " <> user.email <> ": " <> secret.reveal(code),
  )
  Ok(Nil)
}

pub fn main() {
  case demo.env("HOWDY_AUTH_MFA_KEY") {
    Error(_) ->
      io.println(
        "Set HOWDY_AUTH_MFA_KEY first; see the top of src/flows/passkeys_and_mfa.gleam.",
      )
    Ok(mfa_key) -> {
      let db = database.open(database_file)
      configure(db, demo.print_email, mfa_key:, send_code: print_code)
      |> app
      |> demo.serve
    }
  }
}
