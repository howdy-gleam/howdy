//// Application logic for users. Knows nothing about HTTP; every function
//// returns a `service.Result` which the controller turns into a response.

import gleam/int
import gleam/list
import gleam/result
import howdy/problem
import howdy/service
import user/user.{type NewUser, type User, User}

const users = [
  User(1, "Ada", "ada@example.com", 36),
  User(2, "Grace", "grace@example.com", 45),
  User(3, "Joe", "joe@example.com", 29),
]

pub fn all() -> service.Result(List(User)) {
  Ok(users)
}

pub fn find(id: Int) -> service.Result(User) {
  users
  |> list.find(fn(user) { user.id == id })
  |> result.replace_error(service.NotFound("user " <> int.to_string(id)))
}

/// `input` has already passed `user.validate`. The only check left is one
/// the validator cannot make on its own: is the email already taken?
pub fn create(input: NewUser) -> service.Result(User) {
  case list.any(users, fn(user) { user.email == input.email }) {
    True ->
      Error(
        service.Validation([
          service.FieldError(
            "email",
            problem.Custom("taken", "is already taken"),
          ),
        ]),
      )
    False ->
      Ok(User(
        id: list.length(users) + 1,
        name: input.name,
        email: input.email,
        age: input.age,
      ))
  }
}

pub fn delete(id: Int) -> service.Result(Nil) {
  use _ <- result.try(find(id))
  Ok(Nil)
}
