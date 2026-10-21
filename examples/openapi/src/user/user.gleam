//// The user types and their schemas. Each schema is the decoder, the
//// encoder and the documentation of its type at once.

import howdy/openapi/schema.{type Schema}
import howdy/validate

pub type User {
  User(id: Int, name: String, email: String, age: Int)
}

/// A user to create. Decoding it through `new_user` checks every field, so
/// the service can trust it.
pub type NewUser {
  NewUser(name: String, email: String, age: Int)
}

pub fn user() -> Schema(User) {
  {
    use id <- schema.field("id", schema.int(), fn(user: User) { user.id })
    use name <- schema.field("name", schema.string(), fn(user: User) {
      user.name
    })
    use email <- schema.field("email", schema.string(), fn(user: User) {
      user.email
    })
    use age <- schema.field("age", schema.int(), fn(user: User) { user.age })
    schema.success(User(id:, name:, email:, age:))
  }
  |> schema.named("User")
}

pub fn new_user() -> Schema(NewUser) {
  {
    use name <- schema.field(
      "name",
      schema.string()
        |> schema.rule(validate.trim())
        |> schema.not_empty
        |> schema.max_length(50)
        |> schema.example("Linus"),
      fn(input: NewUser) { input.name },
    )
    use email <- schema.field(
      "email",
      schema.string() |> schema.rule(validate.trim()) |> schema.email,
      fn(input: NewUser) { input.email },
    )
    use age <- schema.field(
      "age",
      schema.int() |> schema.minimum(13) |> schema.maximum(150),
      fn(input: NewUser) { input.age },
    )
    schema.success(NewUser(name:, email:, age:))
  }
  |> schema.named("NewUser")
}
