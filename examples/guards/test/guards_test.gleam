//// Every request from the README's curl list, run through the app without a
//// server. `howdy_guards_example.app()` builds the app; `howdy/testing`
//// sends requests through it and reads the responses.

import gleam/dynamic/decode
import howdy/testing
import howdy_guards_example.{app}

fn as_member(req) {
  testing.header(req, "authorization", "Bearer member-token")
}

fn as_admin(req) {
  testing.header(req, "authorization", "Bearer admin-token")
}

fn profile_name() -> decode.Decoder(String) {
  decode.at(["name"], decode.string)
}

pub fn public_route_needs_no_token_test() {
  let res = testing.get("/public/hello") |> testing.send(app())

  assert res.status == 200
  assert testing.text(res) == "Hello, anyone!"
}

pub fn endpoint_guard_rejects_anonymous_requests_test() {
  let res = testing.get("/public/me") |> testing.send(app())

  assert res.status == 401
  assert testing.error(res) == Ok("unauthorized")
}

pub fn endpoint_guard_passes_the_user_to_the_handler_test() {
  let res = testing.get("/public/me") |> as_member |> testing.send(app())

  assert res.status == 200
  assert testing.json(res, profile_name()) == Ok("Ada")
}

pub fn controller_guard_protects_every_route_test() {
  assert { testing.get("/account/me") |> testing.send(app()) }.status == 401
  assert { testing.get("/account/admin/42") |> testing.send(app()) }.status
    == 401
}

pub fn controller_guard_supplies_the_current_user_test() {
  let member = testing.get("/account/me") |> as_member |> testing.send(app())
  assert testing.json(member, profile_name()) == Ok("Ada")

  let admin = testing.get("/account/me") |> as_admin |> testing.send(app())
  assert testing.json(admin, profile_name()) == Ok("Grace")
}

pub fn admin_endpoint_needs_admin_role_test() {
  let member =
    testing.get("/account/admin/42") |> as_member |> testing.send(app())
  assert member.status == 403
  assert testing.error(member) == Ok("forbidden")

  let admin =
    testing.get("/account/admin/42") |> as_admin |> testing.send(app())
  assert admin.status == 200
  assert testing.text(admin) == "Admin access to record 42"
}

pub fn admin_endpoint_validates_the_id_after_the_guard_test() {
  let res =
    testing.get("/account/admin/nope") |> as_admin |> testing.send(app())

  assert res.status == 400
  assert testing.error(res) == Ok("parameter id must be an integer")
}
