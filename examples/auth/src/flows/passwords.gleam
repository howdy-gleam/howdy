//// Email and password sign-in, alongside email tokens.
////
//// Passwords are an alternative way in, not a second factor: anyone can still
//// sign in by email, which is also how a forgotten password is reset. A new
//// account is created only once its address is verified, so registering with
//// a password still sends a token.
////
////     gleam run -m migrate
////     gleam run -m flows/passwords
////
//// Register at http://localhost:8787/auth/password/register, paste the token
//// printed in the terminal, then sign in at /auth/password/login. The account
//// page, /auth/account, changes the password.

import database
import demo
import gloo/repo.{type Repo}
import howdy
import howdy/auth
import howdy/auth/pages
import howdy/auth/password_check
import howdy/auth/policy
import howdy/auth/routes
import howdy/auth/user
import howdy/controller

pub const database_file = "passwords.sqlite"

/// Passwords your users must not choose. A real application loads a
/// maintained breach corpus here; the checker keeps only digests and never
/// sends a password anywhere.
const denied = ["howdy password 2026!", "letmein letmein letmein"]

pub fn configure(
  db: Repo,
  deliver: fn(auth.Delivery) -> Result(Nil, Nil),
) -> auth.Auth {
  let assert Ok(identity) = auth.new(repo: db, origin: demo.origin, deliver:)
  let identity = auth.allow_registration(identity)
  let assert Ok(identity) = auth.with_passwords(identity)
  // Screened as well as the built-in common-password and shape checks.
  let identity =
    auth.with_password_check(identity, password_check.blocklist(denied))
  // Keep returning users signed in: a session lasts a week from its last
  // renewal, renews at most daily while used, and never beyond 90 days.
  let assert Ok(identity) =
    auth.with_policy(
      identity,
      policy.Policy(
        ..policy.default(),
        session_seconds: 604_800,
        session_renew_seconds: 86_400,
        session_max_seconds: 7_776_000,
      ),
    )
  identity
}

pub fn app(identity: auth.Auth) -> howdy.App {
  let account =
    controller.guarded("/account", auth.required(identity))
    |> controller.get("/me", fn(ctx) {
      controller.json(ctx, user.to_json(ctx.guard.user))
    })
    |> controller.build()

  // The same routes as email tokens: password endpoints and pages appear
  // because `with_passwords` is on.
  howdy.new()
  |> howdy.controller(routes.api(identity, at: "/api/auth"))
  |> howdy.controller(pages.routes(identity, at: "/auth", api_at: "/api/auth"))
  |> howdy.controller(account)
}

pub fn main() {
  let db = database.open(database_file)
  configure(db, demo.print_email) |> app |> demo.serve
}
