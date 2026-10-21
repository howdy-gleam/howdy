//// Routes for `/user`. Each endpoint declares what it reads with schemas,
//// so the OpenAPI document matches what the handler really accepts.

import gleam/http/request
import gleam/option
import howdy/controller
import howdy/openapi/endpoint.{type Endpoint}
import howdy/openapi/schema
import howdy/service
import user/user
import user/user_service

pub fn controller() -> controller.Controller {
  controller.new("user")
  |> endpoint.get("/", all())
  |> endpoint.get("/:id", by_id())
  |> endpoint.post("/", create())
  |> endpoint.delete("/:id", delete())
}

fn all() -> Endpoint(Nil) {
  use <- endpoint.describe([
    endpoint.summary("List users"),
    endpoint.response(200, "Every matching user", schema.list(user.user())),
  ])
  use min_age <- endpoint.optional_query(
    "min_age",
    schema.int() |> schema.description("Only users at least this old"),
  )
  use ctx <- endpoint.handle
  user_service.all(option.unwrap(min_age, 0))
  |> service.respond(ctx, schema.to_json(_, schema.list(user.user())))
}

fn by_id() -> Endpoint(Nil) {
  use <- endpoint.describe([
    endpoint.summary("Find a user"),
    endpoint.response(200, "The user", user.user()),
    endpoint.error(404, "No user has this id"),
  ])
  use id <- endpoint.path("id", schema.int())
  use ctx <- endpoint.handle
  user_service.find(id)
  |> service.respond(ctx, schema.to_json(_, user.user()))
}

fn create() -> Endpoint(Nil) {
  use <- endpoint.describe([
    endpoint.summary("Create a user"),
    endpoint.response(201, "The new user", user.user()),
  ])
  use input <- endpoint.body(user.new_user())
  use ctx <- endpoint.handle
  user_service.create(input)
  |> service.created(ctx, schema.to_json(_, user.user()))
}

fn delete() -> Endpoint(Nil) {
  use <- endpoint.describe([
    endpoint.summary("Delete a user"),
    endpoint.security("api_key"),
    endpoint.empty_response(204, "The user was deleted"),
    endpoint.error(401, "The API key is missing or wrong"),
    endpoint.error(404, "No user has this id"),
  ])
  use id <- endpoint.path("id", schema.int())
  use ctx <- endpoint.handle
  case request.get_header(ctx.request, "x-api-key") {
    Ok("secret") -> user_service.delete(id) |> service.no_content(ctx)
    _ -> service.error_response(ctx, service.Unauthorized)
  }
}
