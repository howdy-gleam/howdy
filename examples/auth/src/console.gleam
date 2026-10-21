//// Shortcuts for an interactive console attached to the running full tour.
//// Start the server as a named node, then attach GSH to it from another
//// terminal; the README has the commands.
////
//// Everything typed there runs inside the server, with the database, auth
//// and roles `main` configured:
////
////     gsh(1)> console.users()
////     gsh(2)> console.grant("ada@example.com", "reader")
////
//// These are privileged operations with no authorization of their own, so the
//// console must only be reachable by the application's operators. Their audit
//// events record the client `console`.

import gleam/list
import gleam/result
import howdy/auth
import howdy/auth/user.{type User}
import howdy/auth/users
import howdy/authorization as access
import howdy/console as exposed
import howdy/service
import howdy_auth_example.{type Services}
import notes.{type Note}

const actor = user.SystemFrom(client: "console")

/// The running server's services. Panics on a node where `main` has not run.
pub fn services() -> Services {
  case exposed.get(howdy_auth_example.services_key()) {
    Ok(services) -> services
    Error(Nil) ->
      panic as "the server is not running on this node: attach to it with --remsh, or run gleam run -m gsh -- howdy_auth_example"
  }
}

pub fn users() -> service.Result(List(User)) {
  users.list(services().identity)
}

pub fn user(email: String) -> service.Result(User) {
  use all <- result.try(users())
  list.find(all, fn(user) { user.email == email })
  |> result.replace_error(service.NotFound("user"))
}

/// Create an account without sending anything; the user signs in with an
/// email token when they are ready.
pub fn provision(email: String) -> service.Result(User) {
  auth.provision(services().identity, email, by: actor)
}

/// The roles the user holds, as scope and name.
pub fn roles(email: String) -> service.Result(List(#(access.Scope, String))) {
  use user <- result.try(user(email))
  access.assignments(services().permissions, user.id)
}

/// Assign a global role, such as `reader` for `/account/reports`.
pub fn grant(email: String, role: String) -> service.Result(Nil) {
  use user <- result.try(user(email))
  access.assign(services().permissions, user.id, role, access.Global, by: actor)
}

pub fn revoke(email: String, role: String) -> service.Result(Nil) {
  use user <- result.try(user(email))
  access.revoke(services().permissions, user.id, role, access.Global, by: actor)
}

pub fn sessions(email: String) -> service.Result(List(auth.SessionInfo)) {
  use user <- result.try(user(email))
  auth.sessions_of(services().identity, user.id)
}

/// End every session the user has, on every device.
pub fn sign_out(email: String) -> service.Result(Nil) {
  use user <- result.try(user(email))
  auth.revoke_sessions(services().identity, user.id, by: actor)
}

pub fn suspend(email: String) -> service.Result(Nil) {
  use user <- result.try(user(email))
  auth.suspend(services().identity, user.id, by: actor)
}

pub fn resume(email: String) -> service.Result(Nil) {
  use user <- result.try(user(email))
  auth.resume(services().identity, user.id, by: actor)
}

pub fn notes(email: String) -> service.Result(List(Note)) {
  use user <- result.try(user(email))
  notes.list(services().db, user)
}
