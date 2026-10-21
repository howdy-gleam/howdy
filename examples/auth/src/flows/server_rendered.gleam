//// Your own pages and transport, on the headless API.
////
//// No `routes.api`, no starter pages and no JavaScript: plain HTML forms call
//// `auth.request_token_from`, `auth.exchange_step`, `auth.logout` and friends
//// directly, and this module owns the cookie, the redirects and the markup.
//// The same headless functions serve any other transport too: a CLI, a
//// WebSocket, an RPC service.
////
//// Owning the transport means owning what the bundled routes would have done:
//// - Check Origin on every form POST (`auth.check_origin`). `auth.required`
////   already does for cookie-authenticated writes.
//// - Set the session cookie exactly as the bundled routes do: the name
////   `auth.cookie_name`, HttpOnly, SameSite=Lax, Secure outside loopback.
//// - Pass the client address to the `_from` variants for throttling and audit,
////   and rate-limit these routes as a whole (see `howdy/rate_limit`).
//// - Never write on GET, and never put a token in a URL.
////
////     gleam run -m migrate
////     gleam run -m flows/server_rendered
////
//// Then open http://localhost:8787/.

import database
import demo
import gleam/http/response
import gleam/list
import gleam/option
import gleam/string
import gloo/repo.{type Repo}
import howdy
import howdy/auth
import howdy/auth/secret
import howdy/context
import howdy/controller.{type Context}
import howdy/cookie
import howdy/form
import howdy/service

pub const database_file = "server_rendered.sqlite"

pub fn configure(
  db: Repo,
  deliver: fn(auth.Delivery) -> Result(Nil, Nil),
) -> auth.Auth {
  let assert Ok(identity) = auth.new(repo: db, origin: demo.origin, deliver:)
  auth.allow_registration(identity)
}

pub fn app(identity: auth.Auth) -> howdy.App {
  let pages =
    controller.new("/")
    |> controller.get("/", fn(ctx) {
      case auth.required(identity)(ctx) {
        Ok(principal) -> page(ctx, home(principal.user.email))
        Error(_) -> page(ctx, sign_in(""))
      }
    })
    // Step one: email a token. "Sign in" and "Create account" differ only in
    // the intent, and the reply is the same whether or not the address has an
    // account, so this page reveals nothing about who is registered.
    |> controller.post("/login", fn(ctx) {
      use <- same_origin(identity, ctx)
      use submitted <- form.read(ctx)
      let intent = case form.value(submitted, "intent") {
        "register" -> auth.Register
        _ -> auth.Login
      }
      let email = form.value(submitted, "email")
      case auth.request_token_from(identity, email, intent, client(ctx)) {
        Ok(Nil) -> page(ctx, enter_token(email, ""))
        Error(service.TooManyRequests(_)) ->
          page(ctx, sign_in("Too many requests. Wait a minute and try again."))
        Error(_) -> page(ctx, sign_in("Enter a valid email address."))
      }
    })
    // Step two: exchange it for a session. Tokens only ever travel by POST.
    |> controller.post("/login/token", fn(ctx) {
      use <- same_origin(identity, ctx)
      use submitted <- form.read(ctx)
      let token = string.trim(form.value(submitted, "token"))
      case auth.exchange_step(identity, token, client(ctx)) {
        Ok(auth.SignedIn(session)) ->
          redirect(ctx, "/")
          |> cookie.set(
            auth.cookie_name(identity),
            secret.reveal(session.token),
            session_cookie(identity)
              |> cookie.max_age(auth.session_cookie_seconds(identity)),
          )
        // Only accounts that enrolled a factor get here, and this application
        // does not enable MFA. With it on, keep `challenge.token` in a short
        // HttpOnly cookie and complete it with `auth.verify_mfa`; see
        // flows/passkeys_and_mfa for the bundled version of that flow.
        Ok(auth.SecondFactor(_challenge)) ->
          page(ctx, sign_in("This account needs a second factor."))
        // Spent, expired, mistyped, or a suspended account: all look the same.
        Error(_) ->
          page(
            ctx,
            enter_token("", "That token did not work. Request another."),
          )
      }
    })
    |> controller.build()

  // Signed-in routes. Unlike the JSON guard, an HTML page sends anyone who is
  // not signed in back to the start rather than answering 401.
  let account =
    controller.new("/account")
    |> controller.get("/sessions", fn(ctx) {
      use principal <- signed_in(identity, ctx)
      case auth.sessions(identity, principal) {
        Ok(sessions) -> page(ctx, sessions_page(sessions))
        Error(error) -> service.error_response(ctx, error)
      }
    })
    |> controller.post("/sessions/revoke", fn(ctx) {
      use principal <- signed_in(identity, ctx)
      use submitted <- form.read(ctx)
      // Ids are digests: they name a session but cannot sign in as it, and
      // only the caller's own sessions are ever revoked.
      let _ =
        auth.revoke_session(identity, principal, form.value(submitted, "id"))
      redirect(ctx, "/account/sessions")
    })
    |> controller.post("/logout", fn(ctx) {
      use principal <- signed_in(identity, ctx)
      let _ = auth.logout(identity, principal)
      redirect(ctx, "/")
      |> cookie.delete(auth.cookie_name(identity), session_cookie(identity))
    })
    |> controller.build()

  howdy.new()
  |> howdy.controller(pages)
  |> howdy.controller(account)
}

pub fn main() {
  let db = database.open(database_file)
  configure(db, demo.print_email) |> app |> demo.serve
}

// --- Transport ---------------------------------------------------------------

/// Cross-site form posts are refused before anything else happens.
fn same_origin(identity: auth.Auth, ctx: Context, next) {
  case auth.check_origin(identity, ctx) {
    Ok(Nil) -> next()
    Error(error) -> service.error_response(ctx, error)
  }
}

/// `auth.required` reads the cookie (or a bearer token), checks Origin on
/// writes and verifies the session against the database.
fn signed_in(identity: auth.Auth, ctx: Context, next) {
  case auth.required(identity)(ctx) {
    Ok(principal) -> next(principal)
    Error(service.Forbidden) -> service.error_response(ctx, service.Forbidden)
    Error(_) -> redirect(ctx, "/")
  }
}

fn session_cookie(identity: auth.Auth) -> cookie.Options {
  cookie.defaults() |> cookie.secure(auth.secure(identity))
}

fn client(ctx: Context) -> String {
  context.client_ip(ctx.request) |> option.unwrap("")
}

fn redirect(ctx: Context, to: String) {
  controller.status(ctx, 303) |> response.set_header("location", to)
}

// --- Markup ------------------------------------------------------------------

fn page(ctx: Context, body: String) {
  controller.html(
    ctx,
    "<!doctype html><html><head><meta charset=\"utf-8\"><title>Howdy</title></head><body>"
      <> body
      <> "</body></html>",
  )
  |> response.set_header("cache-control", "no-store")
}

fn sign_in(message: String) -> String {
  notice(message)
  <> "<h1>Sign in</h1><form method=\"post\" action=\"/login\">"
  <> "<label>Email <input type=\"email\" name=\"email\" autocomplete=\"email\" required></label>"
  <> "<button name=\"intent\" value=\"login\">Sign in</button>"
  <> "<button name=\"intent\" value=\"register\">Create account</button></form>"
}

fn enter_token(email: String, message: String) -> String {
  let sent = case email {
    "" -> ""
    _ -> "<p>If " <> escape(email) <> " can sign in, a token is on its way.</p>"
  }
  notice(message)
  <> "<h1>Check your email</h1>"
  <> sent
  <> "<form method=\"post\" action=\"/login/token\">"
  <> "<label>Token <input name=\"token\" autocomplete=\"one-time-code\" required></label>"
  <> "<button>Continue</button></form><p><a href=\"/\">Start again</a></p>"
}

fn home(email: String) -> String {
  "<h1>Signed in as "
  <> escape(email)
  <> "</h1><p><a href=\"/account/sessions\">Your sessions</a></p>"
  <> "<form method=\"post\" action=\"/account/logout\"><button>Sign out</button></form>"
}

fn sessions_page(sessions: List(auth.SessionInfo)) -> String {
  "<h1>Your sessions</h1><ul>"
  <> string.concat(
    list.map(sessions, fn(session) {
      let label = case session.current {
        True -> " (this browser)"
        False -> ""
      }
      "<li>Signed in from "
      <> escape(session.client)
      <> label
      <> "<form method=\"post\" action=\"/account/sessions/revoke\">"
      <> "<input type=\"hidden\" name=\"id\" value=\""
      <> escape(session.id)
      <> "\"><button>Sign out</button></form></li>"
    }),
  )
  <> "</ul><p><a href=\"/\">Home</a></p>"
}

fn notice(message: String) -> String {
  case message {
    "" -> ""
    _ -> "<p role=\"alert\">" <> escape(message) <> "</p>"
  }
}

fn escape(text: String) -> String {
  text
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
  |> string.replace("'", "&#39;")
}
