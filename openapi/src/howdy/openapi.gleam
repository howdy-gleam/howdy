//// OpenAPI 3.1 documents for Howdy apps.
////
//// Routes added with `howdy/openapi/endpoint` are documented from the
//// schemas they read and the docs they declare. Ordinary controller routes
//// are left out, so an app chooses what it publishes.
////
//// ```gleam
//// import howdy/openapi
////
//// let spec =
////   openapi.new(title: "Users API", version: "1.0.0")
////   |> openapi.bearer_auth("bearer")
////
//// howdy.new()
//// |> howdy.controller(user.controller())
//// |> openapi.serve(spec, at: "/openapi.json")
//// |> openapi.reference(at: "/docs", document: "/openapi.json")
//// |> howdy.start
//// ```
////
//// `serve` documents the controllers mounted before it, so call it after
//// them. An app with a `howdy/version` group gets a document per version;
//// see `version_document`.

import gleam/http/response
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import howdy
import howdy/content
import howdy/controller
import howdy/openapi/endpoint
import howdy/openapi/internal/annotation
import howdy/openapi/schema
import howdy/version

/// The document's own details: title, version, servers and security
/// schemes.
pub opaque type Spec {
  Spec(
    title: String,
    version: String,
    description: Option(String),
    servers: List(String),
    schemes: List(#(String, Json)),
    security: List(String),
  )
}

/// `version` is the version of your API, not of OpenAPI, and is the
/// document's `info.version`. With a `howdy/version` group, each version's
/// document shows it followed by that version's name, as in `1.0.0 (v2)`;
/// see `version_document`.
pub fn new(title title: String, version version: String) -> Spec {
  Spec(
    title:,
    version:,
    description: None,
    servers: [],
    schemes: [],
    security: [],
  )
}

/// A description of the API. OpenAPI allows Markdown here.
pub fn description(spec: Spec, text: String) -> Spec {
  Spec(..spec, description: Some(text))
}

/// A base URL the API is served from, such as `https://api.example.com`.
/// Without one, clients use the URL the document was fetched from.
pub fn server(spec: Spec, url: String) -> Spec {
  Spec(..spec, servers: list.append(spec.servers, [url]))
}

/// Declare a bearer token scheme, `authorization: Bearer <token>`, named
/// `name`. Endpoints require it with `endpoint.security(name)`.
pub fn bearer_auth(spec: Spec, name: String) -> Spec {
  scheme(spec, name, [
    #("type", json.string("http")),
    #("scheme", json.string("bearer")),
  ])
}

/// Declare an API key sent in a request header.
pub fn api_key_header(spec: Spec, name: String, header header: String) -> Spec {
  scheme(spec, name, [
    #("type", json.string("apiKey")),
    #("in", json.string("header")),
    #("name", json.string(header)),
  ])
}

/// Declare an API key sent in a cookie, such as a session cookie.
pub fn api_key_cookie(spec: Spec, name: String, cookie cookie: String) -> Spec {
  scheme(spec, name, [
    #("type", json.string("apiKey")),
    #("in", json.string("cookie")),
    #("name", json.string(cookie)),
  ])
}

fn scheme(spec: Spec, name: String, fields: List(#(String, Json))) -> Spec {
  Spec(
    ..spec,
    schemes: list.append(spec.schemes, [#(name, json.object(fields))]),
  )
}

/// Require a declared scheme for every endpoint that does not name its own
/// with `endpoint.security`.
pub fn require(spec: Spec, scheme: String) -> Spec {
  Spec(..spec, security: list.append(spec.security, [scheme]))
}

/// The document for the endpoints of the controllers mounted on `app` so
/// far. With a `howdy/version` group, it is the document of the default
/// version, or of the newest without a default; see `version_document`.
/// Panics if an endpoint reads a path parameter its route does not capture,
/// two different schemas share a name, or two endpoints share an operation
/// id.
pub fn document(spec: Spec, app: howdy.App) -> Json {
  case howdy.version_group(app) {
    Some(group) -> {
      let assert Ok(document) = version_document(spec, app, main_version(group))
      document
    }
    None ->
      build(spec, None, mounted(howdy.routes(app), endpoint.unversioned()))
  }
}

/// The versions `app` has documents for, in declaration order. Empty
/// without a version group.
pub fn versions(app: howdy.App) -> List(String) {
  case howdy.version_group(app) {
    Some(group) -> version.names(group)
    None -> []
  }
}

/// The document for one version of the API: the app's unversioned
/// endpoints, which answer whatever the version, and the version's own,
/// including those it falls back to. The document's `info.version` is the
/// spec's version followed by the version's name in parentheses, as in
/// `1.0.0 (v2)`, so both are seen.
///
/// How a client asks for the version is documented the way OpenAPI expects:
///
/// - `version.path()`: paths start with the version, as in `/v2/users`.
/// - `version.header(name)`: each operation takes the header, required
///   unless this is the default version.
/// - `version.accept(vendor)`: JSON responses have the vendor media type,
///   such as `application/vnd.howdy.v2+json`, so clients send it in
///   `accept`.
/// - `version.custom(fn)`: nothing can be said; describe it yourself.
///
/// `Error` if the app has no such version.
pub fn version_document(
  spec: Spec,
  app: howdy.App,
  name: String,
) -> Result(Json, Nil) {
  use group <- result.try(option.to_result(howdy.version_group(app), Nil))
  use controllers <- result.map(version.controllers(group, name))
  let versioned =
    list.flat_map(controllers, controller.routes)
    |> mounted(mount(group, name))
  // Unversioned controllers are matched first, as the router does.
  let routes =
    list.append(mounted(howdy.routes(app), endpoint.unversioned()), versioned)
  build(spec, Some(name), routes)
}

fn mounted(
  routes: List(controller.Route),
  mount: endpoint.Mount,
) -> List(#(controller.Route, endpoint.Mount)) {
  list.map(routes, fn(route) { #(route, mount) })
}

fn mount(group: version.Group, name: String) -> endpoint.Mount {
  let json = "application/json"
  case version.strategy(group) {
    version.PathStrategy ->
      endpoint.Mount(prefix: [name], header: None, media_type: json)
    version.HeaderStrategy(header) -> {
      let required = version.default_version(group) != Some(name)
      endpoint.Mount(
        prefix: [],
        header: Some(#(header, name, required)),
        media_type: json,
      )
    }
    version.AcceptStrategy(vendor) ->
      endpoint.Mount(
        prefix: [],
        header: None,
        media_type: "application/" <> vendor <> "." <> name <> "+json",
      )
    version.CustomStrategy ->
      endpoint.Mount(prefix: [], header: None, media_type: json)
  }
}

/// The version `document` describes: the default, or else the newest.
fn main_version(group: version.Group) -> String {
  case version.default_version(group), list.last(version.names(group)) {
    Some(name), _ -> name
    None, Ok(name) -> name
    None, Error(Nil) ->
      panic as "howdy/openapi: the app's version group has no versions"
  }
}

fn build(
  spec: Spec,
  version: Option(String),
  routes: List(#(controller.Route, endpoint.Mount)),
) -> Json {
  let api_version = case version {
    Some(name) -> spec.version <> " (" <> name <> ")"
    None -> spec.version
  }
  let #(paths, components, _) =
    list.fold(routes, #([], schema.components(), []), fn(acc, entry) {
      let #(route, mount) = entry
      let #(paths, components, ids) = acc
      case endpoint.render(route, mount, components) {
        Ok(rendered) -> {
          let paths =
            add_operation(
              paths,
              rendered.path,
              rendered.method,
              rendered.operation,
            )
          let place = string.uppercase(rendered.method) <> " " <> rendered.path
          let ids = case list.key_find(ids, rendered.operation_id) {
            Ok(other) if other != place ->
              panic as {
                "howdy/openapi: "
                <> other
                <> " and "
                <> place
                <> " both have the operation id "
                <> rendered.operation_id
                <> "; give one its own with endpoint.operation_id"
              }
            _ -> [#(rendered.operation_id, place), ..ids]
          }
          #(paths, rendered.components, ids)
        }
        Error(Nil) -> acc
      }
    })

  let paths =
    list.reverse(paths)
    |> list.map(fn(entry) {
      let #(path, operations) = entry
      #(path, json.object(list.reverse(operations)))
    })
  let schemas = schema.component_list(components)
  let components =
    list.flatten([
      case schemas {
        [] -> []
        _ -> [#("schemas", json.object(schemas))]
      },
      case spec.schemes {
        [] -> []
        schemes -> [#("securitySchemes", json.object(schemes))]
      },
    ])

  json.object(
    list.flatten([
      [
        #("openapi", json.string("3.1.0")),
        #(
          "info",
          json.object([
            #("title", json.string(spec.title)),
            #("version", json.string(api_version)),
            ..case spec.description {
              Some(text) -> [#("description", json.string(text))]
              None -> []
            }
          ]),
        ),
      ],
      case spec.servers {
        [] -> []
        servers -> [
          #(
            "servers",
            json.array(servers, fn(url) {
              json.object([#("url", json.string(url))])
            }),
          ),
        ]
      },
      case spec.security {
        [] -> []
        names -> [
          #(
            "security",
            json.array(names, fn(name) {
              json.object([#(name, json.array([], json.string))])
            }),
          ),
        ]
      },
      [#("paths", json.object(paths))],
      case components {
        [] -> []
        _ -> [#("components", json.object(components))]
      },
    ]),
  )
}

/// Paths in first-seen order, each with its operations. The router answers
/// with the first route that matches, so a later duplicate is left out.
fn add_operation(
  paths: List(#(String, List(#(String, Json)))),
  path: String,
  method: String,
  operation: Json,
) -> List(#(String, List(#(String, Json)))) {
  case list.key_find(paths, path) {
    Ok(operations) ->
      case list.key_find(operations, method) {
        Ok(_) -> paths
        Error(Nil) ->
          list.key_set(paths, path, [#(method, operation), ..operations])
      }
    Error(Nil) -> [#(path, [#(method, operation)]), ..paths]
  }
}

/// Serve the document as JSON at `path`. With a version group, `path`
/// serves the `document`, and each version's is served beside it:
/// `/openapi.json` gives `/openapi/v1.json`, `/openapi/v2.json` and so on.
/// The documents are built once, here, from the controllers already
/// mounted.
pub fn serve(app: howdy.App, spec: Spec, at path: String) -> howdy.App {
  let versions =
    list.map(versions(app), fn(name) {
      let assert Ok(document) = version_document(spec, app, name)
      Served(
        path: version_path(path, name),
        version: Some(name),
        main: False,
        document: json.to_string(document),
      )
    })
  // The main document is one of the versions' documents, served again at
  // `path`, so it is built once and shared rather than built again.
  let main = case howdy.version_group(app) {
    Some(group) -> {
      let name = main_version(group)
      let assert Ok(served) =
        list.find(versions, fn(served) { served.version == Some(name) })
      Served(..served, path:, main: True)
    }
    None ->
      Served(
        path:,
        version: None,
        main: True,
        document: json.to_string(document(spec, app)),
      )
  }
  list.fold([main, ..versions], app, fn(app, served) {
    howdy.controller(app, json_controller(served))
  })
}

/// A document `serve` serves. Tools such as `howdy_admin` find them with
/// `served`.
pub type Served {
  Served(
    /// Where the document is served.
    path: String,
    /// The version it describes, if the app has a version group.
    version: Option(String),
    /// Whether it is the document at the path given to `serve`, rather than
    /// one of the per-version documents beside it.
    main: Bool,
    /// The document, as JSON text.
    document: String,
  )
}

const served_key = "howdy_openapi_document"

fn json_controller(served: Served) -> controller.Controller {
  let body = served.document
  controller.new(served.path)
  |> controller.get("/", fn(_ctx) {
    response.new(200)
    |> response.set_header("content-type", "application/json; charset=utf-8")
    |> response.set_body(content.Text(body))
  })
  |> controller.annotate(served_key, annotation.wrap(served_key, served))
}

/// The documents `serve` added to `app`, in the order they were added.
pub fn served(app: howdy.App) -> List(Served) {
  list.filter_map(howdy.routes(app), fn(route) {
    controller.annotation(route, served_key)
    |> result.map(annotation.unwrap(_, served_key))
  })
}

/// Where `serve` puts a version's document, next to the main one at `path`.
fn version_path(path: String, name: String) -> String {
  case string.ends_with(path, ".json") {
    True -> string.drop_end(path, 5) <> "/" <> name <> ".json"
    False -> path <> "/" <> name
  }
}

/// Serve an interactive API reference at `path`, for the document `serve`
/// serves at the URL `document`. With a version group, the page offers every
/// version's document, opening on the one `document` describes. The page
/// loads Scalar's API reference from the jsDelivr CDN, so browsers viewing
/// it need to reach `cdn.jsdelivr.net`.
pub fn reference(
  app: howdy.App,
  at path: String,
  document url: String,
) -> howdy.App {
  let config = case howdy.version_group(app) {
    Some(group) -> {
      let main = main_version(group)
      json.object([
        #(
          "sources",
          json.array(version.names(group), fn(name) {
            json.object([
              #("title", json.string(name)),
              #("slug", json.string(name)),
              #("url", json.string(version_path(url, name))),
              #("default", json.bool(name == main)),
            ])
          }),
        ),
      ])
    }
    None -> json.object([#("url", json.string(url))])
  }
  let config =
    json.to_string(config)
    |> string.replace("</", "<\\/")
  let page = "<!doctype html>
<html>
  <head>
    <meta charset=\"utf-8\">
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
    <title>API reference</title>
  </head>
  <body>
    <div id=\"app\"></div>
    <script src=\"https://cdn.jsdelivr.net/npm/@scalar/api-reference\"></script>
    <script>Scalar.createApiReference('#app', " <> config <> ")</script>
  </body>
</html>
"
  howdy.controller(
    app,
    controller.new(path)
      |> controller.get("/", fn(ctx) { controller.html(ctx, page) }),
  )
}
