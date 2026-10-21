//// SAML 2.0 for an SSO connection: SP-initiated, HTTP-Redirect out and
//// HTTP-POST back. The XML work, and what is and is not accepted, is in
//// `howdy_auth_saml_ffi`.
////
//// The service provider's entity ID is its assertion consumer URL: one value
//// for the customer's administrator to enter, and the audience every
//// assertion must name.

import gleam/option.{None}
import gleam/result
import gleam/string
import gleam/uri
import howdy/auth/connection.{type Connection}
import howdy/auth/internal/address
import howdy/auth/internal/token
import howdy/auth/provider.{type Provider}
import howdy/auth/secret
import howdy/service

@external(erlang, "howdy_auth_saml_ffi", "request")
fn request(id: String, issuer: String, acs: String, to: String) -> String

@external(erlang, "howdy_auth_saml_ffi", "response")
fn response(
  encoded: String,
  certificates: List(String),
  acs: String,
  audience: String,
  issuer: String,
  now: Int,
) -> Result(#(String, String, String), Nil)

@external(erlang, "howdy_auth_saml_ffi", "metadata")
pub fn metadata(entity_id: String, acs: String) -> String

/// In provider terms: `state` travels as RelayState, the nonce names the
/// AuthnRequest, and the "code" exchanged is the posted SAMLResponse. The
/// response must answer that request, which only this browser's attempt knows.
pub fn provider(
  conn: Connection,
  entity_id: String,
  sso_url: String,
  certificates: List(String),
) -> Provider {
  provider.new(
    connection.identity_issuer(conn.id),
    conn.name,
    Ok(Nil),
    fn(auth) {
      sso_url
      <> case string.contains(sso_url, "?") {
        True -> "&"
        False -> "?"
      }
      <> uri.query_to_string([
        #(
          "SAMLRequest",
          request(
            request_id(auth.nonce),
            auth.redirect_uri,
            auth.redirect_uri,
            sso_url,
          ),
        ),
        #("RelayState", auth.state),
      ])
    },
    fn(exchange) {
      use #(in_response_to, name_id, email) <- result.try(
        response(
          secret.reveal(exchange.code),
          certificates,
          exchange.redirect_uri,
          exchange.redirect_uri,
          entity_id,
          token.now(),
        )
        |> result.replace_error(service.Unauthorized),
      )
      use _ <- result.try(case in_response_to {
        "_" <> nonce if nonce != "" ->
          case
            token.constant_time_equal(
              token.digest(nonce),
              exchange.nonce_digest,
            )
          {
            True -> Ok(Nil)
            False -> Error(service.Unauthorized)
          }
        _ -> Error(service.Unauthorized)
      })
      let email = address.normalize_email(email) |> result.unwrap("")
      Ok(provider.Identity(
        connection.identity_issuer(conn.id),
        name_id,
        email,
        connection.owns_email(conn, email),
        None,
      ))
    },
  )
}

/// An XML ID cannot begin with a digit, which a random token may.
fn request_id(nonce: String) -> String {
  "_" <> nonce
}
