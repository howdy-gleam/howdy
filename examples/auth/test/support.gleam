//// Each test gets a fresh in-memory database with the schemas migrated, and a
//// mailbox that collects what auth would have emailed.

import demo
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/json
import gleam/list
import gloo/adapter/sqlite
import gloo/repo.{type Repo}
import howdy/auth
import howdy/auth/secret
import howdy/authorization
import howdy/context.{type Body}
import howdy/database
import howdy/migration
import howdy/testing

pub const strong_password = "an uncommon orchard phrase 947!"

pub fn with_database(run: fn(Repo) -> a) -> a {
  let assert Ok(db) = sqlite.start(sqlite.memory())
  let assert Ok(_) = database.sqlite_defaults(db)
  let assert Ok(_) = migration.run(db, [auth.schema(), authorization.schema()])
  let value = run(db)
  let assert Ok(_) = repo.close(db)
  value
}

/// A `deliver` callback that posts each email to the returned subject.
pub fn mailbox() -> #(
  Subject(auth.Delivery),
  fn(auth.Delivery) -> Result(Nil, Nil),
) {
  let inbox = process.new_subject()
  #(inbox, fn(delivery) {
    process.send(inbox, delivery)
    Ok(Nil)
  })
}

pub fn next_email(inbox: Subject(auth.Delivery)) -> auth.Delivery {
  let assert Ok(delivery) = process.receive(inbox, 1000)
  delivery
}

pub fn no_email(inbox: Subject(auth.Delivery)) -> Bool {
  process.receive(inbox, 50) == Error(Nil)
}

pub fn token(delivery: auth.Delivery) -> String {
  secret.reveal(delivery.token)
}

/// Browsers send Origin with every POST; cookie sign-in and cookie-authenticated
/// writes require it to be exactly the configured origin.
pub fn from_browser(req: Request(Body)) -> Request(Body) {
  testing.header(req, "origin", demo.origin)
}

pub fn bearer(req: Request(Body), token: String) -> Request(Body) {
  testing.header(req, "authorization", "Bearer " <> token)
}

pub fn object(pairs: List(#(String, String))) -> json.Json {
  json.object(list.map(pairs, fn(pair) { #(pair.0, json.string(pair.1)) }))
}

pub fn email_field() -> decode.Decoder(String) {
  decode.at(["email"], decode.string)
}

pub fn string_at(path: List(String)) -> decode.Decoder(String) {
  decode.at(path, decode.string)
}

/// Sign `email` up headlessly and return a bearer token for them.
pub fn signed_up(
  identity: auth.Auth,
  inbox: Subject(auth.Delivery),
  email: String,
) -> String {
  let assert Ok(Nil) = auth.request_token(identity, email, auth.Register)
  let assert Ok(session) = auth.exchange(identity, token(next_email(inbox)))
  secret.reveal(session.token)
}
