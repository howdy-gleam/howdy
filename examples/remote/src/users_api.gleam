//// The contract between the two services. In a real system this module
//// lives in a small package that both services depend on, so the caller
//// and the server always agree on names and types.

import gleam/dynamic/decode
import gleam/json.{type Json}
import howdy/codec
import howdy/remote

pub type User {
  User(id: Int, name: String)
}

pub fn user_to_json(user: User) -> Json {
  json.object([#("id", json.int(user.id)), #("name", json.string(user.name))])
}

fn user() -> codec.Codec(User) {
  codec.new(encode: user_to_json, decoder: {
    use id <- decode.field("id", decode.int)
    use name <- decode.field("name", decode.string)
    decode.success(User(id:, name:))
  })
}

pub fn get_user() -> remote.Procedure(Int, User) {
  remote.procedure("users.get", input: codec.int(), output: user())
}

pub fn list_users() -> remote.Procedure(Nil, List(User)) {
  remote.procedure("users.list", input: codec.nil(), output: codec.list(user()))
}
