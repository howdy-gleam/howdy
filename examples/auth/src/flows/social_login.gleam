//// Sign in with Google, GitHub, Apple, Facebook or Microsoft Entra.
////
//// Each provider you configure gets a button on the starter sign-in page and
//// a "Link" button on the account page. Provider sign-ins produce ordinary
//// sessions, so the rest of the application cannot tell them apart.
////
//// Set the credentials of whichever providers you want, then:
////
////     gleam run -m migrate
////     gleam run -m flows/social_login
////
//// | Provider  | Environment                                           |
//// | --------- | ----------------------------------------------------- |
//// | Google    | GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, optionally GOOGLE_HOSTED_DOMAIN |
//// | GitHub    | GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET                 |
//// | Facebook  | FACEBOOK_APP_ID, FACEBOOK_APP_SECRET                   |
//// | Entra     | ENTRA_CLIENT_ID, ENTRA_CLIENT_SECRET, optionally ENTRA_TENANT |
//// | Apple     | APPLE_SERVICES_ID, APPLE_TEAM_ID, APPLE_KEY_ID, APPLE_PRIVATE_KEY_FILE |
////
//// Register `http://localhost:8787/auth/providers/<id>/callback` with each
//// provider (Apple needs a real HTTPS domain instead). Then open
//// http://localhost:8787/auth/login.
////
//// Who may do what:
//// - Google (Gmail or verified Workspace), GitHub (verified email) and Apple
////   can create an account, because registration is enabled below.
//// - Facebook and Entra addresses are not treated as proof of mailbox
////   ownership: register by email first, then link from /auth/account.
//// - An existing local account is never taken over by a matching address. Sign
////   in to it and link the provider deliberately.

import database
import demo
import gleam/io
import gleam/list
import gleam/result
import gloo/repo.{type Repo}
import howdy
import howdy/auth
import howdy/auth/pages
import howdy/auth/provider.{type Provider}
import howdy/auth/providers/apple
import howdy/auth/providers/entra
import howdy/auth/providers/facebook
import howdy/auth/providers/github
import howdy/auth/providers/google
import howdy/auth/routes
import howdy/auth/user
import howdy/controller
import simplifile

pub const database_file = "social_login.sqlite"

pub fn configure(
  db: Repo,
  deliver: fn(auth.Delivery) -> Result(Nil, Nil),
  providers: List(Provider),
) -> auth.Auth {
  // Email tokens stay on: they are how Facebook and Entra users first prove
  // their address, and how anyone recovers an account. For a provider-only
  // application use `auth.new_without_email(repo: db, origin: demo.origin)`.
  let assert Ok(identity) = auth.new(repo: db, origin: demo.origin, deliver:)
  let identity = auth.allow_registration(identity)
  // `with_provider` validates each one and rejects duplicate ids.
  let assert Ok(identity) =
    list.try_fold(providers, identity, auth.with_provider)
  identity
}

pub fn app(identity: auth.Auth) -> howdy.App {
  let account =
    controller.guarded("/account", auth.required(identity))
    |> controller.get("/me", fn(ctx) {
      controller.json(ctx, user.to_json(ctx.guard.user))
    })
    |> controller.build()

  howdy.new()
  |> howdy.controller(routes.api(identity, at: "/api/auth"))
  // POST /auth/providers/:id/login and /link, GET /auth/providers/:id/callback.
  // Mount it at the same prefix as the pages, whose buttons post to it.
  // Behind a proxy, use `routes.providers_limited_by` with your client header.
  |> howdy.controller(routes.providers(
    identity,
    at: "/auth",
    success_path: "/auth/account",
    failure_path: "/auth/login",
  ))
  |> howdy.controller(pages.routes(identity, at: "/auth", api_at: "/api/auth"))
  |> howdy.controller(account)
}

/// Load secrets from the environment, never from source control or requests.
pub fn providers_from_environment() -> List(Provider) {
  [
    {
      use id <- result.try(demo.env("GOOGLE_CLIENT_ID"))
      use secret <- result.map(demo.env("GOOGLE_CLIENT_SECRET"))
      let google = google.new(client_id: id, client_secret: secret)
      // Optionally only admit one Workspace, checked against the signed `hd`
      // claim rather than the address.
      case demo.env("GOOGLE_HOSTED_DOMAIN") {
        Ok(domain) -> google.require_hosted_domain(google, domain)
        Error(_) -> google
      }
    },
    {
      use id <- result.try(demo.env("GITHUB_CLIENT_ID"))
      use secret <- result.map(demo.env("GITHUB_CLIENT_SECRET"))
      github.new(client_id: id, client_secret: secret)
    },
    {
      use id <- result.try(demo.env("FACEBOOK_APP_ID"))
      use secret <- result.map(demo.env("FACEBOOK_APP_SECRET"))
      facebook.new(client_id: id, client_secret: secret)
    },
    {
      use id <- result.try(demo.env("ENTRA_CLIENT_ID"))
      use secret <- result.map(demo.env("ENTRA_CLIENT_SECRET"))
      // A tenant ID or domain, or `common`, `organizations` or `consumers`.
      let tenant = demo.env("ENTRA_TENANT") |> result.unwrap("organizations")
      entra.new(client_id: id, client_secret: secret, tenant:)
    },
    {
      use services_id <- result.try(demo.env("APPLE_SERVICES_ID"))
      use team_id <- result.try(demo.env("APPLE_TEAM_ID"))
      use key_id <- result.try(demo.env("APPLE_KEY_ID"))
      use path <- result.try(demo.env("APPLE_PRIVATE_KEY_FILE"))
      use private_key <- result.map(
        simplifile.read(path) |> result.replace_error(Nil),
      )
      // Apple has no shared secret: the .p8 key signs a short-lived one for
      // every exchange. An unusable key fails at `with_provider`, at startup.
      apple.new(client_id: services_id, team_id:, key_id:, private_key:)
    },
  ]
  |> result.values
}

pub fn main() {
  let providers = providers_from_environment()
  case providers {
    [] ->
      io.println(
        "No provider credentials set; only email sign-in is available. See the top of src/flows/social_login.gleam.",
      )
    _ -> Nil
  }
  let db = database.open(database_file)
  configure(db, demo.print_email, providers) |> app |> demo.serve
}
