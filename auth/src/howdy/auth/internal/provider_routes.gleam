//// Browser transport for providers; the headless flow lives in auth.

import gleam/http/response
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri
import howdy/auth.{type Auth}
import howdy/auth/internal/login_transport
import howdy/auth/secret
import howdy/auth/user.{type Principal}
import howdy/controller
import howdy/cookie
import howdy/form
import howdy/guard
import howdy/locale
import howdy/middleware
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
    as "provider routes require local paths without queries or fragments"
  let limited = rate_limit.by(auth.limiter(identity, "providers", 30, 60), key)
  let wrap = middleware.wrap(_, limited)
  let routes =
    controller.new(prefix)
    |> controller.middleware(fn(ctx, next) {
      next(ctx)
      |> response.set_header("cache-control", "no-store")
      |> response.set_header("referrer-policy", "no-referrer")
      |> response.set_header("x-content-type-options", "nosniff")
    })
  list.fold(auth.providers(identity), routes, fn(routes, provider) {
    let #(id, _) = provider
    let path = "/providers/" <> id
    let callback = prefix <> path <> "/callback"
    routes
    |> controller.post(
      path <> "/login",
      wrap(fn(ctx) {
        use _ <- guard.require(ctx, fn(ctx) { auth.check_origin(identity, ctx) })
        use group <- query.optional_string(ctx, "group")
        let scoped = case auth.bound_group(identity), group {
          None, Some(g) -> auth.in_group(identity, g)
          _, _ -> identity
        }
        start(
          ctx,
          identity,
          cookie_name(identity, id),
          auth.begin_provider(scoped, id, callback, option.unwrap(key(ctx), "")),
        )
      }),
    )
    |> controller.post(
      path <> "/link",
      wrap(fn(ctx) {
        use _ <- guard.require(ctx, fn(ctx) { auth.check_origin(identity, ctx) })
        use principal <- guard.require(ctx, auth.required_from(identity, key))
        start(
          ctx,
          identity,
          cookie_name(identity, id),
          auth.begin_provider_link(identity, principal, id, callback),
        )
      }),
    )
    |> controller.get(
      path <> "/callback",
      wrap(fn(ctx) {
        use state <- query.string(ctx, "state")
        use code <- query.optional_string(ctx, "code")
        use error <- query.optional_string(ctx, "error")
        use browser <- cookie.optional_string(ctx, cookie_name(identity, id))
        let identity =
          auth.in_locale(
            identity,
            locale.to_string(auth.request_locale(identity, ctx)),
          )
        let principal =
          auth.required_from(identity, key)(ctx) |> option.from_result
        let code = case error {
          Some(_) -> None
          None -> code
        }
        let completed =
          auth.finish_provider(
            identity,
            id,
            callback,
            state,
            option.unwrap(browser, ""),
            code,
            principal,
          )
        complete(ctx, identity, prefix, success, failure, principal, completed)
        |> cookie.delete(cookie_name(identity, id), options(identity))
      }),
    )
    // `response_mode=form_post`, which Apple requires whenever a scope is asked
    // for. The provider posts here from its own site, so the browser withholds
    // every SameSite=Lax cookie: neither the attempt's binding nor a session
    // to link arrives. Nothing is decided here. The answer is handed to the
    // GET above as a top-level navigation, which does carry those cookies, and
    // is judged there exactly as a query-mode answer is. Anyone can cause
    // this redirect, and it gives them nothing a link to that GET would not.
    |> controller.post(
      path <> "/callback",
      wrap(fn(ctx) {
        use submitted <- form.read_with_limit(ctx, 16_384)
        let answer =
          list.filter_map(["state", "code", "error"], fn(name) {
            case form.value(submitted, name) {
              "" -> Error(Nil)
              value -> Ok(#(name, value))
            }
          })
        redirect(ctx, callback <> "?" <> uri.query_to_string(answer))
      }),
    )
  })
}

/// Turn a finished attempt into the browser's next page. Shared with the SSO
/// routes: what happens after an identity is proven does not depend on how.
pub fn complete(
  ctx,
  identity: Auth,
  prefix: String,
  success: String,
  failure: String,
  principal: Option(Principal),
  completed: service.Result(auth.ProviderOutcome),
) {
  // Signing in replaces the local session the browser arrived with, or joins
  // it in a multi-session browser.
  let signed_in = fn(session: auth.Session) {
    login_transport.signed_in(
      identity,
      ctx,
      redirect(ctx, success),
      session,
      principal,
      "",
    )
  }
  case completed {
    Ok(auth.ProviderSession(session)) -> signed_in(session)
    Ok(auth.ProviderSecondFactor(challenge)) ->
      case login_transport.try_trusted(identity, ctx, challenge) {
        #(auth.SignedIn(session), remembered) ->
          signed_in(session) |> remembered
        #(auth.SecondFactor(challenge), _) -> {
          case auth.multi_session(identity), principal {
            None, Some(p) -> {
              let _ = auth.logout(identity, p)
              Nil
            }
            _, _ -> Nil
          }
          login_transport.pending(
            identity,
            redirect(ctx, prefix <> "/mfa"),
            challenge,
          )
        }
      }
    Ok(auth.ProviderLinked) -> redirect(ctx, success)
    Error(_) -> redirect(ctx, failure)
  }
}

pub fn start(
  ctx,
  identity: Auth,
  named: String,
  started: service.Result(auth.ProviderStart),
) {
  case started {
    Error(error) -> service.error_response(ctx, error)
    Ok(start) ->
      redirect(ctx, start.url)
      |> cookie.set(
        named,
        secret.reveal(start.browser_token),
        options(identity) |> cookie.max_age(600),
      )
  }
}

pub fn redirect(ctx, location) {
  controller.status(ctx, 303) |> response.set_header("location", location)
}

pub fn options(identity) {
  cookie.defaults() |> cookie.secure(auth.secure(identity))
}

fn cookie_name(identity, id) {
  case auth.secure(identity) {
    True -> "__Host-howdy_provider_"
    False -> "howdy_dev_provider_"
  }
  <> id
}
