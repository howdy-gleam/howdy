# howdy_openapi

OpenAPI 3.1 documents for Howdy apps, built from schemas that also decode
requests and encode responses, so the document cannot drift from the code.

```sh
gleam add howdy_openapi@1
```

```gleam
import howdy/openapi
import howdy/openapi/endpoint.{type Endpoint}
import howdy/openapi/schema

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

howdy.new()
|> howdy.controller(controller.new("user") |> endpoint.get("/:id", by_id()))
|> openapi.serve(openapi.new(title: "Users", version: "1.0.0"), at: "/openapi.json")
|> openapi.reference(at: "/docs", document: "/openapi.json")
```

- `howdy/openapi/schema`: values described once, as decoder, encoder and
  JSON Schema, with constraints checked while decoding.
- `howdy/openapi/endpoint`: handlers that read their inputs through schemas,
  mounted on ordinary controllers.
- `howdy/openapi`: the document, served as JSON, and a Scalar reference page.
  An app with a `howdy/version` group gets a document per version.

See `docs/openapi/` and `examples/openapi`.
