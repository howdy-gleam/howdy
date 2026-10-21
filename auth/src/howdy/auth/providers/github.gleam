//// GitHub OAuth Apps server flow. GitHub has no OpenID Connect: identity is
//// taken from the REST endpoints after a single code exchange. A verified
//// address from `/user/emails` is authoritative, preferring the primary one;
//// a profile address (or a hidden, null one) must first register or verify
//// through the email flow, then link. No GitHub tokens are stored or returned.

import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import howdy/auth/provider.{type Provider}
import howdy/auth/secret
import howdy/service

const issuer = "https://github.com"

const authorize_url = "https://github.com/login/oauth/authorize"

const token_url = "https://github.com/login/oauth/access_token"

const user_url = "https://api.github.com/user"

const emails_url = "https://api.github.com/user/emails"

pub fn new(
  client_id client_id: String,
  client_secret client_secret: String,
) -> Provider {
  with_transport(client_id, client_secret, send)
}

/// Internal network seam. GitHub signs nothing itself, so tests replace only
/// the transport; the account rules live in the shared provider runtime.
@internal
pub fn with_transport(
  client_id: String,
  client_secret: String,
  send: fn(Request(String)) -> service.Result(Response(String)),
) -> Provider {
  let client_secret = secret.wrap(client_secret)
  // Fixed URLs parse once here, at installation, so no sign-in can fail on
  // building a request from a constant.
  let assert Ok(token_request) = request.to(token_url)
  let assert Ok(user_request) = request.to(user_url)
  let assert Ok(emails_request) = request.to(emails_url)
  let valid = case
    string.trim(client_id) != "" && secret.reveal(client_secret) != ""
  {
    True -> Ok(Nil)
    False ->
      Error(service.Invalid("GitHub requires a client ID and client secret"))
  }
  provider.new(
    "github",
    "GitHub",
    valid,
    fn(auth) {
      authorize_url
      <> "?"
      <> uri.query_to_string([
        #("client_id", client_id),
        #("redirect_uri", auth.redirect_uri),
        #("scope", "read:user user:email"),
        #("state", auth.state),
        #("code_challenge", auth.challenge),
        #("code_challenge_method", "S256"),
      ])
    },
    fn(exchange) {
      use response <- result.try(
        post(send, token_request, [
          #("client_id", client_id),
          #("client_secret", secret.reveal(client_secret)),
          #("code", secret.reveal(exchange.code)),
          #("redirect_uri", exchange.redirect_uri),
          #("code_verifier", secret.reveal(exchange.verifier)),
        ]),
      )
      use access <- result.try(
        json.parse(
          response,
          decode.field("access_token", decode.string, decode.success),
        )
        |> result.replace_error(service.Unauthorized),
      )
      use access <- result.try(case access == "" {
        True -> Error(service.Unauthorized)
        False -> Ok(access)
      })
      use profile <- result.try(get(send, user_request, access))
      use subject <- result.try(
        json.parse(profile, decode.field("id", decode.int, decode.success))
        |> result.replace_error(service.Unauthorized),
      )
      use stated <- result.try(
        json.parse(
          profile,
          decode.optional_field(
            "email",
            None,
            decode.optional(decode.string),
            decode.success,
          ),
        )
        |> result.replace_error(service.Unauthorized),
      )
      use emails <- result.try(
        list_of_emails(send, emails_request, access)
        |> result.replace_error(service.Unauthorized),
      )
      let #(email, authoritative) = address_of(emails, stated)
      let subject = int.to_string(subject)
      case subject != "" && string.byte_size(subject) <= 255 {
        True ->
          Ok(provider.Identity(issuer, subject, email, authoritative, None))
        False -> Error(service.Unauthorized)
      }
    },
  )
}

/// The verified-address list is the only trustworthy source. A hidden profile
/// address (`email: null`) is used only as an unauthoritative fallback below.
fn list_of_emails(
  send: fn(Request(String)) -> service.Result(Response(String)),
  emails_request: Request(String),
  access: String,
) -> service.Result(List(#(String, Bool, Bool))) {
  use response <- result.try(send(
    emails_request
    |> request.set_header("authorization", "Bearer " <> access)
    |> request.set_header("accept", "application/vnd.github+json")
    |> request.set_header("user-agent", "howdy-auth"),
  ))
  case response.status == 200 && string.byte_size(response.body) <= 1_048_576 {
    True ->
      json.parse(response.body, emails_decoder())
      |> result.replace_error(service.Unauthorized)
    False -> Error(service.Unauthorized)
  }
}

fn emails_decoder() {
  let entry = {
    use address <- decode.field("email", decode.string)
    use primary <- decode.field("primary", decode.bool)
    use verified <- decode.field("verified", decode.bool)
    decode.success(#(address, primary, verified))
  }
  decode.list(entry)
}

fn address_of(
  emails: List(#(String, Bool, Bool)),
  fallback: Option(String),
) -> #(String, Bool) {
  let primary =
    list.find(emails, fn(record) {
      let #(address, primary, verified) = record
      primary && verified && address != ""
    })
  let chosen = case primary {
    Ok(primary) -> Some(primary)
    Error(_) ->
      list.find(emails, fn(record) {
        let #(address, _, verified) = record
        verified && address != ""
      })
      |> option.from_result
  }
  case chosen {
    Some(#(address, _, _)) -> #(address, True)
    None -> #(option.unwrap(fallback, ""), False)
  }
}

fn get(
  send: fn(Request(String)) -> service.Result(Response(String)),
  req: Request(String),
  access: String,
) -> service.Result(String) {
  use response <- result.try(send(
    req
    |> request.set_header("authorization", "Bearer " <> access)
    |> request.set_header("accept", "application/vnd.github+json")
    |> request.set_header("user-agent", "howdy-auth"),
  ))
  let ok =
    response.status == 200 && string.byte_size(response.body) <= 1_048_576
  case ok {
    True -> Ok(response.body)
    False -> Error(service.Unauthorized)
  }
}

// Catch transport exceptions as well as ordinary errors: some OTP socket/TLS
// errors are not represented by gleam_httpc's error type. Never log requests.
@external(erlang, "howdy_auth_oidc_ffi", "protect")
fn protect(
  run: fn() -> service.Result(Response(String)),
  message: String,
) -> service.Result(Response(String))

fn send(req: Request(String)) -> service.Result(Response(String)) {
  protect(
    fn() {
      httpc.configure()
      |> httpc.timeout(10_000)
      |> httpc.dispatch(req)
      |> result.replace_error(service.Internal("GitHub request failed"))
    },
    "GitHub request failed",
  )
}

fn post(
  send: fn(Request(String)) -> service.Result(Response(String)),
  req: Request(String),
  fields: List(#(String, String)),
) -> service.Result(String) {
  let response =
    send(
      req
      |> request.set_method(http.Post)
      |> request.set_header("content-type", "application/x-www-form-urlencoded")
      |> request.set_header("accept", "application/json")
      |> request.set_body(uri.query_to_string(fields)),
    )
  case response {
    Ok(response) ->
      case
        response.status == 200 && string.byte_size(response.body) <= 1_048_576
      {
        True -> Ok(response.body)
        False -> Error(service.Unauthorized)
      }
    _ -> Error(service.Unauthorized)
  }
}
