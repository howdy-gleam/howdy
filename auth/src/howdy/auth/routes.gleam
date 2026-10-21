//// JSON endpoints for custom pages and API clients. Mount once at startup.

import gleam/dynamic/decode
import gleam/http
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/string
import howdy/auth.{type Auth}
import howdy/auth/internal/codes
import howdy/auth/internal/login_transport
import howdy/auth/internal/provider_routes
import howdy/auth/internal/security_routes
import howdy/auth/internal/sso_routes
import howdy/auth/user
import howdy/body
import howdy/context
import howdy/controller
import howdy/cookie
import howdy/guard
import howdy/locale
import howdy/middleware
import howdy/rate_limit
import howdy/service

/// Make `session` the browser's active session on a response of your own,
/// setting the cookies the bundled routes set. For transports that obtain a
/// session some other way, such as `auth.impersonate` from an operator
/// tool. With multi-session enabled the session joins the browser's
/// accounts; otherwise the cookie is replaced and the previous session is
/// left as it was.
pub fn signed_in(
  identity: Auth,
  ctx: controller.Context,
  res: response.Response(a),
  session: auth.Session,
) -> response.Response(a) {
  login_transport.signed_in(identity, ctx, res, session, option.None, "")
}

/// POST /login and /register deliver email tokens; POST /session exchanges
/// for a browser cookie; POST /token exchanges for a bearer token. Both take
/// `{"token"}`, or with `auth.with_email_codes`, `{"email", "code"}`.
/// POST /password/register sends verification; /password/session and
/// /password/token authenticate with email/password when enabled.
/// POST /password sets or replaces the caller's password; see
/// `auth.set_password` for the fresh email-token session it requires.
/// The endpoints that take an email address also take an optional `group`
/// id, applied with `auth.in_group`; see `auth.with_groups` for when it is
/// needed. It is the client's claim about where it wants to sign in, not
/// proof of membership: `principal.user.group_id` is the group to trust.
/// POST /locale sets the caller's locale, `{"locale": "de"}`, or clears it
/// with `{"locale": null}`; see `auth.set_locale`.
/// GET /me, GET /sessions, POST /sessions/revoke and POST /logout accept either
/// transport, never both together. Cookie writes require Origin. Other
/// endpoints allow absent Origin for nonbrowser clients, but reject any
/// foreign/duplicate Origin.
///
/// Error bodies carry a stable `code` beside the English `error`, and
/// answers that tell the reader something carry one beside `message`, so a
/// client can show its own words; the bundled pages do. The codes are
/// `unauthorized`, `forbidden`, `not_found`, `invalid`, `conflict`,
/// `validation`, `too_many_requests`, `unsupported_media_type` and
/// `internal` from the status, the more specific `password_incorrect`,
/// `password_unchanged`, `password_common`, `password_length`, `password_too_long`,
/// `email_invalid`, `email_unchanged`, `email_mismatch`, `email_taken`,
/// `mfa_enabled`, `passkey_limit`, `passkey_registered`, `passkey_name`,
/// `provider_linked`, `credential_too_large`, `locale_unsupported` and
/// `group_required`, and for success `token_sent`, `signup_token_sent`,
/// `approval_sent` and `confirmation_sent`.
///
/// Clients are rate limited by socket address. Behind a reverse proxy that
/// is the proxy for everyone: use `api_limited_by` there.
pub fn api(identity: Auth, at prefix: String) -> controller.Controller {
  api_limited_by(identity, at: prefix, key: fn(ctx) {
    context.client_ip(ctx.request)
  })
}

/// Requests per client per minute to endpoints that send email, exchange
/// tokens or hash passwords.
pub const credential_limit = 30

/// Requests per client per minute to the signed-in endpoints, which pages
/// call routinely.
pub const session_limit = 300

/// As `api`, identifying clients for rate limiting with `key`. Behind a
/// trusted proxy, read the header it sets:
///
/// ```gleam
/// routes.api_limited_by(identity, at: "/api/auth", key: fn(ctx) {
///   request.get_header(ctx.request, "fly-client-ip") |> option.from_result
/// })
/// ```
///
/// Only use a header your ingress overwrites; a client-supplied value lets
/// anyone choose their own bucket. `None` skips limiting for that request.
pub fn api_limited_by(
  identity: Auth,
  at prefix: String,
  key key: fn(controller.Context) -> Option(String),
) -> controller.Controller {
  let strict =
    rate_limit.by(
      auth.limiter(identity, "credentials", credential_limit, 60),
      key,
    )
  let signed_in =
    rate_limit.by(auth.limiter(identity, "session", session_limit, 60), key)
  let strict = middleware.wrap(_, strict)
  let signed_in = middleware.wrap(_, signed_in)
  // The same identity used for rate limiting is what audit events record.
  let client = fn(ctx) { option.unwrap(key(ctx), "") }
  let required = auth.required_from(identity, key)
  controller.new(prefix)
  |> controller.middleware(fn(ctx, next) {
    let origins =
      list.filter(ctx.request.headers, fn(h) {
        string.lowercase(h.0) == "origin"
      })
    let origin_ok = origins == [] || auth.check_origin(identity, ctx) == Ok(Nil)
    let media_ok = case ctx.request.method {
      http.Post -> {
        case
          list.filter(ctx.request.headers, fn(h) {
            string.lowercase(h.0) == "content-type"
          })
        {
          [#(_, value)] ->
            case string.split(string.lowercase(value), ";") {
              [media, ..] -> string.trim(media) == "application/json"
              _ -> False
            }
          _ -> False
        }
      }
      _ -> True
    }
    let answer = case origin_ok, media_ok {
      False, _ -> service.error_response(ctx, service.Forbidden)
      _, False ->
        service.error_response(
          ctx,
          service.Invalid("expected application/json"),
        )
      True, True -> next(ctx)
    }
    answer
    |> response.set_header("cache-control", "no-store")
    |> response.set_header("referrer-policy", "no-referrer")
    |> response.set_header("x-content-type-options", "nosniff")
  })
  |> controller.post(
    "/login",
    strict(fn(ctx) {
      request_email(localised(identity, ctx), ctx, auth.Login, client(ctx))
    }),
  )
  |> controller.post(
    "/register",
    strict(fn(ctx) {
      request_email(localised(identity, ctx), ctx, auth.Register, client(ctx))
    }),
  )
  |> controller.post(
    "/session",
    strict(fn(ctx) {
      use _ <- guard.require(ctx, fn(ctx) { auth.check_origin(identity, ctx) })
      use proof <- body.json_with_limit(ctx, body_limit, email_proof())
      browser_session(
        identity,
        ctx,
        exchange(localised(identity, ctx), proof, client(ctx)),
        required,
      )
    }),
  )
  |> controller.post(
    "/token",
    strict(fn(ctx) {
      use proof <- body.json_with_limit(ctx, body_limit, email_proof())
      exchange(localised(identity, ctx), proof, client(ctx))
      |> login_transport.bearer(identity, ctx, _)
    }),
  )
  |> controller.post(
    "/password/register",
    strict(fn(ctx) {
      use credentials <- body.json_with_limit(ctx, body_limit, credentials())
      auth.register_password_from(
        within(localised(identity, ctx), credentials.2),
        credentials.0,
        credentials.1,
        client(ctx),
      )
      |> email_response(ctx)
    }),
  )
  |> controller.post(
    "/password/session",
    strict(fn(ctx) {
      use _ <- guard.require(ctx, fn(ctx) { auth.check_origin(identity, ctx) })
      use credentials <- body.json_with_limit(ctx, body_limit, credentials())
      browser_session(
        identity,
        ctx,
        auth.login_password_step(
          within(localised(identity, ctx), credentials.2),
          credentials.0,
          credentials.1,
          client(ctx),
        ),
        required,
      )
    }),
  )
  |> controller.post(
    "/password/token",
    strict(fn(ctx) {
      use credentials <- body.json_with_limit(ctx, body_limit, credentials())
      auth.login_password_step(
        within(localised(identity, ctx), credentials.2),
        credentials.0,
        credentials.1,
        client(ctx),
      )
      |> login_transport.bearer(identity, ctx, _)
    }),
  )
  |> controller.post(
    "/password",
    strict(fn(ctx) {
      use principal <- guard.require(ctx, required)
      use password <- body.json_with_limit(ctx, body_limit, field("password"))
      auth.set_password(identity, principal, password)
      |> service.no_content(ctx)
    }),
  )
  |> controller.post(
    "/password/change",
    strict(fn(ctx) {
      use principal <- guard.require(ctx, required)
      use #(current, new) <- body.json_with_limit(ctx, body_limit, {
        use current <- decode.field("current", decode.string)
        use new <- decode.field("password", decode.string)
        decode.success(#(current, new))
      })
      auth.change_password_from(identity, principal, current, new, client(ctx))
      |> service.no_content(ctx)
    }),
  )
  |> controller.get(
    "/sessions",
    signed_in(fn(ctx) {
      use principal <- guard.require(ctx, required)
      auth.sessions(identity, principal)
      |> service.respond(ctx, json.array(_, session_json))
    }),
  )
  |> controller.post(
    "/sessions/revoke",
    signed_in(fn(ctx) {
      use principal <- guard.require(ctx, required)
      use id <- body.json_with_limit(ctx, body_limit, field("id"))
      auth.revoke_session(identity, principal, id)
      |> service.no_content(ctx)
    }),
  )
  |> controller.get(
    "/me",
    signed_in(fn(ctx) {
      use principal <- guard.require(ctx, required)
      controller.json(ctx, user.to_json(principal.user))
    }),
  )
  |> controller.post(
    "/locale",
    signed_in(fn(ctx) {
      use principal <- guard.require(ctx, required)
      use tag <- body.json_with_limit(
        ctx,
        body_limit,
        decode.field("locale", decode.optional(decode.string), decode.success),
      )
      auth.set_locale(identity, principal, tag)
      |> service.no_content(ctx)
    }),
  )
  |> controller.post(
    "/email/change",
    strict(fn(ctx) {
      use principal <- guard.require(ctx, required)
      use email <- body.json_with_limit(ctx, body_limit, field("email"))
      auth.request_email_change(localised(identity, ctx), principal, email)
      |> email_change_sent(
        ctx,
        case auth.email_change_approval_enabled(identity) {
          True -> #(
            "approval_sent",
            "Check your current email address for an approval token.",
          )
          False -> #(
            "confirmation_sent",
            "Check your new email address for a confirmation token.",
          )
        },
      )
    }),
  )
  |> controller.post(
    "/email/approve",
    strict(fn(ctx) {
      use principal <- guard.require(ctx, required)
      use token <- body.json_with_limit(ctx, body_limit, field("token"))
      auth.approve_email_change(localised(identity, ctx), principal, token)
      |> email_change_sent(ctx, #(
        "confirmation_sent",
        "Check your new email address for a confirmation token.",
      ))
    }),
  )
  |> controller.post(
    "/email/confirm",
    strict(fn(ctx) {
      use principal <- guard.require(ctx, required)
      use token <- body.json_with_limit(ctx, body_limit, field("token"))
      auth.confirm_email_change(identity, principal, token)
      |> account_response(ctx, identity)
    }),
  )
  |> controller.get(
    "/providers",
    signed_in(fn(ctx) {
      use principal <- guard.require(ctx, required)
      auth.linked_providers(identity, principal)
      |> service.respond(
        ctx,
        json.array(_, fn(link) {
          json.object([
            #("provider", json.string(link.0)),
            #("issuer", json.string(link.1)),
          ])
        }),
      )
    }),
  )
  |> controller.post(
    "/providers/unlink",
    strict(fn(ctx) {
      use principal <- guard.require(ctx, required)
      use issuer <- body.json_with_limit(ctx, body_limit, field("issuer"))
      auth.unlink_provider(identity, principal, issuer)
      |> account_response(ctx, identity)
    }),
  )
  |> controller.post(
    "/account/delete",
    strict(fn(ctx) {
      use principal <- guard.require(ctx, required)
      use email <- body.json_with_limit(ctx, body_limit, field("email"))
      auth.delete_account(identity, principal, email)
      |> account_response(ctx, identity)
    }),
  )
  |> controller.post(
    "/logout",
    signed_in(fn(ctx) {
      use principal <- guard.require(ctx, required)
      use everywhere <- body.json_with_limit(
        ctx,
        body_limit,
        // Any JSON body signs this account out; only `{"all": true}` does more.
        decode.one_of(
          decode.optional_field("all", False, decode.bool, decode.success),
          [decode.success(False)],
        ),
      )
      case auth.logout(identity, principal), everywhere {
        Error(error), _ -> service.error_response(ctx, error)
        Ok(Nil), True ->
          controller.status(ctx, 204)
          |> login_transport.signed_out_everywhere(identity, ctx, _)
        Ok(Nil), False ->
          controller.status(ctx, 204)
          |> login_transport.signed_out(identity, ctx, _)
      }
    }),
  )
  |> controller.get(
    "/sessions/accounts",
    signed_in(fn(ctx) {
      use principal <- guard.require(ctx, required)
      auth.device_sessions(
        identity,
        login_transport.device_tokens(identity, ctx),
        client(ctx),
      )
      |> json.array(fn(entry) {
        json.object([
          #("id", json.string({ entry.1 }.session_id)),
          #("user", user.to_json({ entry.1 }.user)),
          #(
            "current",
            json.bool({ entry.1 }.session_id == principal.session_id),
          ),
        ])
      })
      |> controller.json(ctx, _)
    }),
  )
  |> controller.post(
    "/sessions/switch",
    signed_in(fn(ctx) {
      use _ <- guard.require(ctx, required)
      use id <- body.json_with_limit(ctx, body_limit, field("id"))
      let tokens = login_transport.device_tokens(identity, ctx)
      let found =
        auth.device_sessions(identity, tokens, client(ctx))
        |> list.find(fn(entry) { { entry.1 }.session_id == id })
      case found {
        Ok(#(secret, principal)) ->
          controller.json(ctx, user.to_json(principal.user))
          |> cookie.set(auth.cookie_name(identity), secret, options(identity))
        Error(Nil) -> service.error_response(ctx, service.NotFound("account"))
      }
    }),
  )
  |> security_routes.add(identity, strict, signed_in, required, client)
}

/// Request bodies hold an address, a token or a password; nothing larger.
const body_limit = 4096

fn email_change_sent(
  answer: service.Result(Nil),
  ctx,
  message: #(String, String),
) {
  case answer {
    Ok(Nil) ->
      controller.json(ctx, codes.message(message.0, message.1))
      |> controller.with_status(202)
    Error(error) -> service.error_response(ctx, error)
  }
}

fn account_response(answer: service.Result(Nil), ctx, identity: Auth) {
  case answer {
    Ok(Nil) ->
      service.no_content(answer, ctx)
      |> login_transport.signed_out(identity, ctx, _)
    Error(error) -> service.error_response(ctx, error)
  }
}

fn options(identity: Auth) -> cookie.Options {
  cookie.defaults()
  |> cookie.secure(auth.secure(identity))
  |> cookie.max_age(auth.session_cookie_seconds(identity))
}

fn field(name: String) -> decode.Decoder(String) {
  decode.field(name, decode.string, decode.success)
}

fn request_email(identity, ctx, intent, client) {
  use #(email, group) <- body.json_with_limit(ctx, body_limit, {
    use email <- decode.field("email", decode.string)
    use group <- decode.then(group())
    decode.success(#(email, group))
  })
  auth.request_token_from(within(identity, group), email, intent, client)
  |> email_response(ctx)
}

type EmailProof {
  Token(String)
  Code(email: String, code: String, group: Option(String))
}

fn email_proof() -> decode.Decoder(EmailProof) {
  decode.one_of(decode.map(field("token"), Token), [
    {
      use email <- decode.field("email", decode.string)
      use code <- decode.field("code", decode.string)
      use group <- decode.then(group())
      decode.success(Code(email, code, group))
    },
  ])
}

fn exchange(identity: Auth, proof: EmailProof, client: String) {
  case proof {
    Token(secret) -> auth.exchange_step(identity, secret, client)
    Code(email, code, group) ->
      auth.exchange_code_step(within(identity, group), email, code, client)
  }
}

fn group() -> decode.Decoder(Option(String)) {
  use group <- decode.optional_field(
    "group",
    option.None,
    decode.optional(decode.string),
  )
  decode.success(group)
}

/// The identity acting in the request's locale, so a new account and the
/// emails it causes use it.
fn localised(identity: Auth, ctx: controller.Context) -> Auth {
  auth.in_locale(identity, locale.to_string(auth.request_locale(identity, ctx)))
}

fn within(identity: Auth, group: Option(String)) -> Auth {
  case group {
    option.Some(id) -> auth.in_group(identity, id)
    option.None -> identity
  }
}

fn email_response(result, ctx) {
  case result {
    Ok(Nil) ->
      controller.json(
        ctx,
        codes.message("token_sent", "Check your email for a sign-in token."),
      )
      |> controller.with_status(202)
    Error(error) -> service.error_response(ctx, error)
  }
}

fn credentials() -> decode.Decoder(#(String, String, Option(String))) {
  use email <- decode.field("email", decode.string)
  use password <- decode.field("password", decode.string)
  use group <- decode.then(group())
  decode.success(#(email, password, group))
}

fn browser_session(
  identity: Auth,
  ctx: controller.Context,
  answer: service.Result(auth.LoginStep),
  required,
) {
  login_transport.browser(identity, ctx, answer, required)
}

fn session_json(session: auth.SessionInfo) -> json.Json {
  json.object([
    #("id", json.string(session.id)),
    #(
      "method",
      json.string(case session.method {
        auth.EmailToken -> "email"
        auth.Password -> "password"
        auth.Passkey -> "passkey"
        auth.Provider(id) -> "provider:" <> id
        auth.Impersonation -> "impersonation"
      }),
    ),
    #("created_at", json.int(session.created_at)),
    #("last_seen_at", json.int(session.last_seen_at)),
    #("expires_at", json.int(session.expires_at)),
    #("current", json.bool(session.current)),
    #("client", json.string(session.client)),
  ])
}

/// Browser redirects for built-in identity providers. Mount once at startup.
/// The callback URI is `auth.origin(identity) <> at <> "/providers/google/callback"`.
/// Destinations are fixed local paths. Login/link POSTs require an exact Origin.
pub fn providers(
  identity: Auth,
  at prefix: String,
  success_path success: String,
  failure_path failure: String,
) -> controller.Controller {
  provider_routes.routes(identity, prefix, success, failure, fn(ctx) {
    context.client_ip(ctx.request)
  })
}

/// As `providers`, with a trusted client key for proxy-aware rate limits/audit.
pub fn providers_limited_by(
  identity: Auth,
  at prefix: String,
  success_path success: String,
  failure_path failure: String,
  key key: fn(controller.Context) -> Option(String),
) -> controller.Controller {
  provider_routes.routes(identity, prefix, success, failure, key)
}

/// Browser redirects for SSO connections; see `howdy/auth/connection`. Mount
/// once at startup: connections created later are served without remounting.
/// A connection's redirect URI, to register at the customer's provider, is
/// `auth.origin(identity) <> at <> "/sso/" <> connection.id <> "/callback"`.
/// `POST at <> "/sso/login"` takes a form `email` and picks the connection by
/// its domain. Destinations are fixed local paths. POSTs require an exact
/// Origin.
pub fn sso(
  identity: Auth,
  at prefix: String,
  success_path success: String,
  failure_path failure: String,
) -> controller.Controller {
  sso_routes.routes(identity, prefix, success, failure, fn(ctx) {
    context.client_ip(ctx.request)
  })
}

/// As `sso`, with a trusted client key for proxy-aware rate limits/audit.
pub fn sso_limited_by(
  identity: Auth,
  at prefix: String,
  success_path success: String,
  failure_path failure: String,
  key key: fn(controller.Context) -> Option(String),
) -> controller.Controller {
  sso_routes.routes(identity, prefix, success, failure, key)
}
