//// howdy is an opinionated web framework on top of ewe.
////
//// ```gleam
//// let assert Ok(_) =
////   howdy.new()
////   |> howdy.controller(user_controller())
////   |> howdy.start
//// ```

import ewe
import gleam/dict
import gleam/erlang/process.{type Pid}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import howdy/content.{type Content}
import howdy/context.{type Body, Context}
import howdy/controller.{
  type Controller, type Handler, type Middleware, type Route,
}
import howdy/router
import howdy/service
import howdy/trace
import howdy/version.{type Group}

/// The howdy framework version. Keep in sync with `gleam.toml`.
pub const version = "2.1.1"

pub opaque type App {
  App(
    controllers: List(Controller),
    middleware: List(Middleware),
    versions: Option(Group),
    not_found: Option(Handler),
    bind_address: String,
    port: Int,
    tls: Option(Tls),
    quiet_disconnects: Bool,
    shutdown_timeout: Int,
  )
}

type Tls {
  CertificateFiles(cert: String, key: String)
  CertificatePem(cert: BitArray, key: BitArray)
}

/// Where a started server is listening. `port` is the one the operating
/// system chose when the app listens on port `0`.
pub type Address {
  Address(ip: String, port: Int)
}

pub fn new() -> App {
  App(
    controllers: [],
    middleware: [],
    versions: None,
    not_found: None,
    bind_address: "0.0.0.0",
    port: 8787,
    tls: None,
    quiet_disconnects: True,
    shutdown_timeout: 15_000,
  )
}

/// Set the network interface to listen on. Defaults to `"0.0.0.0"`
/// (all IPv4 interfaces). Use `"127.0.0.1"` for local access only.
/// An invalid address panics when the server starts, as in ewe.
pub fn bind(app: App, to address: String) -> App {
  App(..app, bind_address: address)
}

/// Set the listening port. Defaults to `8787`. Use `0` to let the operating
/// system choose an available port. The last call wins.
pub fn listening(app: App, on port: Int) -> App {
  App(..app, port:)
}

/// Serve HTTPS using PEM-encoded certificate and key files. Browsers only
/// speak HTTP/2 over TLS, so this is also what enables HTTP/2 for them; it is
/// offered through ALPN alongside HTTP/1.1. For in-memory certificates use
/// `tls_pem`. Without TLS, HTTP/2 is still served to clients that open
/// with the HTTP/2 preface, such as `curl --http2-prior-knowledge`.
pub fn tls(app: App, cert cert: String, key key: String) -> App {
  App(..app, tls: Some(CertificateFiles(cert:, key:)))
}

/// Serve HTTPS using a PEM-encoded certificate and key held in memory, such
/// as ones read from a secret store. Otherwise the same as `tls`.
pub fn tls_pem(app: App, cert cert: BitArray, key key: BitArray) -> App {
  App(..app, tls: Some(CertificatePem(cert:, key:)))
}

/// Report clients that went away mid write as crashed connections after all.
///
/// By default `start` installs a node-wide logger filter that drops the
/// supervisor and crash reports the server's connection pool emits when a
/// client hangs up while being written to, such as a browser tab closed mid
/// WebSocket close handshake. The filter only drops exits raised by the
/// server's own socket layer with one of its peer-gone reasons; everything
/// else is reported. Call this to keep those reports, for instance while
/// debugging a flaky network.
pub fn log_disconnects(app: App) -> App {
  App(..app, quiet_disconnects: False)
}

/// Set how long each open connection gets to finish when the server is
/// stopped, in milliseconds. 15 seconds by default.
///
/// HTTP/1 connections finish the request they are serving, WebSockets are
/// sent a going-away close frame and HTTP/2 connections send GOAWAY and wait
/// for their open streams. A connection still open once the time is up is
/// closed. This applies to `stop` and to a shutdown of the supervision tree
/// the server runs in; see `supervised`.
pub fn shutdown_timeout(app: App, milliseconds: Int) -> App {
  App(..app, shutdown_timeout: milliseconds)
}

/// Start the app's HTTP server.
/// Defaults to `0.0.0.0:8787`; override with `bind` and `listening`.
/// Prints a howdy banner with the framework version and bound URL once listening.
///
/// Returns the server's process and the `Address` it is listening on. The
/// server is linked to the calling process: if that process exits, so does
/// the server, and if the server exits abnormally, so does the caller. That
/// is fine for a script that calls `process.sleep_forever()` afterwards, but
/// an app that also runs a database pool, a mail outbox or feature flags
/// should put them all under a supervisor with `supervised` instead, so a
/// crash in one is restarted rather than ending the program.
///
/// Stop the server with `stop`, which lets open connections finish.
///
/// Clients that disconnect while the server is still writing to them, such
/// as a browser tab closed mid WebSocket, are not logged as crashes; see
/// `log_disconnects` to change that.
pub fn start(app: App) -> Result(actor.Started(Address), actor.StartError) {
  start_with(app, serve(app))
}

/// A child specification for the app's HTTP server, to add to a supervision
/// tree with `static_supervisor.add`. The child's data is the `Address` the
/// server listens on, and the supervisor restarts the server if it exits.
///
/// ```gleam
/// import gleam/otp/static_supervisor as supervisor
///
/// let assert Ok(_) =
///   supervisor.new(supervisor.OneForOne)
///   |> supervisor.add(howdy.supervised(app))
///   |> supervisor.start
/// ```
///
/// Connections are drained for `shutdown_timeout` when the supervisor stops
/// the server, which happens when the tree is stopped explicitly or, for a
/// tree started by an OTP application, when the node shuts down. A tree
/// started from `main` and left running with `process.sleep_forever()` is
/// killed with the VM instead, so an app that wants a clean stop on SIGTERM
/// should start its tree from an application module; see the supervision
/// guide.
pub fn supervised(app: App) -> supervision.ChildSpecification(Address) {
  supervision.supervisor(fn() { start(app) })
}

/// Start a supervision tree as an OTP application called `name`, and return
/// the pid of its root supervisor.
///
/// This is how a howdy app should run in production. The tree holds the
/// server from `supervised` alongside anything else the app keeps running,
/// such as a database pool, feature flags or a mail outbox, each restarted
/// on its own if it crashes. Because the tree belongs to an application, the
/// node's own shutdown stops it in order: on `SIGTERM`, or `init:stop()`,
/// the server stops listening and gives open connections `shutdown_timeout`
/// to finish before the VM halts. A tree started from `main` without this is
/// simply killed with the VM.
///
/// `name` must not be the name of a package the app already loads, so pick
/// one like `"my_app_server"`. Keep the calling process alive afterwards,
/// with `process.sleep_forever()` from `main`.
///
/// ```gleam
/// import gleam/otp/static_supervisor as supervisor
///
/// pub fn main() -> Nil {
///   let assert Ok(_) =
///     supervisor.new(supervisor.OneForOne)
///     |> supervisor.add(howdy.supervised(app()))
///     |> howdy.start_application(name: "my_app_server")
///   process.sleep_forever()
/// }
/// ```
///
/// Stop it again with `stop_application`.
pub fn start_application(
  tree: static_supervisor.Builder,
  name name: String,
) -> Result(Pid, String) {
  load_and_start(name, fn() { static_supervisor.start(tree) })
}

/// Stop an application started with `start_application` and wait for its
/// tree to finish, draining the server's connections on the way.
pub fn stop_application(name: String) -> Nil {
  stop_application_now(name)
}

@external(erlang, "howdy_application", "load_and_start")
fn load_and_start(
  name: String,
  start: fn() ->
    Result(actor.Started(static_supervisor.Supervisor), actor.StartError),
) -> Result(Pid, String)

@external(erlang, "howdy_application", "stop_application")
fn stop_application_now(name: String) -> Nil

/// Stop a server started with `start` and wait for it to finish.
///
/// The listener closes first so no new connections arrive, then each open
/// connection gets `shutdown_timeout` to finish: HTTP/1 requests complete,
/// WebSockets are sent a going-away close frame and HTTP/2 streams are told
/// GOAWAY. Returns once every connection is gone and the port is free. The
/// calling process is unlinked from the server first, so it is not taken
/// down by the stop. A server still running a minute after the default
/// drain timeout is killed rather than waited on forever.
pub fn stop(server: Pid) -> Nil {
  stop_server(server, 15_000)
}

/// Like `stop`, for a server whose `shutdown_timeout` is not the default:
/// the wait for a wedged server is measured from it.
pub fn stop_within(server: Pid, shutdown_timeout milliseconds: Int) -> Nil {
  stop_server(server, milliseconds)
}

@external(erlang, "howdy_ffi", "stop_server")
fn stop_server(server: Pid, drain_ms: Int) -> Nil

/// Start a server for `app` that answers requests with `handler` instead of
/// the app's own. The address, port and banner come from `app`. This is
/// what development tooling such as `howdy_dev` uses to wrap an app.
pub fn start_with(
  app: App,
  handler: fn(Request(Body)) -> Response(Content),
) -> Result(actor.Started(Address), actor.StartError) {
  case app.quiet_disconnects {
    True -> quiet_disconnects()
    False -> log_disconnects_now()
  }
  let key = share_handler(to_ewe(handler))
  ewe.new(handler: call_shared(key, _))
  |> ewe.bind(to: app.bind_address)
  |> ewe.listening(on: app.port)
  |> ewe.shutdown_timeout(app.shutdown_timeout)
  |> with_tls(app.tls)
  |> ewe.on_start(fn(scheme, address) {
    startup_banner(scheme, to_address(address))
  })
  |> ewe.start
  |> result.map(fn(started) {
    forget_when_down(key, started.pid)
    actor.Started(..started, data: to_address(started.data))
  })
  |> result.map_error(fn(error) {
    forget_handler(key)
    error
  })
}

/// Where a server's handler is kept, for every process to read in place
/// rather than each holding a copy of every route (`howdy_ffi.erl`).
type HandlerKey

@external(erlang, "howdy_ffi", "share_handler")
fn share_handler(
  handler: fn(Request(ewe.Connection)) -> Response(ewe.Body),
) -> HandlerKey

@external(erlang, "howdy_ffi", "call_shared")
fn call_shared(
  key: HandlerKey,
  request: Request(ewe.Connection),
) -> Response(ewe.Body)

@external(erlang, "howdy_ffi", "forget_when_down")
fn forget_when_down(key: HandlerKey, server: Pid) -> Nil

@external(erlang, "howdy_ffi", "forget_handler")
fn forget_handler(key: HandlerKey) -> Nil

/// Stop OTP reporting a client that went away mid write as a crashed
/// connection. Installed once per node; other reports are untouched.
@external(erlang, "howdy_ffi", "quiet_disconnects")
fn quiet_disconnects() -> Nil

@external(erlang, "howdy_ffi", "log_disconnects")
fn log_disconnects_now() -> Nil

fn with_tls(builder: ewe.Builder, tls: Option(Tls)) -> ewe.Builder {
  case tls {
    Some(CertificateFiles(cert:, key:)) ->
      ewe.with_tls(builder, ewe.Disk(cert:, key:))
    Some(CertificatePem(cert:, key:)) ->
      ewe.with_tls(builder, ewe.Pem(cert:, key:))
    None -> builder
  }
}

fn to_address(address: ewe.SocketAddress) -> Address {
  case address {
    ewe.TcpSocketAddress(ip_address:, port:) ->
      Address(ip: ewe.ip_address_to_string(ip_address), port:)
    // `bind` only takes network interfaces, so this is only reachable
    // through `handler` with ewe's own builder; report the path as the ip.
    ewe.UnixSocketAddress(path:) -> Address(ip: path, port: 0)
  }
}

fn startup_banner(scheme: http.Scheme, address: Address) -> Nil {
  let host = case string.contains(address.ip, ":") {
    True -> "[" <> address.ip <> "]"
    False -> address.ip
  }
  let url =
    http.scheme_to_string(scheme)
    <> "://"
    <> host
    <> ":"
    <> int.to_string(address.port)

  io.println("
 _   _                  _
| | | | _____      ____| |_   _
| |_| |/ _ \\ \\ /\\ / / _` | | | |
|  _  | (_) \\ V  V / (_| | |_| |
|_| |_|\\___/ \\_/\\_/ \\__,_|\\__, |
                          |___/

  howdy v" <> version <> "
  Listening on " <> url <> "
")
}

/// Add middleware that runs for every request the app handles, outside any
/// controller or route middleware. The first added is the outermost.
pub fn middleware(app: App, middleware: Middleware) -> App {
  App(..app, middleware: [middleware, ..app.middleware])
}

/// Mount a controller. Controllers are matched in the order they are added.
pub fn controller(app: App, controller: Controller) -> App {
  App(..app, controllers: list.append(app.controllers, [controller]))
}

/// The routes of every controller mounted so far, in matching order, each
/// wrapped in its controller's middleware but not the app's. Routes in a
/// version group are not included. For packages that describe an app's
/// routes, such as `howdy_openapi`; call it once every controller is mounted.
pub fn routes(app: App) -> List(Route) {
  list.flat_map(app.controllers, controller.routes)
}

/// The version group mounted with `versions`, if any. For packages that
/// describe an app's routes, such as `howdy_openapi`.
pub fn version_group(app: App) -> Option(Group) {
  app.versions
}

/// Mount a version group from `howdy/version`. Unversioned controllers are
/// matched first; the group answers whatever they do not. An app has at
/// most one group, so mounting a second panics.
pub fn versions(app: App, group: Group) -> App {
  case app.versions {
    None -> App(..app, versions: Some(group))
    Some(_) -> panic as "howdy: an app can only have one version group"
  }
}

/// Answer requests that no route matches with `handler`, wrapped in the
/// app's middleware like any route, so logging, CORS and the like see them
/// too. It gets the request with no path parameters, and with a version
/// group, the version the request asked for if it named one.
///
/// Without it such a request gets an empty 404 that no middleware sees. A
/// path some route matches with another method still gets its 405, and a
/// catch-all route such as `static.serve("/", ...)` matches first, so its
/// own 404s are the controller's and pass through middleware as usual.
///
/// ```gleam
/// howdy.new()
/// |> howdy.controller(pages())
/// |> howdy.not_found(fn(ctx) {
///   service.error_response(ctx, service.NotFound("no such page"))
/// })
/// ```
pub fn not_found(app: App, handler: Handler) -> App {
  App(..app, not_found: Some(handler))
}

/// Compile routes and middleware into a reusable ewe request handler, for
/// running the app under ewe directly with options `start` does not offer.
/// Pass the result to `ewe.new`; construct it once and reuse it for every
/// request. This is the one part of howdy's API that uses ewe's types.
///
/// The routes are kept where every process reads them in place, as `start`
/// keeps them, so ewe's processes do not each hold a copy; they are kept
/// until the node stops, so make one handler per server rather than one per
/// request.
///
/// To exercise an app without a server, see `howdy/testing`.
pub fn handler(app: App) -> fn(Request(ewe.Connection)) -> Response(ewe.Body) {
  let key = share_handler(to_ewe(serve(app)))
  call_shared(key, _)
}

fn to_ewe(
  serve: fn(Request(Body)) -> Response(Content),
) -> fn(Request(ewe.Connection)) -> Response(ewe.Body) {
  fn(request: Request(ewe.Connection)) {
    serve(request.set_body(request, context.live(request.body)))
    |> response.map(content.to_ewe)
  }
}

/// The handler for requests whose body has already been wrapped in a
/// `context.Body`. `handler` and `howdy/testing` both build on this.
@internal
pub fn serve(app: App) -> fn(Request(Body)) -> Response(Content) {
  let middleware = list.reverse(app.middleware)
  let routes = router.compile(app.controllers, middleware)
  let unmatched = option.map(app.not_found, controller.wrap_all(_, middleware))
  let versions =
    option.map(app.versions, fn(group) {
      let table =
        version.table(group)
        |> dict.map_values(fn(_, controllers) {
          router.compile(controllers, middleware)
        })
      #(group, table)
    })
  fn(request: Request(Body)) {
    use <- traced(request)
    case router.match_table(routes, request.method, request.path), versions {
      router.NotFound, Some(#(group, table)) ->
        versioned(group, table, unmatched, request)
      match, _ -> respond(match, request, unmatched, None, "")
    }
  }
}

/// Answer the request inside a server span that continues any trace the
/// client started. The span is named after the method until a route
/// matches, then after the method and route, as OpenTelemetry's HTTP
/// conventions ask; the raw path would give every user id its own name.
/// Query strings, headers and bodies are left out, as they can hold secrets.
fn traced(
  request: Request(Body),
  respond: fn() -> Response(Content),
) -> Response(Content) {
  let method = http.method_to_string(request.method)
  trace.new(method)
  |> trace.kind(trace.Server)
  |> trace.continue_from(request.headers)
  |> trace.attributes(request_attributes(request, method))
  |> trace.run(fn() {
    let response = respond()
    trace.set_attributes([
      trace.int("http.response.status_code", response.status),
    ])
    case response.status >= 500 {
      True -> {
        trace.set_attributes([
          trace.string("error.type", int.to_string(response.status)),
        ])
        trace.set_error("HTTP " <> int.to_string(response.status))
      }
      False -> Nil
    }
    response
  })
}

fn request_attributes(
  request: Request(Body),
  method: String,
) -> List(trace.Attribute) {
  let optional = [
    option.map(request.port, trace.int("server.port", _)),
    option.map(context.client_ip(request), trace.string("client.address", _)),
    request.get_header(request, "user-agent")
      |> option.from_result
      |> option.map(trace.string("user_agent.original", _)),
  ]
  [
    trace.string("http.request.method", method),
    trace.string("url.path", request.path),
    trace.string("url.scheme", http.scheme_to_string(request.scheme)),
    trace.string("server.address", request.host),
    ..option.values(optional)
  ]
}

/// Name the request's span after the route that answers it.
fn traced_route(request: Request(Body), route: String) -> Nil {
  case trace.is_recording() {
    True -> {
      rename_span(http.method_to_string(request.method) <> " " <> route)
      trace.set_attributes([trace.string("http.route", route)])
    }
    False -> Nil
  }
}

@external(erlang, "howdy_trace_ffi", "update_name")
fn rename_span(name: String) -> Nil

fn versioned(
  group: Group,
  table: dict.Dict(String, router.Table),
  unmatched: Option(Handler),
  request: Request(Body),
) -> Response(Content) {
  let response = case version.resolve(group, request) {
    version.Version(name:, path:) -> {
      let assert Ok(routes) = dict.get(table, name)
      // Under the path strategy the version was the first segment; put it
      // back so the traced route reads like the request.
      let prefix = case path == request.path {
        True -> ""
        False -> "/" <> name
      }
      router.match_table(routes, request.method, path)
      |> respond(request, unmatched, Some(name), prefix)
    }
    version.Missing(message) ->
      service.error_response(
        Context(request:, params: dict.new(), guard: Nil, version: None),
        service.Invalid(message),
      )
    version.NotVersioned -> not_found_response(request, unmatched, None)
  }
  case version.vary_header(group) {
    Some(header) -> add_vary(response, header)
    None -> response
  }
}

/// Append to an existing `vary` header, since middleware such as
/// `howdy/cors` may already have set one.
fn add_vary(response: Response(Content), header: String) -> Response(Content) {
  case response.get_header(response, "vary") {
    Ok(existing) ->
      response.set_header(response, "vary", existing <> ", " <> header)
    Error(Nil) -> response.set_header(response, "vary", header)
  }
}

fn respond(
  match: router.Match,
  request: Request(Body),
  unmatched: Option(Handler),
  version: Option(String),
  route_prefix: String,
) -> Response(Content) {
  case match {
    router.Found(handler:, params:, route:) -> {
      traced_route(request, route_prefix <> route)
      handler(Context(request:, params:, guard: Nil, version:))
    }
    router.NotFound -> not_found_response(request, unmatched, version)
    router.MethodNotAllowed(allowed:) ->
      response.new(405)
      |> response.set_header(
        "allow",
        allowed |> list.map(http.method_to_string) |> string.join(", "),
      )
      |> response.set_body(content.Empty)
  }
}

/// The app's `not_found` handler for a request no route matched, or an
/// empty 404 when it has none.
fn not_found_response(
  request: Request(Body),
  unmatched: Option(Handler),
  version: Option(String),
) -> Response(Content) {
  case unmatched {
    Some(handler) ->
      handler(Context(request:, params: dict.new(), guard: Nil, version:))
    None ->
      response.new(404)
      |> response.set_body(content.Empty)
  }
}
