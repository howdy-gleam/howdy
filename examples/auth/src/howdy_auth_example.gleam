import database
import demo
import gleam/dynamic/decode
import gleam/json
import gleam/result
import gloo/repo.{type Repo}
import howdy
import howdy/auth
import howdy/auth/mfa
import howdy/auth/pages
import howdy/auth/providers/google
import howdy/auth/routes
import howdy/auth/user
import howdy/authorization as access
import howdy/body
import howdy/console
import howdy/controller
import howdy/guard
import howdy/migration
import howdy/param
import howdy/service
import notes

pub fn app(db: Repo, identity: auth.Auth, permissions: access.Authorization) {
  let account =
    controller.guarded("/account", auth.required(identity))
    |> controller.get("/me", fn(ctx) {
      controller.json(ctx, user.to_json(ctx.guard.user))
    })
    |> controller.get("/reports", fn(ctx) {
      use _ <- guard.require(
        ctx,
        access.require_permission(permissions, "reports.read", access.Global),
      )
      controller.text(ctx, "You can read reports.")
    })
    // Application-owned rows, kept beside auth's through howdy/database.
    |> controller.get("/notes", fn(ctx) {
      notes.list(db, ctx.guard.user)
      |> service.respond(ctx, json.array(_, notes.to_json))
    })
    |> controller.post("/notes", fn(ctx) {
      use title <- body.json(ctx, decode.at(["title"], decode.string))
      notes.create(db, ctx.guard.user, title)
      |> service.created(ctx, notes.to_json)
    })
    |> controller.delete("/notes/:id", fn(ctx) {
      use id <- param.string(ctx, "id")
      notes.delete(db, ctx.guard.user, id) |> service.no_content(ctx)
    })
    |> controller.build()

  howdy.new()
  |> howdy.controller(routes.api(identity, at: "/api/auth"))
  |> howdy.controller(routes.providers(
    identity,
    at: "/auth",
    success_path: "/auth/account",
    failure_path: "/auth/login",
  ))
  |> howdy.controller(pages.routes(identity, at: "/auth", api_at: "/api/auth"))
  |> howdy.controller(account)
}

/// What `main` builds and a console needs: see `src/console.gleam`.
pub type Services {
  Services(db: Repo, identity: auth.Auth, permissions: access.Authorization)
}

/// Where `main` exposes the running server's `Services` to a console.
pub fn services_key() -> console.Key(Services) {
  console.key("howdy_auth_example")
}

pub fn main() {
  let db = database.connect()
  // Refuse to start against a schema `gleam run -m migrate` has not caught up.
  let assert Ok(_) = migration.check(db, notes.schema())
  // Local demonstration only. Real applications deliver tokens privately by
  // email and must never send them to logs or the browser that requested them.
  let assert Ok(identity) =
    auth.new(repo: db, origin: demo.origin, deliver: demo.print_email)
  let identity = case google_credentials() {
    Error(_) -> identity
    Ok(#(client_id, client_secret)) -> {
      let assert Ok(identity) =
        auth.with_provider(identity, google.new(client_id:, client_secret:))
      identity
    }
  }
  // Application-owned rows go in the same transaction as the account.
  let identity = auth.with_account_deletion(identity, notes.delete_all)
  let identity = auth.allow_registration(identity)
  let assert Ok(identity) = auth.with_passwords(identity)
  let assert Ok(identity) = auth.with_passkeys(identity, "Howdy demo")
  let identity = case demo.env("HOWDY_AUTH_MFA_KEY") {
    Error(_) -> identity
    Ok(key) -> {
      let assert Ok(config) = mfa.new("Howdy demo", key)
      auth.with_mfa(identity, config)
    }
  }
  let assert Ok(permissions) = access.new(db)
  let assert Ok(_) =
    access.define_role(
      permissions,
      access.Global,
      "reader",
      ["reports.read"],
      by: user.System,
    )
  console.expose(services_key(), Services(db:, identity:, permissions:))
  app(db, identity, permissions) |> demo.serve
}

// Read credentials at startup, never from requests or source-controlled values.
fn google_credentials() -> Result(#(String, String), Nil) {
  use id <- result.try(demo.env("GOOGLE_CLIENT_ID"))
  use secret <- result.map(demo.env("GOOGLE_CLIENT_SECRET"))
  #(id, secret)
}
