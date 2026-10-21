//// The JSON API, the starter pages and the guards in front of them.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import howdy
import howdy/auth
import howdy/auth/routes
import howdy/auth/secret
import howdy/auth/user
import howdy/authorization as access
import howdy/service
import howdy/testing
import support.{app, fixture, signup}

const strong_password = "an uncommon orchard phrase 947!"

fn payload(key, value) {
  json.object([#(key, json.string(value))])
}

pub fn browser_api_custom_pages_and_guard_integration_test() {
  use _, identity, permissions, mailbox <- fixture
  let app = app(identity, permissions)
  let sent =
    testing.post("/api/auth/register", payload("email", "ada@example.com"))
    |> testing.header("origin", "https://example.test")
    |> testing.send(app)
  assert sent.status == 202
  assert response.get_header(sent, "cache-control") == Ok("no-store")
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let rejected =
    testing.post(
      "/api/auth/session",
      payload("token", secret.reveal(delivery.token)),
    )
    |> testing.send(app)
  assert rejected.status == 403
  let session =
    testing.post(
      "/api/auth/session",
      payload("token", secret.reveal(delivery.token)),
    )
    |> testing.header("origin", "https://example.test")
    |> testing.send(app)
  assert session.status == 200
  let assert Ok(header) = response.get_header(session, "set-cookie")
  assert string.contains(string.lowercase(header), "httponly")
  assert string.contains(string.lowercase(header), "secure")
  assert string.contains(string.lowercase(header), "samesite=lax")
  let assert [#(name, secret), #("__Host-howdy_mfa", "")] =
    testing.cookies(session)
  assert name == "__Host-howdy_session"
  let me =
    testing.get("/api/auth/me")
    |> testing.cookie(name, secret)
    |> testing.send(app)
  assert me.status == 200
  assert testing.get("/documents") |> testing.send(app) |> fn(r) { r.status }
    == 401
  assert testing.get("/documents")
    |> testing.cookie(name, secret)
    |> testing.send(app)
    |> fn(r) { r.status }
    == 403
  let assert Ok(principal) = auth.authenticate(identity, secret)
  let assert Ok(Nil) =
    access.define_role(
      permissions,
      access.Global,
      "reader",
      ["documents.read"],
      by: user.System,
    )
  let assert Ok(Nil) =
    access.assign(
      permissions,
      principal.user.id,
      "reader",
      access.Global,
      by: user.System,
    )
  assert testing.get("/documents")
    |> testing.cookie(name, secret)
    |> testing.send(app)
    |> fn(r) { r.status }
    == 200
  assert testing.post("/documents", json.null())
    |> testing.cookie(name, secret)
    |> testing.send(app)
    |> fn(r) { r.status }
    == 403
  assert testing.post("/documents", json.null())
    |> testing.cookie(name, secret)
    |> testing.header("origin", "https://example.test")
    |> testing.send(app)
    |> fn(r) { r.status }
    == 200
  let logged_out =
    testing.post("/api/auth/logout", json.null())
    |> testing.cookie(name, secret)
    |> testing.header("origin", "https://example.test")
    |> testing.send(app)
  assert logged_out.status == 204
  assert auth.authenticate(identity, secret) == Error(service.Unauthorized)
  let page = testing.get("/auth/login") |> testing.send(app)
  assert page.status == 200
  assert string.contains(testing.text(page), "Email token")
  // If JavaScript fails, the token must never be submitted in a GET URL.
  assert string.contains(testing.text(page), "method=\"post\" id=\"exchange\"")
  let script = testing.get("/auth/client.js") |> testing.send(app)
  assert response.get_header(script, "content-type")
    == Ok("text/javascript; charset=utf-8")
}

pub fn native_api_bearer_and_ambiguous_credentials_test() {
  use _, identity, permissions, mailbox <- fixture
  let app = app(identity, permissions)
  let sent =
    testing.post("/api/auth/register", payload("email", "api@example.com"))
    |> testing.send(app)
  assert sent.status == 202
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let reply =
    testing.post(
      "/api/auth/token",
      payload("token", secret.reveal(delivery.token)),
    )
    |> testing.send(app)
  assert reply.status == 200
  assert testing.cookies(reply) == []
  let assert Ok(secret) =
    testing.json(
      reply,
      decode.field("access_token", decode.string, decode.success),
    )
  let request =
    testing.get("/api/auth/me")
    |> testing.header("authorization", "Bearer " <> secret)
  assert request |> testing.send(app) |> fn(r) { r.status } == 200
  assert request
    |> testing.cookie(auth.cookie_name(identity), secret)
    |> testing.send(app)
    |> fn(r) { r.status }
    == 401
  let duplicated =
    request.Request(..request, headers: [
      #("authorization", "Bearer " <> secret),
      ..request.headers
    ])
  assert duplicated |> testing.send(app) |> fn(r) { r.status } == 401
  assert testing.post("/documents", json.null())
    |> testing.header("authorization", "Bearer " <> secret)
    |> testing.send(app)
    |> fn(r) { r.status }
    == 200
}

pub fn foreign_origin_duplicate_cookie_and_form_content_type_rejected_test() {
  use _, identity, permissions, mailbox <- fixture
  let app = app(identity, permissions)
  let session = signup(identity, mailbox, "ada@example.com")
  assert testing.post("/api/auth/login", payload("email", "ada@example.com"))
    |> testing.header("origin", "https://evil.test")
    |> testing.send(app)
    |> fn(r) { r.status }
    == 403
  assert testing.post("/api/auth/session", payload("token", "anything"))
    |> testing.header("content-type", "text/plain")
    |> testing.send(app)
    |> fn(r) { r.status }
    == 400
  let dup =
    auth.cookie_name(identity)
    <> "="
    <> secret.reveal(session.token)
    <> "; "
    <> auth.cookie_name(identity)
    <> "="
    <> secret.reveal(session.token)
  assert testing.get("/api/auth/me")
    |> testing.header("cookie", dup)
    |> testing.send(app)
    |> fn(r) { r.status }
    == 401
}

pub fn auth_route_rate_limit_is_enforced_test() {
  use _, identity, permissions, _ <- fixture
  let app = app(identity, permissions)
  let attempt = fn() {
    testing.post("/api/auth/token", payload("token", "wrong"))
    |> testing.from_ip("127.0.0.1")
    |> testing.send(app)
  }
  list.each(list.repeat(Nil, routes.credential_limit), fn(_) {
    assert attempt().status == 401
  })
  let limited = attempt()
  assert limited.status == 429
  assert response.get_header(limited, "cache-control") == Ok("no-store")
  // Signed-in endpoints have their own, looser budget.
  assert testing.get("/api/auth/me")
    |> testing.from_ip("127.0.0.1")
    |> testing.send(app)
    |> fn(r) { r.status }
    == 401
  // Another client is unaffected.
  assert testing.post("/api/auth/token", payload("token", "wrong"))
    |> testing.from_ip("127.0.0.2")
    |> testing.send(app)
    |> fn(r) { r.status }
    == 401
}

pub fn rate_limit_key_is_configurable_for_proxies_test() {
  use _, identity, _, _ <- fixture
  let app =
    howdy.new()
    |> howdy.controller(
      routes.api_limited_by(identity, at: "/api/auth", key: fn(ctx) {
        request.get_header(ctx.request, "x-client") |> option.from_result
      }),
    )
  let attempt = fn(client) {
    testing.post("/api/auth/token", payload("token", "wrong"))
    |> testing.from_ip("10.0.0.1")
    |> testing.header("x-client", client)
    |> testing.send(app)
  }
  list.each(list.repeat(Nil, routes.credential_limit), fn(_) {
    assert attempt("a").status == 401
  })
  assert attempt("a").status == 429
  assert attempt("b").status == 401
}

fn credentials_payload(email, password) {
  json.object([
    #("email", json.string(email)),
    #("password", json.string(password)),
  ])
}

pub fn password_api_supports_cookies_bearer_and_custom_pages_test() {
  use _, identity, permissions, mailbox <- fixture
  let assert Ok(identity) = auth.with_passwords(identity)
  let app = app(identity, permissions)
  let credentials = credentials_payload("api@example.com", strong_password)
  let response =
    testing.post("/api/auth/password/register", credentials)
    |> testing.send(app)
  assert response.status == 202
  assert !string.contains(testing.text(response), strong_password)
  let assert Ok(delivery) = process.receive(mailbox, 1000)
  let verified =
    testing.post(
      "/api/auth/token",
      payload("token", secret.reveal(delivery.token)),
    )
    |> testing.send(app)
  assert verified.status == 200
  assert testing.post("/api/auth/password/session", credentials)
    |> testing.send(app)
    |> fn(r) { r.status }
    == 403
  let login =
    testing.post("/api/auth/password/session", credentials)
    |> testing.header("origin", "https://example.test")
    |> testing.send(app)
  assert login.status == 200
  let assert [#(name, secret), #("__Host-howdy_mfa", "")] =
    testing.cookies(login)
  assert testing.get("/api/auth/me")
    |> testing.cookie(name, secret)
    |> testing.send(app)
    |> fn(r) { r.status }
    == 200
  assert !string.contains(testing.text(login), "encoded_hash")
  let token_response =
    testing.post("/api/auth/password/token", credentials) |> testing.send(app)
  assert token_response.status == 200
  assert testing.cookies(token_response) == []
  let assert Ok(bearer) =
    testing.json(
      token_response,
      decode.field("access_token", decode.string, decode.success),
    )
  assert testing.get("/api/auth/me")
    |> testing.header("authorization", "Bearer " <> bearer)
    |> testing.send(app)
    |> fn(r) { r.status }
    == 200
  let page = testing.get("/auth/password/login") |> testing.send(app)
  assert page.status == 200
  assert string.contains(testing.text(page), "current-password")
  assert string.contains(testing.text(page), "method=\"post\"")
  let register = testing.get("/auth/password/register") |> testing.send(app)
  assert register.status == 200
  assert string.contains(testing.text(register), "new-password")
}
