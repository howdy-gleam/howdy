//// OpenID Connect for an SSO connection. Everything the built-in providers
//// pin in source is configuration here, so it is discovered at the configured
//// issuer and nowhere else: never from a token, and never from a redirect.
//// Only identity scopes are requested; provider tokens are never stored.

import gleam/option.{None, Some}
import gleam/result
import howdy/auth/connection.{type Config, type Connection}
import howdy/auth/internal/oidc
import howdy/auth/provider.{type Provider}
import howdy/auth/secret
import howdy/service

/// A provider for one attempt. Discovery happens here, so beginning a sign-in
/// fails cleanly when the customer's provider is misconfigured or down.
pub fn provider(
  config: Config,
  conn: Connection,
  issuer: String,
  client_id: String,
  client_secret: secret.Secret,
) -> service.Result(Provider) {
  let client =
    oidc.Client(
      issuer:,
      client_id:,
      client_secret:,
      send: connection.transport(config),
      cache: connection.cache(config),
    )
  use metadata <- result.try(oidc.discover(client))
  Ok(
    provider.new(
      connection.identity_issuer(conn.id),
      conn.name,
      Ok(Nil),
      oidc.authorization_url(client, metadata, _),
      fn(exchange) {
        use claims <- result.try(oidc.exchange(client, metadata, exchange))
        Ok(provider.Identity(
          connection.identity_issuer(conn.id),
          claims.subject,
          claims.email,
          // Enterprise providers often omit email_verified. What decides is
          // whether this connection is believed about the domain at all.
          claims.email_verified != Some(False)
            && connection.owns_email(conn, claims.email),
          None,
        ))
      },
    ),
  )
}
