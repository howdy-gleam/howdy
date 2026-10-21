//// Version 2 of `/user`. Only the list changed: it now comes wrapped in an
//// object with a count. Everything else falls back to version 1, and the
//// v2 document shows both.

import gleam/list
import gleam/option
import howdy/controller
import howdy/openapi/endpoint.{type Endpoint}
import howdy/openapi/schema.{type Schema}
import howdy/service
import user/user.{type User}
import user/user_service

pub type Page {
  Page(users: List(User), count: Int)
}

fn page() -> Schema(Page) {
  {
    use users <- schema.field("users", schema.list(user.user()), fn(page: Page) {
      page.users
    })
    use count <- schema.field("count", schema.int(), fn(page: Page) {
      page.count
    })
    schema.success(Page(users:, count:))
  }
  |> schema.named("UserPage")
}

pub fn controller() -> controller.Controller {
  controller.new("user")
  |> endpoint.get("/", all())
}

fn all() -> Endpoint(Nil) {
  use <- endpoint.describe([
    endpoint.summary("List users"),
    endpoint.response(200, "Every matching user, and how many", page()),
  ])
  use min_age <- endpoint.optional_query("min_age", schema.int())
  use ctx <- endpoint.handle
  user_service.all(option.unwrap(min_age, 0))
  |> service.respond(ctx, fn(users) {
    schema.to_json(Page(users:, count: list.length(users)), page())
  })
}
