//// Local-demonstration plumbing shared by the examples. Printing tokens to the
//// terminal stands in for an email provider **on your own machine only**: a
//// real application delivers them privately and never logs them.

import gleam/erlang/process
import gleam/io
import gleam/option.{None, Some}
import gleam/otp/static_supervisor as supervisor
import howdy
import howdy/auth
import howdy/auth/secret

/// Every example serves the same local origin, one at a time.
pub const origin = "http://localhost:8787"

/// The `deliver` callback `auth.new` takes. Write one email per purpose.
pub fn print_email(delivery: auth.Delivery) -> Result(Nil, Nil) {
  io.println(
    "LOCAL DEMO email to "
    <> delivery.email
    <> " ["
    <> subject(delivery.purpose)
    <> "]: "
    <> secret.reveal(delivery.token)
    <> case delivery.code {
      Some(code) -> "\n  or enter the code " <> secret.reveal(code)
      None -> ""
    }
    <> case delivery.link {
      Some(link) -> "\n  or open " <> secret.reveal(link)
      None -> ""
    },
  )
  Ok(Nil)
}

/// What each email should say. Notices (`EmailChanged`, `PasswordChanged`)
/// carry an empty token. `AlreadyRegistered` means someone tried to register an
/// address that already has an account: tell the owner, rather than inviting
/// them to register again. The HTTP reply was the same either way.
pub fn subject(purpose: auth.Purpose) -> String {
  case purpose {
    auth.SignIn -> "Your sign-in token"
    auth.Registration -> "Confirm your new account"
    auth.AlreadyRegistered ->
      "You already have an account; this token signs you in"
    auth.EmailChange -> "Confirm your new email address"
    auth.EmailChangeApproval ->
      "Approve moving your account to a new email address"
    auth.EmailChanged -> "Your account now uses a different email address"
    auth.PasswordChanged ->
      "Your password was changed; reset it by email if this was not you"
  }
}

/// Read configuration at startup, never from requests. Unset and empty
/// variables are both `Error(Nil)`.
@external(erlang, "howdy_auth_example_ffi", "getenv")
pub fn env(name: String) -> Result(String, Nil)

/// Listen on loopback only: these examples are not meant to be reachable.
pub fn serve(app: howdy.App) -> Nil {
  // Supervised inside an OTP application: restarted on a crash, drained on
  // SIGTERM.
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(howdy.supervised(app |> howdy.bind(to: "127.0.0.1")))
    |> howdy.start_application(name: "howdy_auth_example_server")
  process.sleep_forever()
}
