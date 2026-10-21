//// Routes for `/user`. Each handler extracts input, calls the service, and
//// hands the result to `service` to turn into a response.

import gleam/int
import gleam/json
import howdy/body
import howdy/conditional
import howdy/controller.{type Context}
import howdy/middleware
import howdy/param
import howdy/rate_limit
import howdy/service
import middleware/api_key
import middleware/powered_by
import user/user
import user/user_service

pub fn controller() -> controller.Controller {
  // Creating a user is expensive, so allow a burst of 3 then one a second
  // per API key. Requests without a key are not counted; put an auth
  // middleware in front if every caller must have one.
  let writes = rate_limit.token_bucket(capacity: 3, refill_per_second: 1)

  controller.new("user")
  // Runs for every route in this controller.
  |> controller.middleware(powered_by.header)
  |> controller.get("/all", all)
  |> controller.get("/:id", by_id)
  |> controller.post(
    "/",
    create |> middleware.wrap(rate_limit.by_header(writes, "x-api-key")),
  )
  // Runs for this route only.
  |> controller.delete("/:id", delete |> middleware.wrap(api_key.require))
}

fn all(ctx: Context) {
  user_service.all()
  |> service.respond(ctx, json.array(_, user.to_json))
}

fn by_id(ctx: Context) {
  use id <- param.int(ctx, "id")
  case user_service.find(id) {
    Error(error) -> service.error_response(ctx, error)
    Ok(found) -> {
      // The etag changes whenever the JSON would. A client that sends it
      // back in `if-none-match` gets an empty 304 while it still matches.
      use <- conditional.when(
        ctx,
        conditional.etag([
          int.to_string(found.id),
          found.name,
          found.email,
          int.to_string(found.age),
        ]),
      )
      controller.json(ctx, user.to_json(found))
    }
  }
}

fn create(ctx: Context) {
  use input <- body.validated(ctx, user.input_decoder(), user.validate)
  user_service.create(input)
  |> service.created(ctx, user.to_json)
}

fn delete(ctx: Context) {
  use id <- param.int(ctx, "id")
  user_service.delete(id)
  |> service.no_content(ctx)
}
