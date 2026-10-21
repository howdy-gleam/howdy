//// Passwordless sign-in with emailed tokens: the smallest useful setup.
////
//// Someone enters their address, receives an email and proves they read it:
//// by opening its link, typing its six-digit code, or pasting its token.
//// Registration and sign-in are the same two steps. The same
//// exchange serves browsers (an HttpOnly session cookie) and native clients
//// (a bearer token), and `auth.required` accepts either.
////
////     gleam run -m migrate
////     gleam run -m flows/email_tokens
////
//// Open http://localhost:8787/auth/register, open the link printed in the
//// terminal (or type its code), then visit http://localhost:8787/account/me.

import database
import demo
import gloo/repo.{type Repo}
import howdy
import howdy/auth
import howdy/auth/pages
import howdy/auth/routes
import howdy/auth/user
import howdy/controller

pub const database_file = "email_tokens.sqlite"

/// Auth is configured once, at startup, from the application's Repo and a
/// function that emails tokens.
pub fn configure(
  db: Repo,
  deliver: fn(auth.Delivery) -> Result(Nil, Nil),
) -> auth.Auth {
  let assert Ok(identity) = auth.new(repo: db, origin: demo.origin, deliver:)
  // Registration is off until you say otherwise. Without it, only accounts
  // created by trusted code (`auth.provision`) can sign in.
  let identity = auth.allow_registration(identity)
  // Each email also gets a link to the starter pages mounted below, and a
  // short code to type instead of pasting the token.
  let assert Ok(identity) = auth.with_email_links(identity, at: "/auth")
  auth.with_email_codes(identity)
}

pub fn app(identity: auth.Auth) -> howdy.App {
  // Everything under /account needs a signed-in user; handlers read it from
  // `ctx.guard`, already verified.
  let account =
    controller.guarded("/account", auth.required(identity))
    |> controller.get("/me", fn(ctx) {
      controller.json(ctx, user.to_json(ctx.guard.user))
    })
    |> controller.build()

  howdy.new()
  // The JSON API: /register, /login, /session (cookie), /token (bearer), ...
  |> howdy.controller(routes.api(identity, at: "/api/auth"))
  // Optional starter pages that call that API. Omit them to bring your own.
  |> howdy.controller(pages.routes(identity, at: "/auth", api_at: "/api/auth"))
  |> howdy.controller(account)
}

pub fn main() {
  let db = database.open(database_file)
  configure(db, demo.print_email) |> app |> demo.serve
}
