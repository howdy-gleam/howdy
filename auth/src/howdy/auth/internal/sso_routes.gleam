//// Browser transport for SSO connections; the headless flow lives in auth.
//// Unlike the built-in providers, connections come and go while the server
//// runs, so the connection is a path parameter rather than a mounted route.

import gleam/http/response
import gleam/option.{type Option, None, Some}
import gleam/string
import howdy/auth.{type Auth}
import howdy/auth/internal/provider_routes.{complete, options, redirect}
import howdy/auth/internal/sso_saml
import howdy/auth/secret
import howdy/controller
import howdy/cookie
import howdy/form
import howdy/guard
import howdy/locale
import howdy/middleware
import howdy/param
import howdy/query
import howdy/rate_limit
import howdy/service

pub fn routes(
  identity: Auth,
  prefix: String,
  success: String,
  failure: String,
  key: fn(controller.Context) -> Option(String),
) -> controller.Controller {
  let assert True =
    auth.provider_path(prefix)
    && !string.ends_with(prefix, "/")
    && auth.provider_path(success)
    && auth.provider_path(failure)
    as "SSO routes require local paths without queries or fragments"
  let callback = fn(id) { prefix <> "/sso/" <> id <> "/callback" }
  let limited = rate_limit.by(auth.limiter(identity, "sso", 30, 60), key)
  let wrap = middleware.wrap(_, limited)
  let client = fn(ctx) { option.unwrap(key(ctx), "") }
  let finish = fn(ctx, id, state, browser, code) {
    let identity =
      auth.in_locale(
        identity,
        locale.to_string(auth.request_locale(identity, ctx)),
      )
    let principal = auth.required_from(identity, key)(ctx) |> option.from_result
    complete(
      ctx,
      identity,
      prefix,
      success,
      failure,
      principal,
      auth.finish_sso(
        identity,
        id,
        callback(id),
        state,
        option.unwrap(browser, ""),
        code,
        principal,
      ),
    )
    |> cookie.delete(cookie_name(identity, id), options(identity))
    |> cookie.delete(post_cookie_name(identity, id), post_options())
  }
  controller.new(prefix)
  |> controller.middleware(fn(ctx, next) {
    next(ctx)
    |> response.set_header("cache-control", "no-store")
    |> response.set_header("referrer-policy", "no-referrer")
    |> response.set_header("x-content-type-options", "nosniff")
  })
  // The sign-in page asks for an address and the domain picks the connection.
  // An address no connection serves goes to `failure`, as a failed sign-in.
  |> controller.post(
    "/sso/login",
    wrap(fn(ctx) {
      use _ <- guard.require(ctx, fn(ctx) { auth.check_origin(identity, ctx) })
      use submitted <- form.read(ctx)
      case auth.sso_for_email(identity, form.value(submitted, "email")) {
        Ok(Some(id)) ->
          begin(
            ctx,
            identity,
            id,
            auth.begin_sso(identity, id, callback(id), client(ctx)),
          )
        _ -> redirect(ctx, failure)
      }
    }),
  )
  |> controller.post(
    "/sso/:connection/login",
    wrap(fn(ctx) {
      use _ <- guard.require(ctx, fn(ctx) { auth.check_origin(identity, ctx) })
      use id <- connection(ctx, failure)
      begin(
        ctx,
        identity,
        id,
        auth.begin_sso(identity, id, callback(id), client(ctx)),
      )
    }),
  )
  |> controller.post(
    "/sso/:connection/link",
    wrap(fn(ctx) {
      use _ <- guard.require(ctx, fn(ctx) { auth.check_origin(identity, ctx) })
      use principal <- guard.require(ctx, auth.required_from(identity, key))
      use id <- connection(ctx, failure)
      begin(
        ctx,
        identity,
        id,
        auth.begin_sso_link(identity, principal, id, callback(id)),
      )
    }),
  )
  |> controller.get(
    "/sso/:connection/callback",
    wrap(fn(ctx) {
      use id <- connection(ctx, failure)
      use state <- query.string(ctx, "state")
      use code <- query.optional_string(ctx, "code")
      use error <- query.optional_string(ctx, "error")
      use browser <- cookie.optional_string(ctx, cookie_name(identity, id))
      let code = case error {
        Some(_) -> None
        None -> code
      }
      finish(ctx, id, state, browser, code)
    }),
  )
  // The customer's provider posts here from its own site, so there is no
  // Origin to check: the attempt's RelayState, the browser's cookie and the
  // response's InResponseTo are what tie it to a sign-in begun here.
  // It is the same URL as the OIDC callback, so a connection has one URL
  // whatever its protocol: its redirect URI, or its ACS URL and entity ID.
  |> controller.post(
    "/sso/:connection/callback",
    wrap(fn(ctx) {
      use id <- connection(ctx, failure)
      use submitted <- form.read_with_limit(ctx, 700_000)
      use browser <- cookie.optional_string(ctx, post_cookie_name(identity, id))
      let code = case form.value(submitted, "SAMLResponse") {
        "" -> None
        encoded -> Some(encoded)
      }
      finish(ctx, id, form.value(submitted, "RelayState"), browser, code)
    }),
  )
  // Generated from the id alone, so it says nothing about which ids exist.
  |> controller.get("/sso/:connection/metadata", fn(ctx) {
    use id <- connection(ctx, failure)
    let acs = auth.origin(identity) <> callback(id)
    controller.text(ctx, sso_saml.metadata(acs, acs))
    |> response.set_header("content-type", "application/samlmetadata+xml")
  })
}

/// The path parameter names a cookie and a callback path before any lookup
/// vouches for it, so it must already look like a connection id.
fn connection(ctx, failure: String, next) {
  use id <- param.string(ctx, "connection")
  case
    auth.provider_path("/" <> id)
    && !string.contains(id, "/")
    && string.byte_size(id) <= 64
  {
    True -> next(id)
    False -> redirect(ctx, failure)
  }
}

/// Both bindings are set, because the routes do not know the connection's
/// protocol until it answers. OIDC returns by a GET navigation, which carries
/// the Lax cookie. SAML returns by a cross-site POST, which carries only a
/// SameSite=None cookie; browsers accept its Secure attribute on loopback too.
fn begin(ctx, identity, id, started: service.Result(auth.ProviderStart)) {
  case started {
    Error(error) -> service.error_response(ctx, error)
    Ok(start) -> {
      let token = secret.reveal(start.browser_token)
      redirect(ctx, start.url)
      |> cookie.set(
        cookie_name(identity, id),
        token,
        options(identity) |> cookie.max_age(600),
      )
      |> cookie.set(
        post_cookie_name(identity, id),
        token,
        post_options() |> cookie.max_age(600),
      )
    }
  }
}

fn post_options() {
  cookie.defaults() |> cookie.secure(True) |> cookie.same_site(cookie.None)
}

fn post_cookie_name(identity, id) {
  case auth.secure(identity) {
    True -> "__Host-howdy_sso_post_"
    False -> "howdy_dev_sso_post_"
  }
  <> id
}

fn cookie_name(identity, id) {
  case auth.secure(identity) {
    True -> "__Host-howdy_sso_"
    False -> "howdy_dev_sso_"
  }
  <> id
}
