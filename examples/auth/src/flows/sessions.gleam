//// Session behaviour: lifetimes, several accounts in one browser, and
//// keeping sessions outside the database.
////
//// - **Lifetimes.** Sessions renew while in use, end after two idle days, and
////   never outlive 90 days.
//// - **Multi-session.** Signing in while signed in adds an account instead of
////   replacing it; the account page lists them with Switch buttons.
//// - **An external store.** `session_store.memory()` stands in for Redis or
////   similar, wrapped to print each call so you can watch what a store does.
////   Users, credentials and suspension stay in the database either way.
////
////     gleam run -m migrate
////     gleam run -m flows/sessions
////
//// Register two addresses at http://localhost:8787/auth/register in the same
//// browser, then switch between them on /auth/account. Restart the server
//// and both are signed out: the memory store does not survive restarts.

import database
import demo
import gleam/int
import gleam/io
import gleam/option.{type Option}
import gloo/repo.{type Repo}
import howdy
import howdy/auth
import howdy/auth/pages
import howdy/auth/policy
import howdy/auth/routes
import howdy/auth/session_store.{type SessionStore, SessionStore}
import howdy/auth/user
import howdy/controller

pub const database_file = "sessions.sqlite"

pub fn configure(
  db: Repo,
  deliver: fn(auth.Delivery) -> Result(Nil, Nil),
  store: SessionStore,
) -> auth.Auth {
  let assert Ok(identity) = auth.new(repo: db, origin: demo.origin, deliver:)
  let identity = auth.allow_registration(identity)
  let assert Ok(identity) =
    auth.with_policy(
      identity,
      policy.Policy(
        ..policy.default(),
        // A week from the last renewal, renewed at most daily while in use...
        session_seconds: 604_800,
        session_renew_seconds: 86_400,
        // ...but never beyond 90 days from sign-in...
        session_max_seconds: 7_776_000,
        // ...and not after two days untouched.
        session_idle_seconds: 172_800,
      ),
    )
  // Up to three accounts per browser; a fourth signs the oldest out.
  let assert Ok(identity) = auth.with_multi_session(identity, max: 3)
  // Changing store signs everyone out: sessions are not copied across.
  auth.with_session_store(identity, store)
}

pub fn app(identity: auth.Auth) -> howdy.App {
  // Guards see one account at a time, the browser's active one.
  let account =
    controller.guarded("/account", auth.required(identity))
    |> controller.get("/me", fn(ctx) {
      controller.json(ctx, user.to_json(ctx.guard.user))
    })
    |> controller.build()

  // GET /api/auth/sessions lists a user's sessions and /sessions/revoke ends
  // one; /sessions/accounts and /sessions/switch manage this browser's.
  howdy.new()
  |> howdy.controller(routes.api(identity, at: "/api/auth"))
  |> howdy.controller(pages.routes(identity, at: "/auth", api_at: "/api/auth"))
  |> howdy.controller(account)
}

/// A store is a record of seven functions. This one forwards each to another
/// store and reports it: the shape of an adapter for Redis or anything else.
/// A store only ever sees a digest of a session token, never the token.
/// `session_store.check` tests an adapter against the contract.
pub fn observed(
  store: SessionStore,
  report: fn(String) -> Nil,
) -> SessionStore {
  SessionStore(
    insert: fn(entry) {
      report("insert session for " <> entry.user_id <> " via " <> entry.method)
      store.insert(entry)
    },
    get: fn(digest) { store.get(digest) },
    // Renewal arrives here: a backend with a native TTL resets it from
    // `expires_at`, or renewed sessions vanish early.
    touch: fn(digest, now, expires_at) {
      report("touch session, expires at " <> int.to_string(expires_at))
      store.touch(digest, now, expires_at)
    },
    list: fn(user_id) { store.list(user_id) },
    delete: fn(digest, user_id) {
      report("delete one session of " <> user_id)
      store.delete(digest, user_id)
    },
    delete_for_user: fn(user_id, keep: Option(String)) {
      report("delete sessions of " <> user_id)
      store.delete_for_user(user_id, keep)
    },
    prune: fn(now) { store.prune(now) },
  )
}

pub fn main() {
  let db = database.open(database_file)
  let store =
    observed(session_store.memory(), fn(line) {
      io.println("LOCAL DEMO store: " <> line)
    })
  configure(db, demo.print_email, store) |> app |> demo.serve
}
