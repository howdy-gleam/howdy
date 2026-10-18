# howdy

[![Package Version](https://img.shields.io/hexpm/v/howdy)](https://hex.pm/packages/howdy)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://howdy.hexdocs.pm/)

```sh
gleam add howdy@2
```
```gleam
import gleam/erlang/process
import howdy
import howdy/controller

pub fn main() -> Nil {
  let hello =
    controller.new("/")
    |> controller.get("/", fn(ctx) { controller.text(ctx, "Howdy!") })

  let assert Ok(_) =
    howdy.new()
    |> howdy.controller(hello)
    |> howdy.start

  process.sleep_forever()
}
```

The server defaults to `0.0.0.0:8787` (all IPv4 interfaces). Override either
setting in the app pipeline:

```gleam
howdy.new()
|> howdy.controller(hello)
|> howdy.bind(to: "127.0.0.1")
|> howdy.listening(on: 8080)
|> howdy.start
```

`howdy.start` returns the server's process and the `howdy.Address` it is
listening on, whose `port` is the real one even when configured with port `0`.
Once listening, it prints a HOWDY ASCII banner, the framework version (`howdy.version`),
and the bound URL. Keep the calling process alive while serving requests.
For anything beyond a script, run the server under a supervisor as an OTP
application with `howdy.supervised` and `howdy.start_application`, so a crash
is restarted and `SIGTERM` lets open requests finish; see
[docs/guides/supervision.djot](https://github.com/mikeyjones/howdy/blob/v2/docs/guides/supervision.djot).
Howdy runs on the [ewe](https://hexdocs.pm/ewe/) server, but your code never
needs to name it. For ewe options `howdy.start` does not offer, pass
`howdy.handler(app)` to `ewe.new` yourself.

HTTP/2 is always on. Add `howdy.tls(cert: "priv/cert.pem", key: "priv/key.pem")`
to serve HTTPS, which is also what lets browsers use HTTP/2. See
[docs/guides/supervision.djot](https://github.com/mikeyjones/howdy/blob/v2/docs/guides/supervision.djot) for running the
app as a release, and check a deployed instance with `scripts/smoke.sh`, which
probes HTTP/1.1, HTTP/2, forwarded headers and WebSocket origins.

Further documentation can be found at <https://howdy.hexdocs.pm/>.

## Query strings

Use `howdy/query` to extract typed query parameters in a handler:

```gleam
import gleam/json
import howdy/controller
import howdy/query

pub fn users_controller() {
  controller.new("/users")
  |> controller.get("/", fn(ctx) {
    use search <- query.string_or(ctx, "search", default: "")
    use page <- query.int_or(ctx, "page", default: 1)
    use active <- query.bool_or(ctx, "active", default: True)

    controller.json(ctx, json.object([
      #("search", json.string(search)),
      #("page", json.int(page)),
      #("active", json.bool(active)),
    ]))
  })
}
```

- `string`, `int`, and `bool` require the parameter to be present.
- `optional_string`, `optional_int`, and `optional_bool` return `Option` values.
- `string_or`, `int_or`, and `bool_or` use a default only for missing parameters.
- `strings` collects repeated values in request order, or returns `[]` if absent.

Invalid input returns a JSON `400` response and stops the handler. For example,
`query.int(ctx, "page")` returns `{"error":"missing query parameter page"}`
when absent, or `{"error":"query parameter page must be an integer"}` for
`?page=hello`. Defaults never hide invalid values.

Empty strings are preserved. Booleans accept only `true` and `false`. Singular
helpers reject duplicate keys, and all helpers reject invalid query encoding.
Use `howdy/validate` for constraints such as a minimum page number.

## Forms

Use `howdy/form` for HTML forms posted as `application/x-www-form-urlencoded`.
`form.read` reads the body once into a `Form`; fields are then taken from that
value. Field problems come back as `howdy/validate` errors rather than
responses, so a page can be rendered again with its errors and the values the
user typed:

```gleam
import howdy/controller
import howdy/form.{type Form}
import howdy/validate

fn signup(fields: Form) -> validate.Result(Signup) {
  use email <- form.string(fields, "email", [validate.trim(), validate.email()])
  use age <- form.int(fields, "age", [validate.min(13)])
  use nickname <- form.optional_string(fields, "nickname", [validate.trim()])
  use newsletter <- form.checkbox(fields, "newsletter")
  validate.ok(Signup(email:, age:, nickname:, newsletter:))
}

pub fn signup_controller() {
  controller.new("/signup")
  |> controller.post("/", fn(ctx) {
    use fields <- form.read(ctx)
    case signup(fields) {
      Ok(signup) -> welcome(ctx, signup)
      Error(errors) ->
        controller.html(ctx, signup_page(fields, errors))
        |> controller.with_status(422)
    }
  })
}
```

- `string` and `int` require the field; a missing one reports `is required`.
  `optional_string` and `optional_int` return `Option` values. Every field is
  checked, so all errors are reported together.
- `checkbox` is `True` when the field was submitted at all, since browsers
  leave unticked checkboxes out. `strings` collects repeated values such as a
  multi-select, in order.
- When rendering the page again, `form.value(fields, "email")` gives the
  submitted value or `""`, and `form.error(errors, "email")` the field's
  message, if any. Escape submitted values like any other user input.
- `get`, `all` and `fields` give raw access. `form.validated(ctx, signup)`
  answers a failed validation with the JSON `422` of `body.validated`, for
  endpoints that are not pages.

Browsers submit an empty input as `name=`. `string` keeps the empty string, so
pair it with `validate.not_empty()`; `int` treats it as missing and the
`optional_*` helpers as `None`. Singular helpers reject repeated fields.

`read` returns `415` unless the content type is
`application/x-www-form-urlencoded`, and `400` for a body that is badly encoded
or over one mebibyte; `read_with_limit` changes the limit. Multipart forms,
and so file uploads, are not supported yet. A local variable named `form`
would shadow the module, so call the value something else, such as `fields`.

## Cross-site request forgery

A page on another site can make a browser post a form to your application,
and the browser attaches the user's cookies, because it decides by
destination rather than by who asked. Form posts need no CORS preflight, so
nothing stops the request from arriving. An attacker cannot read the
response, so this is about writes, not disclosure.

Two defences already apply. `cookie.defaults()` sets `SameSite=Lax`, which
keeps cookies off cross-site writes, and [`howdy_auth`](https://github.com/mikeyjones/howdy/blob/v2/auth/README.md)
requires a matching `Origin` on cookie-authenticated writes, both on its own
routes and on any route behind its guard. An application that uses that guard
for every write is already protected.

For applications that manage their own session cookies, `howdy/csrf` applies
the same check:

```gleam
import howdy/csrf

howdy.new()
|> howdy.middleware(csrf.middleware(csrf.new(["https://example.com"])))
```

`GET`, `HEAD` and `OPTIONS` pass through, so pages and preflights still work.
Every other method must carry exactly one `origin` header matching one of the
origins, or it gets `403` before the handler runs. `null`, a different scheme,
a different port and a host that merely starts with an allowed one are all
rejected. Origins must be `scheme://host` with an optional port; anything else
panics when built.

Some proxies and privacy tools strip `origin`. When it is missing, a single
`sec-fetch-site: same-origin` header is accepted in its place: browsers set it
themselves and scripts cannot forge it. An `origin` that is present always
decides, and a request with neither header fails closed.

The protection is header-based by design and uses no tokens. Every current
browser sends these headers. Go's standard library protects against CSRF the
same way, with `http.CrossOriginProtection`. OWASP's CSRF cheat sheet treats
`Sec-Fetch-Site` with an origin fallback as a primary defence, and its
Application Security Verification Standard (4.0, requirement 13.2.3) lists
origin header checks among the accepted protections.

Because it rejects requests with neither header, it also rejects non-browser
clients. Where those authenticate with a bearer token rather than a cookie, a
hostile page cannot make a browser send one on their behalf, so exempt them:

```gleam
csrf.new(["https://example.com"])
|> csrf.exempt(fn(ctx) {
  case request.get_header(ctx.request, "authorization") {
    Ok("Bearer " <> _) -> True
    _ -> False
  }
})
```

`csrf.check(ctx, origins)` runs the same check inside a guard or a single
handler. Keep `SameSite` cookies as well, since the two fail in different
ways, and never write on a `GET` route, because those are not checked.

## Cookies

Read cookies with `use` and write them through response pipelines:

```gleam
import howdy/controller
import howdy/cookie

pub fn preferences_controller() {
  controller.new("/preferences")
  |> controller.get("/", fn(ctx) {
    use theme <- cookie.string_or(ctx, "theme", default: "system")
    controller.text(ctx, theme)
  })
  |> controller.post("/dark", fn(ctx) {
    let options =
      cookie.defaults()
      |> cookie.max_age(60 * 60 * 24 * 30)
      |> cookie.same_site(cookie.Lax)

    controller.text(ctx, "Preference saved")
    |> cookie.set("theme", "dark", options)
  })
  |> controller.delete("/", fn(ctx) {
    controller.text(ctx, "Preference cleared")
    |> cookie.delete("theme", cookie.defaults())
  })
}
```

- `string` requires a cookie; absence returns `400` with
  `{"error":"missing cookie theme"}` for a cookie named `theme`.
- `optional_string` returns `Option(String)`; `string_or` defaults only when absent.
- Empty values remain empty. Duplicate names and invalid percent encoding return
  JSON `400` responses and stop the handler. The HTTP parser ignores malformed pairs.
- Values are percent-encoded when written and decoded when read, preserving spaces,
  Unicode, punctuation, and literal percent signs. External cookie writers should
  use the same encoding convention.
- `set` and `delete` preserve existing headers, including other `Set-Cookie` headers.

Defaults enable `Secure`, `HttpOnly`, `SameSite=Lax`, and `Path=/`, with no domain
attribute or persistent lifetime. Configure them using `max_age` (seconds),
`same_site` (`Lax`, `Strict`, or `None`), `path`, `domain`, `secure`, and `http_only`.
For local HTTP development use `cookie.defaults() |> cookie.secure(False)`.
`SameSite=None` requires `Secure`. Invalid names, paths, domains, or incompatible
options panic as configuration errors; values are safely encoded by `set`.

To delete a cookie, pass options with the same path and domain used when setting
it. Deletion writes an empty value, `Max-Age=0`, and an expiry in the past, following
the [browser cookie deletion rules](https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/Cookies).

These helpers read and write cookies; they do not sign them or validate sessions.
For authentication, let a guard validate the session and return `401` when needed.

## Authentication and authorization

[`howdy_auth`](https://github.com/mikeyjones/howdy/blob/v2/auth/README.md) is an optional package with email-token, opt-in password
and built-in Google login and registration, browser cookie sessions, bearer-token API routes, and optional
starter pages. Custom pages can call the same JSON endpoints or use the headless
operations directly. Separate role-based authorization supports simple role
checks and permissions scoped to an application or organization.

The package accepts a configured Gloo Repo (PostgreSQL or SQLite), owns its
schema, and ships explicit, checksummed migrations.
[`howdy_database`](https://github.com/mikeyjones/howdy/blob/v2/database/README.md) provides those migrations and the
portable transactions beneath them, and applications can use it for their own
tables, with or without auth.
See [the runnable example](https://github.com/mikeyjones/howdy/blob/v2/examples/auth/README.md) and the package documentation
for setup and current scope; enterprise federation is not yet
implemented.

## Static files

`howdy/static` serves the files in a directory. Mount it like any controller:

```gleam
import howdy/static

howdy.new()
|> howdy.controller(api_controller())
|> howdy.controller(static.serve("/", from: "priv/public"))
```

`GET /css/site.css` answers with `priv/public/css/site.css` and a content type
from its extension. `GET /` and `GET /docs/` answer with the `index.html` in
that directory. Only `GET` and `HEAD` are handled, directories are never
listed, and paths that would escape the root get a `404`. On a live
connection files are sent by ewe without being held in memory.

The public directory is for trusted deployment assets. The root itself and
every requested component must be real files/directories: symbolic links,
including linked indexes and fallbacks, return `404`. Index and fallback names
must be relative paths without `..`, drive prefixes or backslashes; invalid
configuration panics when built. Keep this tree inaccessible to untrusted
writers. These path checks do not protect against concurrent filesystem swaps;
do not use this controller for an attacker-writable upload directory.

Build it step by step to change the defaults:

```gleam
static.new(from: "priv/public")
|> static.at("/assets")              // mount under a prefix, default "/"
|> static.index("home.html")         // directory index, default "index.html"
|> static.max_age(seconds: 86_400)   // add a cache-control header
|> static.fallback("index.html")     // single-page apps: unknown paths get this file
|> static.build
```

The result is an ordinary controller, so `controller.middleware` and the rest
apply. A controller at `"/"` matches every path, so add it last, and mount it
under a prefix when the app has a version group: the group only answers paths
no controller matched.

To send one file from a handler, use `static.file`. It answers `404` in the
standard error shape when the file is missing:

```gleam
controller.get("/invoice/:id", fn(ctx) {
  use id <- param.int(ctx, "id")
  static.file(ctx, "priv/invoices/" <> int.to_string(id) <> ".pdf")
})
```

## Request logging

Use `howdy/logger` to log the request method, path and response status with
the `logging` library at `Info` level, for example `GET /user/2 -> 200`:

```gleam
import howdy
import howdy/logger
import logging

logging.configure()

howdy.new()
|> howdy.middleware(logger.log)
```

Configure logging once at application startup. Add the logger before other
middleware to include their rejected requests and CORS preflight responses.
The response is returned unchanged. Query strings, headers and bodies are
omitted. Unmatched routes bypass middleware, so their 404 responses are not
logged; handlers that panic do not produce a request log either.

## CORS

Browsers only let a page read cross-origin responses that say so. Attach
`howdy/cors` as the outermost middleware to add those headers and answer
preflight requests:

```gleam
import gleam/http
import howdy
import howdy/cors

let policy =
  cors.new()
  |> cors.allow_origins(["https://app.example.com", "http://localhost:5173"])
  |> cors.allow_methods([http.Get, http.Post, http.Delete])
  |> cors.allow_headers(["content-type", "authorization"])
  |> cors.expose_headers(["x-request-id"])
  |> cors.allow_credentials()
  |> cors.max_age(600)

howdy.new()
|> howdy.middleware(cors.middleware(policy))
|> howdy.middleware(require_api_key)
|> howdy.controller(user.controller())
```

- `cors.new()` allows no origins. Add them with `allow_origins`,
  `allow_any_origin`, or `allow_origins_matching` with your own function.
  `cors.allow_all()` is a ready-made policy for public APIs: any origin and any
  requested header, without credentials.
- Origins are `scheme://host` with an optional port, such as
  `http://localhost:5173`, and match case-insensitively. A path, trailing slash
  or `*` panics as a configuration error. List `null` to allow sandboxed pages.
- Methods default to `GET`, `HEAD`, `POST`, `PUT`, `PATCH` and `DELETE`. No
  request headers beyond the browser safelist are allowed until you name them
  with `allow_headers` or echo whatever was asked for with `allow_any_header`.
- `allow_credentials` cannot be combined with `allow_any_origin`; building the
  middleware panics. Use `allow_origins_matching(fn(_) { True })` if you really
  mean it.

A preflight is an `OPTIONS` request carrying `origin` and
`access-control-request-method`. The middleware answers it with `204` and never
calls the handler, so put CORS before authentication or rate limiting, which
would otherwise reject the credential-less preflight. Other requests with an
`origin` run as normal and the response gains the CORS headers, including error
responses, so the browser can show a `422` instead of a CORS failure. Requests
without an `origin` pass through without CORS headers.

The router answers `OPTIONS` for any path that has routes, even without an
explicit `OPTIONS` route: a `204` with an `allow` header, run through the
controller's middleware but not its guard. Declare an `OPTIONS` route yourself
to override that. Paths with no routes are `404` before any middleware runs, so
they carry no CORS headers.

Responses that depend on the origin carry `vary: origin`, including requests
without an Origin header. This also applies to wildcard policies because they
omit CORS headers when Origin is absent. Existing `Vary` fields are preserved,
including version-group headers and `Vary: *`.

## Versioning

Group controllers by API version and let newer versions fall back to older ones
for anything they do not override:

```gleam
import howdy
import howdy/version

let api =
  version.new(version.path())
  |> version.default("v1")
  |> version.add("v1", [user_v1.controller(), order.controller()])
  |> version.add("v2", [user_v2.controller()])

howdy.new()
|> howdy.controller(health.controller())
|> howdy.versions(api)
|> howdy.handler
```

- `GET /v2/users` hits the `v2` user controller. `GET /v2/orders` falls back to the
  `v1` order controller. Fallback is per route, so `POST /v2/users` also falls back
  if `v2` only declares `GET`. Fallback walks versions in reverse declaration order.
- `GET /users` uses the default version. Without a default a missing version is
  `404` for the path strategy and `400` for the others.
- `version.no_fallback` makes every version answer only its own routes.
- Unversioned controllers are matched first and never see a version.
- Handlers and middleware read `ctx.version`, an `Option(String)`. The original
  request path is preserved, including the version segment.

One strategy applies per app. Pick it with the argument to `version.new`:

- `version.path()` reads `/v2/...` and strips the segment before routing. This is
  the default choice: URLs are shareable, cacheable and easy to test.
- `version.header("x-api-version")` reads a request header.
- `version.accept("vnd.howdy")` reads `application/vnd.howdy.v2+json` from the
  `accept` header.
- `version.custom(fn)` runs your own function from the request to an
  `Option(String)`.

Header and accept strategies answer `400` with `{"error":"unknown API version v9"}`
for undeclared versions and add a `vary` header to every response from the group.
Mixing strategies with precedence rules is deliberately unsupported; write a custom
resolver if you need it. Versions are opaque strings ordered by declaration, so date
based names such as `2026-09-14` work as well as `v1`.

Duplicate version names, a default that was never added, and mounting two groups on
one app panic when the app is built.

## WebSockets

A WebSocket is a `GET` route that ends in `websocket.upgrade`, so it goes
through the same middleware, guards and versioning as any other route. Browsers
cannot set headers on the handshake, so socket guards usually read a cookie or
a query parameter.

```gleam
import howdy/websocket
import howdy/websocket/channel

controller.new("chat")
|> controller.get("/:room", fn(ctx) {
  use room <- param.string(ctx, "room")

  websocket.new(fn(socket) {
    channel.join(socket, "room:" <> room)
    room
  })
  |> websocket.on_text(fn(_socket, room, text) {
    channel.broadcast_text("room:" <> room, text)
    websocket.continue(room)
  })
  |> websocket.on_close(fn(_socket, _room) { Nil })
  |> websocket.upgrade(ctx)
})
```

- `websocket.new(on_open)` returns the starting state. Add `on_text`, `on_binary`
  or `on_json(decoder, ...)` for frames from the client, and `on_message` for
  messages other processes send to `websocket.subject(socket)`. Every callback
  returns `websocket.continue(state)` or `websocket.close(socket, code, reason)`.
- Send with `send_text`, `send_binary` or `send_json` on the socket handle.
- `howdy/websocket/channel` groups sockets under a topic. `channel.join` and
  `channel.leave` manage membership; `channel.broadcast_text` and
  `channel.broadcast_json` reach every socket on a topic from anywhere in the
  program, including plain HTTP handlers. Topics are Erlang `pg` groups, so a
  socket that closes or crashes is removed automatically.
- In `howdy/testing` there is no connection to upgrade, so a socket route
  answers `426` there. Test the guards and parameters in front of it as usual.

See `examples/chat` for a working chat room.

Socket upgrades check browser `Origin` before opening the connection. The
default accepts only the request's own HTTP(S) scheme, hostname and port;
malformed, duplicate and `null` origins receive `403`. Behind a reverse proxy
that terminates TLS, the scheme comes from `X-Forwarded-Proto` and the host
from `X-Forwarded-Host` when the proxy sends them, so live pages work behind
Traefik, Caddy, nginx and most hosting platforms without configuration. A
hostile page cannot set those headers on a browser's handshake, so the check
is no weaker for it; client addresses still ignore them. Non-browser clients
without Origin remain supported; add `websocket.require_origin` for a
browser-only endpoint. Origin checks complement authentication, not replace it.

For pages served from another origin, such as a separate frontend, configure
exact public origins on the socket builder:

```gleam
websocket.new(on_open)
|> websocket.allow_origins(["https://app.example.com"])
|> websocket.require_origin
|> websocket.upgrade(ctx)
```

For live components, apply these options to `live.socket(app, args)` or `live.socket_shared(runtime)` before
`websocket.upgrade(ctx)`; the direct `live.serve` helpers use the same-origin
default.

## Server-sent events

`howdy/sse` keeps a `GET` response open and pushes events to the browser's
`EventSource`. Like a socket it is an ordinary route, runs in its own process
and is reached from anywhere through topics or its subject.

```gleam
import howdy/sse

controller.new("orders")
|> controller.get("/events", fn(ctx) {
  sse.new(fn(stream) {
    sse.join(stream, "orders")
    Nil
  })
  |> sse.start(ctx)
})

// Anywhere else in the program:
sse.broadcast("orders", sse.json(order_json) |> sse.name("order.created"))
```

- `sse.new(on_open)` returns the starting state; `on_message` handles what
  other processes send to `sse.subject(stream)`, and `on_close` runs however
  the stream ends. Callbacks return `sse.continue(state)` or `sse.stop()`.
- Build events with `sse.event` or `sse.json`, then `name`, `id` and `retry`.
  `sse.last_event_id(stream)` is the ID a reconnecting browser last saw.
- `sse.join`, `sse.leave` and `sse.broadcast` work like WebSocket channels,
  across nodes, but on their own topics.
- A comment is sent every 15 seconds so proxies keep idle streams open; change
  it with `sse.heartbeat` or turn it off with `sse.no_heartbeat`.
- `testing.open_events(res)` runs a stream in a test, with
  `testing.next_event` and `testing.close_events`.

For one long body sent a piece at a time, such as a CSV export,
`stream.body` from `howdy/stream` writes it in chunks as it is produced.

## Pages and live components

Web pages, themes and Lustre server components live in a separate package,
[`howdy_ui`](https://github.com/mikeyjones/howdy/blob/v2/ui/README.md), so howdy itself stays free of Lustre and Sketch.

```gleam
import howdy/ui
import howdy/ui/live
import howdy/ui/page

controller.new("/")
|> controller.get("/", fn(ctx) {
  use theme <- cookie.string_or(ctx, "theme", default: "system")
  page.new("Counter")
  |> page.theme(theme)
  |> page.live
  |> page.body([ui.h1("Counter"), live.mount("/counter")])
  |> page.respond(ctx)
})
|> controller.get("/counter", fn(ctx) { live.serve(ctx, counter.app(), with: 0) })
```

Themes are records that compile to CSS variables, and every component reads
them, so switching light and dark is one attribute change. Components can be
copied into your project to edit with `gleam run -m howdy/ui add button`. The CSS is
embedded in each page by default, served as one file in development with
`ui.stylesheet`, or written to a minified static file for publishing with
`howdy/ui/export`. See `examples/live` for a working page.

## Calling other services

[`howdy_remote`](https://github.com/mikeyjones/howdy/blob/v2/remote/README.md) is an optional package for typed calls
between services. Define a procedure once in a module both services share,
serve it from the service that owns the data, and call it from anywhere:

```gleam
pub fn get_user() -> remote.Procedure(Int, User) {
  remote.procedure("users.get", input: remote.int(), output: user_codec())
}

// In the users service. Handlers return the usual `service.Result`.
remote.server()
|> remote.handle(users_api.get_user(), user_service.find)
|> remote.start

// In any other service.
remote.call(remote.cluster(), users_api.get_user(), id, timeout: 5000)
|> remote.respond(ctx, user.to_json)
```

Calls travel over Erlang distribution between trusted nodes, or over HTTP
with a bearer token across a trust boundary. The call site stays the same;
only the target changes. See `examples/remote` for two services calling each other.

## Hot reload

[`howdy_dev`](https://github.com/mikeyjones/howdy/blob/v2/howdy_dev/README.md) is a dev dependency that rebuilds and
reloads the app when a file under `src` changes, and refreshes open pages.
Put an entry point in `dev/` and run it with `gleam dev`:

```gleam
import howdy/dev
import my_app

pub fn main() {
  let assert Ok(_) = dev.start(my_app.app)
  process.sleep_forever()
}
```

It polls files rather than using a native watcher, so it works the same on
macOS. Nothing from it reaches a `gleam export erlang-shipment`.

## Development admin

[`howdy_admin`](https://github.com/mikeyjones/howdy/blob/v2/admin/README.md) is a dev dependency that mounts an admin
area at `/_howdy` from the same `dev/` entry point: the tables of the app's
database in a grid that follows changes, its users and groups, and its
roles and permissions, with a button to sign in to the app as any user. The app registers what it has,
since Gleam cannot discover packages at runtime:

```gleam
dev.start(fn() {
  my_app.app(db, identity)
  |> admin.mount(
    admin.new() |> admin.auth(identity) |> admin.authorization(permissions),
  )
})
```

See `examples/admin` for a working app.

## Telemetry

[`howdy_telemetry`](https://github.com/mikeyjones/howdy/blob/v2/telemetry/README.md) switches on OpenTelemetry. Howdy
opens a span for every request, query, remote call, email and sign-in with
`howdy/trace`, but they go nowhere until the app starts telemetry, so apps
that do not want it pay next to nothing. Send traces to any OTLP collector
in production, or record them in memory for the admin to show:

```gleam
let assert Ok(Nil) =
  telemetry.new("acme-web")
  |> telemetry.otlp
  |> telemetry.start
```

## Email

[`howdy_mail`](https://github.com/mikeyjones/howdy/blob/v2/mail/README.md) writes email with
[smail](https://hexdocs.pm/smail) templates and sends it over SMTP, Resend,
SendGrid or an adapter of your own. In development an outbox keeps the mail
instead, and the admin shows it as it arrives, along with previews of every
template rendered from sample data:

```gleam
let mailer =
  mail.mailer(smtp.adapter(smtp_config))
  |> mail.default_from(mail.named("Acme", "hello@acme.test"))

mail.message()
|> mail.to([mail.address(user.email)])
|> mail.subject("Welcome to Acme")
|> mail.template(welcome_email(user))
|> mail.send(mailer, _)
```

`howdy/auth/emails` gives `howdy_auth` a ready-made email for every purpose.

## Feature flags

[`howdy_flags`](https://github.com/mikeyjones/howdy/blob/v2/flags/README.md) keeps feature flags defined in code and
switched at runtime: a kill switch, users, organizations and groups a flag is
allowed or blocked for, and a rollout to a share of users that only ever adds
people as it grows, raised by hand or step by step on a schedule. Checks read
memory, never the store, and every change is recorded and can be undone.
Settings live in the app's database by default, in memory, or anywhere a
store can load them from. In development the admin shows them under
**Flags**; on your own servers, `howdy/flags/cli` manages them from a task
module:

```gleam
let assert Ok(store) = flags_database.store(db)
let assert Ok(features) =
  flags.new(store) |> flags.register([new_checkout()]) |> flags.start

flags.enabled(features, new_checkout(), for: flags.user(user.id))
```

## Testing

`howdy/testing` runs requests through an app without starting a server. The
whole pipeline runs: routing, middleware, guards, versioning, body decoding and
validation. Keep the app separate from `main` so tests can build it too:

```gleam
import gleam/json
import howdy/service.{FieldError}
import howdy/testing
import my_app

pub fn create_user_test() {
  let res =
    testing.post("/user", json.object([#("name", json.string("Ada"))]))
    |> testing.header("x-api-key", "secret")
    |> testing.send(my_app.app())

  assert res.status == 201
  assert testing.json(res, user.decoder()) == Ok(User(id: 1, name: "Ada"))
}

pub fn blank_name_is_rejected_test() {
  let res =
    testing.post("/user", json.object([#("name", json.string(""))]))
    |> testing.send(my_app.app())

  assert res.status == 422
  assert testing.field_errors(res)
    == Ok([FieldError("name", "must not be empty")])
}
```

- Build requests with `get`, `delete`, or `post`, `put` and `patch` taking JSON.
  `post_form` takes form fields. `request(method, path)` covers the rest. A
  query string in the path is kept.
- Adjust them with `header`, `query`, `cookie`, `json_body`, `form_body`,
  `text_body`, `bytes_body` and `from_ip`, which makes `rate_limit.by_ip` count the request.
  Requests are plain `gleam/http/request` values, so its functions work too.
- Read responses with `text`, `bytes`, `json` with a decoder, `error` for the
  message in `{"error": "..."}`, `field_errors` for a `422`, and `cookies` for
  the name and value pairs the response sets.

Both [example applications](https://github.com/mikeyjones/howdy/tree/v2/examples) have a test suite written this way.

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
```


## Performance checks

`howdy.start` compiles route and middleware tables once. When integrating with
Ewe directly, construct `howdy.handler(app)` once and reuse the returned handler.
Declaration order, wildcard fallback and version fallback remain unchanged.

Route dispatch is indexed, so its cost does not grow with the number of
controllers; a 512-controller app dispatches as fast as a one-controller app.
Run `gleam run -m routing_benchmark` for dispatch throughput and heap allocation,
and `gleam run -m rate_limit_benchmark` for identity-cardinality scaling.
CI tests every package and every example in `examples/`, and runs both
benchmarks. Generated `build/` directories are ignored throughout the repository.

### Reserved optional-package modules

The core package reserves `howdy/auth`, every `howdy/auth/*` module and
`howdy/authorization` for the optional `howdy_auth` package, and
`howdy/database` and `howdy/migration` for `howdy_database`,
`howdy/remote` and every `howdy/remote/*` module for `howdy_remote`, and
`howdy/admin` and every `howdy/admin/*` module for `howdy_admin`, and
`howdy/mail` and every `howdy/mail/*` module for `howdy_mail`, and
`howdy/flags` and every `howdy/flags/*` module for `howdy_flags`,
`howdy/openapi` and every `howdy/openapi/*` module for `howdy_openapi`,
`howdy/telemetry` and every `howdy/telemetry/*` module for `howdy_telemetry`,
`howdy/ui` and every `howdy/ui/*` module for `howdy_ui`, and `howdy/dev` and
every `howdy/dev/*` module for `howdy_dev`. Core must not
define these modules: Gleam/BEAM module names are
global across dependencies. CI runs `scripts/check-auth-namespace.sh` to
reject collisions. Applications should put their own modules in their own
namespace.
