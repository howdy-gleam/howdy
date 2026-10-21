import flows/social_login
import gleam/http/response
import gleam/list
import gleam/string
import howdy/auth
import howdy/auth/providers/github
import howdy/auth/providers/google
import howdy/testing
import support.{from_browser}

fn configured(db, deliver) {
  social_login.configure(db, deliver, [
    google.new(client_id: "google-client", client_secret: "google-secret"),
    github.new(client_id: "github-client", client_secret: "github-secret"),
  ])
}

pub fn configured_providers_appear_on_the_sign_in_page_test() {
  use db <- support.with_database
  let #(_, deliver) = support.mailbox()
  let identity = configured(db, deliver)
  assert auth.providers(identity)
    |> list.map(fn(provider) { provider.0 })
    |> list.sort(string.compare)
    == ["github", "google"]

  let page =
    testing.get("/auth/login") |> testing.send(social_login.app(identity))
  assert string.contains(testing.text(page), "/auth/providers/github/login")
  assert string.contains(testing.text(page), "/auth/providers/google/login")
}

pub fn signing_in_redirects_to_the_provider_test() {
  use db <- support.with_database
  let #(_, deliver) = support.mailbox()
  let app = configured(db, deliver) |> social_login.app

  let started =
    testing.post_form("/auth/providers/github/login", [])
    |> from_browser
    |> testing.send(app)
  assert started.status == 303
  let assert Ok(location) = response.get_header(started, "location")
  assert string.starts_with(
    location,
    "https://github.com/login/oauth/authorize?",
  )
  // The callback URL comes from the configured origin, never the Host header.
  assert string.contains(
    location,
    "redirect_uri=http%3A%2F%2Flocalhost%3A8787%2Fauth%2Fproviders%2Fgithub%2Fcallback",
  )
  // A cookie binds the attempt to this browser, so a stolen callback URL
  // cannot be finished elsewhere.
  assert testing.cookies(started) != []
}

pub fn a_cross_site_start_is_refused_test() {
  use db <- support.with_database
  let #(_, deliver) = support.mailbox()
  let app = configured(db, deliver) |> social_login.app

  let forged =
    testing.post_form("/auth/providers/google/login", [])
    |> testing.header("origin", "https://attacker.example")
    |> testing.send(app)
  assert forged.status == 403
}

pub fn a_callback_without_its_attempt_fails_closed_test() {
  use db <- support.with_database
  let #(_, deliver) = support.mailbox()
  let app = configured(db, deliver) |> social_login.app

  let res =
    testing.get("/auth/providers/google/callback")
    |> testing.query([#("state", "made-up"), #("code", "made-up")])
    |> testing.send(app)
  assert res.status == 303
  assert response.get_header(res, "location") == Ok("/auth/login")
}
