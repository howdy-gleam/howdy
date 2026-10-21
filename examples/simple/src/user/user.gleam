//// The user type, its JSON codecs, and the validator for new users.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import howdy/validate

pub type User {
  User(id: Int, name: String, email: String, age: Int)
}

/// Straight off the wire, nothing checked yet.
pub type NewUserInput {
  NewUserInput(name: String, email: String, age: Int)
}

/// Only `validate` can produce one of these, so the service can trust it.
pub type NewUser {
  NewUser(name: String, email: String, age: Int)
}

pub fn to_json(user: User) -> Json {
  json.object([
    #("id", json.int(user.id)),
    #("name", json.string(user.name)),
    #("email", json.string(user.email)),
    #("age", json.int(user.age)),
  ])
}

pub fn input_decoder() -> Decoder(NewUserInput) {
  use name <- decode.field("name", decode.string)
  use email <- decode.field("email", decode.string)
  use age <- decode.field("age", decode.int)
  decode.success(NewUserInput(name:, email:, age:))
}

pub fn validate(input: NewUserInput) -> validate.Result(NewUser) {
  use name <- validate.field("name", input.name, [
    validate.trim(),
    validate.not_empty(),
    validate.max_length(50),
  ])
  use email <- validate.field("email", input.email, [
    validate.trim(),
    validate.email(),
  ])
  use age <- validate.field("age", input.age, [
    validate.min(13),
    validate.max(150),
  ])
  validate.ok(NewUser(name:, email:, age:))
}
