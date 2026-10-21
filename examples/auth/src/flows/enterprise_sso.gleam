//// Enterprise single sign-on: each customer brings their own identity
//// provider over OpenID Connect or SAML 2.0.
////
//// A **connection** is data, not code: created while the server runs, stored
//// (secrets sealed) in the auth database, and bound to the customer's group.
//// Its users sign in from an email-first page, where the address's domain
//// picks the connection. People whose address the connection does not cover,
//// such as contractors and operators, keep signing in by email.
////
////     export HOWDY_AUTH_SSO_KEY=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')
////     export SSO_DOMAIN=acme.com
////     # Either OpenID Connect:
////     export SSO_OIDC_ISSUER=https://acme.okta.com SSO_OIDC_CLIENT_ID=... SSO_OIDC_CLIENT_SECRET=...
////     # or SAML, with the provider's signing certificate:
////     export SSO_SAML_ENTITY_ID=... SSO_SAML_SSO_URL=https://... SSO_SAML_CERTIFICATE_FILE=idp.pem
////     gleam run -m migrate
////     gleam run -m flows/enterprise_sso
////
//// Startup onboards the customer "acme" once and prints the one URL to give
//// their administrator. Then open http://localhost:8787/login. Set
//// SSO_ENFORCE=true to make SSO the only way in for addresses in SSO_DOMAIN.

import database
import demo
import gleam/io
import gleam/result
import gloo/repo.{type Repo}
import howdy
import howdy/auth
import howdy/auth/connection.{type Connection, type Protocol}
import howdy/auth/connections
import howdy/auth/group
import howdy/auth/groups
import howdy/auth/pages
import howdy/auth/routes
import howdy/auth/user.{type Actor}
import howdy/controller
import howdy/service
import simplifile

pub const database_file = "enterprise_sso.sqlite"

pub fn configure(
  db: Repo,
  deliver: fn(auth.Delivery) -> Result(Nil, Nil),
  sso_key sso_key: String,
) -> auth.Auth {
  let assert Ok(identity) = auth.new(repo: db, origin: demo.origin, deliver:)
  // Each customer is a group, and each address belongs to one of them.
  let assert Ok(identity) = auth.with_groups(identity, group.OneGroupPerUser)
  // Seals connection secrets at rest. Stable, 32 bytes, outside the database;
  // it may be the same key as MFA's.
  let assert Ok(config) = connection.config(sso_key)
  // No `allow_registration`: creating a connection is what admits its users.
  auth.with_sso(identity, config)
}

/// Operator code, never a public route: give a customer a group and a
/// connection. Confirm the customer controls every domain first; within those
/// domains their provider is believed about who owns an address.
pub fn onboard(
  identity: auth.Auth,
  id id: String,
  name name: String,
  protocol protocol: Protocol,
  domains domains: List(String),
  by actor: Actor,
) -> service.Result(Connection) {
  use _ <- result.try(groups.create_with_id(identity, id:, name:, by: actor))
  connections.create_with_id(
    identity,
    id:,
    group: id,
    name:,
    protocol:,
    domains:,
    by: actor,
  )
}

pub fn app(identity: auth.Auth) -> howdy.App {
  let login =
    controller.new("/")
    |> controller.get("/login", fn(ctx) { controller.html(ctx, login_page) })
    |> controller.build()

  let account =
    controller.guarded("/account", auth.required(identity))
    |> controller.get("/", fn(ctx) {
      controller.json(ctx, user.to_json(ctx.guard.user))
    })
    |> controller.build()

  howdy.new()
  |> howdy.controller(login)
  // POST /auth/sso/login (email-first), GET and POST /auth/sso/:id/callback,
  // GET /auth/sso/:id/metadata for SAML, POST /auth/sso/:id/link. Mounted once;
  // connections created later are served without remounting.
  |> howdy.controller(routes.sso(
    identity,
    at: "/auth",
    success_path: "/account",
    failure_path: "/login",
  ))
  // Email-token sign-in for everyone else, and /auth/mfa for accounts with a
  // Howdy second factor (asked after the provider unless the connection
  // trusts the provider's own; see `connections.trust_provider_mfa`).
  |> howdy.controller(routes.api(identity, at: "/api/auth"))
  |> howdy.controller(pages.routes(identity, at: "/auth", api_at: "/api/auth"))
  |> howdy.controller(account)
}

/// Starter pages have no SSO button, because asking for the address first is
/// the application's choice. This form is all it takes.
const login_page = "<!doctype html><html><head><meta charset=\"utf-8\"><title>Sign in</title></head><body>
<h1>Sign in</h1>
<form method=\"post\" action=\"/auth/sso/login\">
  <label>Work email <input type=\"email\" name=\"email\" autocomplete=\"username\" required></label>
  <button>Continue with SSO</button>
</form>
<p>Not using your company's sign-in? <a href=\"/auth/login\">Sign in by email</a>.</p>
</body></html>"

fn protocol_from_environment() -> Result(Protocol, Nil) {
  let oidc = {
    use issuer <- result.try(demo.env("SSO_OIDC_ISSUER"))
    use client_id <- result.try(demo.env("SSO_OIDC_CLIENT_ID"))
    use client_secret <- result.map(demo.env("SSO_OIDC_CLIENT_SECRET"))
    connection.oidc(issuer:, client_id:, client_secret:)
  }
  use <- result.lazy_or(oidc)
  use entity_id <- result.try(demo.env("SSO_SAML_ENTITY_ID"))
  use sso_url <- result.try(demo.env("SSO_SAML_SSO_URL"))
  use path <- result.try(demo.env("SSO_SAML_CERTIFICATE_FILE"))
  use certificate <- result.map(
    simplifile.read(path) |> result.replace_error(Nil),
  )
  connection.Saml(entity_id:, sso_url:, certificates: [certificate])
}

pub fn main() {
  case demo.env("HOWDY_AUTH_SSO_KEY") {
    Error(_) ->
      io.println(
        "Set HOWDY_AUTH_SSO_KEY first; see the top of src/flows/enterprise_sso.gleam.",
      )
    Ok(sso_key) -> {
      let db = database.open(database_file)
      let identity = configure(db, demo.print_email, sso_key:)
      case connections.get(identity, "acme"), protocol_from_environment() {
        Ok(_), _ -> Nil
        Error(_), Ok(protocol) -> {
          let domain = demo.env("SSO_DOMAIN") |> result.unwrap("acme.com")
          let assert Ok(_) =
            onboard(
              identity,
              id: "acme",
              name: "Acme",
              protocol:,
              domains: [domain],
              by: user.System,
            )
          io.println("Onboarded acme for " <> domain <> ".")
        }
        Error(_), Error(_) ->
          io.println(
            "No SSO_OIDC_* or SSO_SAML_* settings; the acme connection was not created.",
          )
      }
      case demo.env("SSO_ENFORCE") {
        // Signs covered members out and refuses every other way in for them.
        // Keep an operator account outside the domain: `stop_enforcing` is the
        // way back if the customer's provider breaks.
        Ok("true") -> {
          let _ = connections.enforce(identity, "acme", by: user.System)
          Nil
        }
        _ -> Nil
      }
      // The same URL is the OIDC redirect URI, and SAML's ACS URL and audience.
      io.println(
        "Give the customer this URL: "
        <> auth.origin(identity)
        <> "/auth/sso/acme/callback",
      )
      app(identity) |> demo.serve
    }
  }
}
