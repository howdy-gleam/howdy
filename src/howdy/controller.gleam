//// Controllers group HTTP routes under a common path prefix.
////
//// ```gleam
//// import howdy/controller.{type Context}
////
//// pub fn user_controller() {
////   controller.new("user")
////   |> controller.get("/all", fn(ctx: Context) { controller.text(ctx, "all") })
////   |> controller.get("/:id", fn(ctx: Context) { ... })
////   |> controller.post("/", fn(ctx: Context) { ... })
//// }
//// ```

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/http.{type Method}
import gleam/http/response.{type Response}
import gleam/json.{type Json}
import gleam/list
import gleam/string
import howdy/content.{type Content}
import howdy/context
import howdy/service

/// Everything a handler needs to answer a request.
pub type Context =
  context.Context(Nil)

/// A context carrying the successful result of a controller guard.
pub type GuardedContext(guarded) =
  context.Context(guarded)

/// A function that answers a request.
pub type Handler =
  fn(Context) -> Response(Content)

/// The rest of the chain a middleware hands the request on to.
pub type Next =
  fn(Context) -> Response(Content)

/// A function that runs around a handler. See `howdy/middleware`.
pub type Middleware =
  fn(Context, Next) -> Response(Content)

/// A single route: method, path pattern (already prefixed) and handler.
/// `annotations` hold values other packages attach with `annotate`, keyed by
/// the package that owns them; the router ignores them.
pub type Route {
  Route(
    method: Method,
    segments: List(String),
    handler: Handler,
    annotations: List(#(String, Dynamic)),
  )
}

/// A named group of routes.
pub type Controller =
  Builder(Nil)

/// A controller under construction, with a typed guard result.
/// Call `build` before mounting a guarded builder.
pub opaque type Builder(guarded) {
  Controller(
    prefix: List(String),
    routes: List(Route),
    middleware: List(Middleware),
    check: fn(Context) -> service.Result(guarded),
  )
}

/// Create a controller. Every route added to it is mounted under `prefix`.
/// Leading and trailing slashes are ignored, so `"user"`, `"/user"` and
/// `"/user/"` are equivalent. `"api/user"` mounts under two segments.
pub fn new(prefix: String) -> Controller {
  Controller(prefix: segments(prefix), routes: [], middleware: [], check: fn(_) {
    Ok(Nil)
  })
}

/// Create a controller whose guard runs before every matched handler.
/// An error returns the standard service error response and stops execution.
/// The successful value is available to every route as `ctx.guard`.
pub fn guarded(
  prefix: String,
  check: fn(Context) -> service.Result(guarded),
) -> Builder(guarded) {
  Controller(prefix: segments(prefix), routes: [], middleware: [], check:)
}

/// Finish a builder so controllers with different guard types can be mounted
/// together. Each route already captures its guard; no guard runs at build time.
pub fn build(controller: Builder(guarded)) -> Controller {
  let check = controller.check
  Controller(
    prefix: controller.prefix,
    routes: controller.routes,
    middleware: controller.middleware,
    check: fn(ctx) {
      case check(ctx) {
        Ok(_) -> Ok(Nil)
        Error(error) -> Error(error)
      }
    },
  )
}

/// The routes of a controller, in the order they were declared. Each
/// handler is already wrapped in the controller's middleware.
pub fn routes(controller: Controller) -> List(Route) {
  let middleware = list.reverse(controller.middleware)
  controller.routes
  |> list.reverse
  |> list.map(fn(route) {
    Route(..route, handler: wrap_all(route.handler, middleware))
  })
}

/// Add middleware that runs for every route in the controller, no matter
/// where in the pipeline it is added. The first added is the outermost.
pub fn middleware(
  controller: Builder(guarded),
  middleware: Middleware,
) -> Builder(guarded) {
  Controller(..controller, middleware: [middleware, ..controller.middleware])
}

/// The handler the router uses for `OPTIONS` requests to a path that has
/// routes but no explicit `OPTIONS` route. It answers `204` with an `allow`
/// header and runs inside the controller's middleware, so CORS middleware
/// sees preflight requests. The controller guard does not run: browsers send
/// preflights without credentials, so a guard could only reject them.
@internal
pub fn options_handler(
  controller: Controller,
  allowed: List(Method),
) -> Handler {
  let allow =
    list.append(allowed, [http.Options])
    |> list.unique
    |> list.map(http.method_to_string)
    |> string.join(", ")
  let handler = fn(_ctx) {
    response.new(204)
    |> response.set_header("allow", allow)
    |> response.set_body(content.Empty)
  }
  wrap_all(handler, list.reverse(controller.middleware))
}

/// Wrap a handler in one middleware.
pub fn wrap(handler: Handler, middleware: Middleware) -> Handler {
  fn(ctx) { middleware(ctx, handler) }
}

/// Wrap a handler in several middleware. The first in the list is the
/// outermost.
pub fn wrap_all(handler: Handler, middleware: List(Middleware)) -> Handler {
  list.fold_right(middleware, handler, wrap)
}

/// Add a route for any method. A path segment starting with `:` captures
/// one segment as a parameter. A final segment starting with `*` captures
/// the rest of the path, joined with `/`, and matches even when nothing
/// remains: `"/files/*path"` matches `/files`, `/files/a` and `/files/a/b`.
pub fn route(
  controller: Builder(guarded),
  method: Method,
  path: String,
  handler: fn(GuardedContext(guarded)) -> Response(Content),
) -> Builder(guarded) {
  let check = controller.check
  let route =
    Route(
      method:,
      segments: list.append(controller.prefix, segments(path)),
      annotations: [],
      handler: fn(ctx) {
        case check(ctx) {
          Ok(value) ->
            handler(context.Context(
              request: ctx.request,
              params: ctx.params,
              guard: value,
              version: ctx.version,
            ))
          Error(error) -> service.error_response(ctx, error)
        }
      },
    )
  Controller(..controller, routes: [route, ..controller.routes])
}

/// Attach `value` under `key` to the route added most recently. This is for
/// packages that describe routes, such as `howdy_openapi`, not for handlers:
/// the router never reads annotations. Use a key naming your package, and
/// read it back with `annotation`. A later value for the same key replaces
/// the earlier one. Panics if the controller has no routes yet.
pub fn annotate(
  controller: Builder(guarded),
  key: String,
  value: Dynamic,
) -> Builder(guarded) {
  case controller.routes {
    [route, ..rest] -> {
      let annotations = [
        #(key, value),
        ..list.filter(route.annotations, fn(entry) { entry.0 != key })
      ]
      Controller(..controller, routes: [Route(..route, annotations:), ..rest])
    }
    [] -> panic as "howdy/controller: annotate needs a route to annotate"
  }
}

/// The value attached to a route under `key` with `annotate`.
pub fn annotation(route: Route, key: String) -> Result(Dynamic, Nil) {
  list.key_find(route.annotations, key)
}

pub fn get(
  controller: Builder(guarded),
  path: String,
  handler: fn(GuardedContext(guarded)) -> Response(Content),
) -> Builder(guarded) {
  route(controller, http.Get, path, handler)
}

pub fn post(
  controller: Builder(guarded),
  path: String,
  handler: fn(GuardedContext(guarded)) -> Response(Content),
) -> Builder(guarded) {
  route(controller, http.Post, path, handler)
}

pub fn put(
  controller: Builder(guarded),
  path: String,
  handler: fn(GuardedContext(guarded)) -> Response(Content),
) -> Builder(guarded) {
  route(controller, http.Put, path, handler)
}

pub fn patch(
  controller: Builder(guarded),
  path: String,
  handler: fn(GuardedContext(guarded)) -> Response(Content),
) -> Builder(guarded) {
  route(controller, http.Patch, path, handler)
}

pub fn delete(
  controller: Builder(guarded),
  path: String,
  handler: fn(GuardedContext(guarded)) -> Response(Content),
) -> Builder(guarded) {
  route(controller, http.Delete, path, handler)
}

/// Split a path into non-empty segments. `"/user//all/"` -> `["user", "all"]`.
pub fn segments(path: String) -> List(String) {
  path
  |> string.split("/")
  |> list.filter(fn(segment) { segment != "" })
}

// -- Context helpers ---------------------------------------------------------

/// Look up a path parameter captured by a `:name` or `*name` segment.
pub fn param(
  ctx: GuardedContext(guarded),
  name: String,
) -> Result(String, Nil) {
  dict.get(ctx.params, name)
}

/// Read the whole request body, up to `limit` bytes.
pub fn read_body(
  ctx: GuardedContext(guarded),
  limit limit: Int,
) -> Result(BitArray, context.BodyError) {
  context.read_body(ctx.request, limit:)
}

/// Read the request body a piece at a time with `context.read_chunk`, for a
/// body too large to hold in memory, such as a file written to disk as it
/// arrives. A body over `limit` bytes is refused.
pub fn body_reader(
  ctx: GuardedContext(guarded),
  limit limit: Int,
) -> context.Reader {
  context.reader(ctx.request, limit:)
}

// -- Response helpers --------------------------------------------------------

/// A `200` response with a UTF-8 text body.
pub fn text(_ctx: GuardedContext(guarded), body: String) -> Response(Content) {
  response.new(200)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(content.Text(body))
}

/// A `200` response with an HTML body.
pub fn html(_ctx: GuardedContext(guarded), body: String) -> Response(Content) {
  response.new(200)
  |> response.set_header("content-type", "text/html; charset=utf-8")
  |> response.set_body(content.Text(body))
}

/// A `200` response with a JSON body.
pub fn json(_ctx: GuardedContext(guarded), body: Json) -> Response(Content) {
  response.new(200)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_body(content.Text(json.to_string(body)))
}

/// A response with the given status and no body.
pub fn status(_ctx: GuardedContext(guarded), code: Int) -> Response(Content) {
  response.new(code)
  |> response.set_body(content.Empty)
}

/// Change the status of a response built with one of the helpers above.
pub fn with_status(
  response: Response(Content),
  code: Int,
) -> Response(Content) {
  response.Response(..response, status: code)
}
