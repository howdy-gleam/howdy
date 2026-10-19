//// Typed calls from one Howdy service to another, over Erlang distribution
//// or HTTP.
////
//// Define each procedure once, in a module both services can import:
////
//// ```gleam
//// pub fn get_user() -> remote.Procedure(Int, User) {
////   remote.procedure("users.get", input: codec.int(), output: user_codec())
//// }
//// ```
////
//// Serve it from the service that owns the data. A handler returns the same
//// `service.Result` a controller works with:
////
//// ```gleam
//// remote.server()
//// |> remote.handle(users_api.get_user(), user_service.find)
//// |> remote.start
//// ```
////
//// Call it from anywhere:
////
//// ```gleam
//// case remote.call(remote.cluster(), users_api.get_user(), 42, timeout: 5000) {
////   Ok(user) -> ...
////   Error(remote.Failed(service.NotFound(_))) -> ...
////   Error(error) -> ...
//// }
//// ```
////
//// Inputs and outputs are encoded as JSON and decoded at the boundary, even
//// between Erlang nodes. Two services built at different times can disagree
//// on a type; decoding turns that into a `BadResponse` or an `Invalid`
//// error instead of an ill-typed value that crashes somewhere else later.
//// It also means one procedure works over both transports unchanged.
////
//// Erlang distribution gives every connected node full control of every
//// other: a node holding the cookie can run any code on yours, whatever
//// this module allows. Use `cluster` and `node` only between nodes on a
//// private network. Across a trust boundary, serve with `controller` and
//// call with `http`.

import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/process.{type Pid}
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import howdy/body
import howdy/codec as howdy_codec
import howdy/content.{type Content}
import howdy/controller.{type Context, type Controller}
import howdy/service
import howdy/trace
import logging

// -- Procedures ----------------------------------------------------------------

/// How to turn a value into JSON and back. The same type as
/// `howdy/codec.Codec`, which has the constructors.
pub type Codec(a) =
  howdy_codec.Codec(a)

/// The same as `codec.new` in `howdy/codec`, kept so code written before
/// that module existed still compiles.
pub fn codec(
  encode encode: fn(a) -> Json,
  decoder decoder: Decoder(a),
) -> Codec(a) {
  howdy_codec.new(encode:, decoder:)
}

/// The same as `codec.int` in `howdy/codec`, kept so code written before
/// that module existed still compiles.
pub fn int() -> Codec(Int) {
  howdy_codec.int()
}

/// The same as `codec.float` in `howdy/codec`, kept so code written before
/// that module existed still compiles.
pub fn float() -> Codec(Float) {
  howdy_codec.float()
}

/// The same as `codec.string` in `howdy/codec`, kept so code written before
/// that module existed still compiles.
pub fn string() -> Codec(String) {
  howdy_codec.string()
}

/// The same as `codec.bool` in `howdy/codec`, kept so code written before
/// that module existed still compiles.
pub fn bool() -> Codec(Bool) {
  howdy_codec.bool()
}

/// The same as `codec.nil` in `howdy/codec`, kept so code written before
/// that module existed still compiles.
pub fn nil() -> Codec(Nil) {
  howdy_codec.nil()
}

/// The same as `codec.list` in `howdy/codec`, kept so code written before
/// that module existed still compiles.
pub fn list(of item: Codec(a)) -> Codec(List(a)) {
  howdy_codec.list(item)
}

/// The same as `codec.optional` in `howdy/codec`, kept so code written before
/// that module existed still compiles.
pub fn optional(of item: Codec(a)) -> Codec(Option(a)) {
  howdy_codec.optional(item)
}

/// A named function one service offers another, taking an `input` and
/// returning an `output`. The name is all that crosses the wire, so it must
/// be unique among the procedures a server handles. A dotted name such as
/// `"users.get"` keeps services apart.
pub opaque type Procedure(input, output) {
  Procedure(name: String, input: Codec(input), output: Codec(output))
}

pub fn procedure(
  name: String,
  input input: Codec(input),
  output output: Codec(output),
) -> Procedure(input, output) {
  Procedure(name:, input:, output:)
}

pub fn name(procedure: Procedure(input, output)) -> String {
  procedure.name
}

// -- Errors --------------------------------------------------------------------

/// Why a call did not return a value.
pub type Error {
  /// The handler ran and returned this error. `Internal` never carries the
  /// remote detail, which is logged on the serving node instead. An input
  /// that the server could not decode arrives as `Invalid`.
  Failed(service.Error)
  /// Nothing at the target handles the named procedure.
  NoHandler(procedure: String)
  /// The target could not be reached: the node is down or not connected,
  /// or the HTTP request failed.
  Unavailable(String)
  /// No reply arrived in time. The handler may still have run.
  Timeout
  /// The handler raised an exception or exited. Over HTTP the detail stays
  /// in the serving node's log.
  Crashed(String)
  /// The reply could not be decoded, usually because the two services
  /// disagree on the procedure's output type.
  BadResponse(String)
  /// The HTTP endpoint refused the token.
  Refused
}

/// A one-line description of an error, for logs.
pub fn describe(error: Error) -> String {
  case error {
    Failed(error) ->
      "remote service failed with "
      <> int.to_string(service.status_code(error))
      <> ": "
      <> service.message(error)
    NoHandler(name) -> "no remote handler for " <> name
    Unavailable(reason) -> "remote service unavailable: " <> reason
    Timeout -> "remote call timed out"
    Crashed(reason) -> "remote handler crashed: " <> reason
    BadResponse(reason) -> "bad remote response: " <> reason
    Refused -> "remote service refused the token"
  }
}

/// The service error a controller should answer with. The remote service's
/// own errors pass through unchanged so a `NotFound` stays a `404`; every
/// transport failure becomes `Internal` and is logged.
pub fn to_service_error(error: Error) -> service.Error {
  case error {
    Failed(error) -> error
    _ -> service.Internal(describe(error))
  }
}

/// Answer a request with the result of a call, like `service.respond`.
///
/// ```gleam
/// remote.call(users, users_api.get_user(), id, timeout: 5000)
/// |> remote.respond(ctx, user.to_json)
/// ```
pub fn respond(
  result: Result(a, Error),
  ctx: controller.GuardedContext(guarded),
  encode: fn(a) -> Json,
) -> Response(Content) {
  result
  |> result.map_error(to_service_error)
  |> service.respond(ctx, encode)
}

// -- Serving -------------------------------------------------------------------

/// The procedures one service offers. Build it with `handle`, then `start`
/// it for Erlang distribution, mount it with `controller` for HTTP, or both.
pub opaque type Server {
  Server(handlers: Dict(String, Handler))
}

/// A handler working on the wire: JSON in, `Ok(json)` or `Error(json)` out.
/// Over distribution it also gets the caller's trace headers, to continue
/// the caller's trace; over HTTP the request's own span already has.
type Handler =
  fn(String, Option(List(#(String, String)))) -> Result(String, String)

pub fn server() -> Server {
  Server(handlers: dict.new())
}

/// Serve `procedure` with `handler`. Handling a name twice keeps the last.
pub fn handle(
  server: Server,
  procedure: Procedure(input, output),
  handler: fn(input) -> service.Result(output),
) -> Server {
  let wire = fn(payload, trace_headers) {
    use <- serving_span(procedure.name, trace_headers)
    case json.parse(payload, procedure.input.decoder) {
      Error(error) ->
        Error(
          encode_error(service.Invalid(
            procedure.name <> ": " <> describe_json_error(error),
          )),
        )
      Ok(input) ->
        case handler(input) {
          Ok(output) -> Ok(json.to_string(procedure.output.encode(output)))
          Error(service.Internal(detail)) -> {
            logging.log(logging.Error, procedure.name <> ": " <> detail)
            trace.set_error("handler returned an internal error")
            Error(encode_error(service.Internal(detail)))
          }
          Error(error) -> Error(encode_error(error))
        }
    }
  }
  Server(handlers: dict.insert(server.handlers, procedure.name, wire))
}

/// Serving a call over distribution continues the caller's trace in a
/// server span. Over HTTP the request is already a server span, so the
/// procedure is a span inside it.
fn serving_span(
  name: String,
  trace_headers: Option(List(#(String, String))),
  run: fn() -> a,
) -> a {
  let span = trace.new(name) |> trace.attributes(rpc_attributes(name))
  case trace_headers {
    option.Some(headers) ->
      span |> trace.kind(trace.Server) |> trace.continue_from(headers)
    option.None -> span
  }
  |> trace.run(run)
}

fn rpc_attributes(name: String) -> List(trace.Attribute) {
  [trace.string("rpc.system", "howdy_remote"), trace.string("rpc.method", name)]
}

/// Run a call in a client span. It fails when the call could not be made
/// or the handler broke; a handler answering `NotFound` or `Invalid` is a
/// result like any other.
fn calling_span(
  name: String,
  kind: trace.Kind,
  target: Target,
  run: fn() -> Result(a, Error),
) -> Result(a, Error) {
  let target_name = case target {
    Cluster -> "cluster"
    OnNode(name:) -> name
    Http(url:, ..) -> url
  }
  use <- trace.run(
    trace.new(name)
    |> trace.kind(kind)
    |> trace.attributes([
      trace.string("server.address", target_name),
      ..rpc_attributes(name)
    ]),
  )
  let outcome = run()
  case outcome {
    Ok(_) -> Nil
    Error(Failed(service.Internal(_)) as error)
    | Error(Failed(service.TooManyRequests(_)) as error) ->
      trace.set_error(describe(error))
    Error(Failed(_)) -> Nil
    Error(error) -> trace.set_error(describe(error))
  }
  outcome
}

/// The names of the procedures a server handles, sorted.
pub fn procedures(server: Server) -> List(String) {
  dict.keys(server.handlers) |> list.sort(string.compare)
}

@external(erlang, "howdy_remote_ffi", "start_directory")
fn start_directory(handlers: Dict(String, Handler)) -> Result(Pid, String)

/// Offer the server's procedures to every node in the cluster, including
/// this one. The server is linked to the calling process; each call runs in
/// its own process on this node, so the server never blocks on a handler.
///
/// Start one server per node for each set of procedures. Several nodes
/// serving the same procedure share the calls made through `cluster`.
pub fn start(server: Server) -> Result(actor.Started(Nil), actor.StartError) {
  case start_directory(server.handlers) {
    Ok(pid) -> Ok(actor.Started(pid:, data: Nil))
    Error(reason) -> Error(actor.InitFailed(reason))
  }
}

/// `start` as a child of a supervisor.
pub fn supervised(server: Server) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() { start(server) })
}

/// Serve the procedures over HTTP, one `POST <at>/<procedure name>` route
/// each. Callers must send `authorization: Bearer <token>`; use a long
/// random secret and TLS. An empty token refuses every request.
///
/// ```gleam
/// howdy.new()
/// |> howdy.controller(remote.controller(server, at: "/rpc", token: secret))
/// ```
pub fn controller(
  server: Server,
  at prefix: String,
  token token: String,
) -> Controller {
  controller.new(prefix)
  |> controller.post("/:procedure", fn(ctx) { serve_http(server, token, ctx) })
}

@external(erlang, "howdy_remote_ffi", "run")
fn run(
  handler: Handler,
  payload: String,
) -> Result(Result(String, String), String)

fn serve_http(
  server: Server,
  token: String,
  ctx: Context,
) -> Response(Content) {
  let assert Ok(name) = controller.param(ctx, "procedure")
  case authorised(ctx, token), dict.get(server.handlers, name) {
    False, _ -> wire_error(401, "refused", [])
    True, Error(Nil) ->
      wire_error(404, "no_handler", [#("procedure", json.string(name))])
    True, Ok(handler) ->
      case controller.read_body(ctx, limit: body.default_limit) {
        Error(_) ->
          wire_reply(
            400,
            encode_error(service.Invalid("request body could not be read")),
          )
        Ok(bits) ->
          case bit_array.to_string(bits) {
            Error(Nil) ->
              wire_reply(
                400,
                encode_error(service.Invalid("request body is not UTF-8")),
              )
            Ok(payload) ->
              case run(handler, payload) {
                Ok(Ok(output)) -> wire_reply(200, output)
                Ok(Error(error)) -> wire_reply(error_status(error), error)
                Error(reason) -> {
                  logging.log(logging.Error, name <> " crashed: " <> reason)
                  wire_error(500, "crashed", [])
                }
              }
          }
      }
  }
}

fn authorised(ctx: Context, token: String) -> Bool {
  case request.get_header(ctx.request, "authorization") {
    Ok("Bearer " <> given) if token != "" ->
      crypto.secure_compare(<<given:utf8>>, <<token:utf8>>)
    _ -> False
  }
}

fn wire_reply(status: Int, body: String) -> Response(Content) {
  response.new(status)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_body(content.Text(body))
}

fn wire_error(
  status: Int,
  kind: String,
  fields: List(#(String, Json)),
) -> Response(Content) {
  json.object([#("kind", json.string(kind)), ..fields])
  |> json.to_string
  |> wire_reply(status, _)
}

fn error_status(error: String) -> Int {
  case json.parse(error, service_error_decoder()) {
    Ok(error) -> service.status_code(error)
    Error(_) -> 500
  }
}

// -- Wire format for service errors ----------------------------------------------

fn encode_error(error: service.Error) -> String {
  let kind = fn(kind) { #("kind", json.string(kind)) }
  let message = fn(message) { #("message", json.string(message)) }
  case error {
    service.NotFound(text) -> [kind("not_found"), message(text)]
    service.Invalid(text) -> [kind("invalid"), message(text)]
    service.Conflict(text) -> [kind("conflict"), message(text)]
    service.Unauthorized -> [kind("unauthorized")]
    service.Forbidden -> [kind("forbidden")]
    service.UnsupportedMediaType(text) -> [
      kind("unsupported_media_type"),
      message(text),
    ]
    service.Internal(_) -> [kind("internal")]
    service.Validation(errors) -> [
      kind("validation"),
      #(
        "fields",
        json.array(errors, fn(error) {
          json.object([
            #("field", json.string(error.field)),
            #("message", json.string(error.message)),
          ])
        }),
      ),
    ]
    service.TooManyRequests(seconds) -> [
      kind("too_many_requests"),
      #("retry_after", json.int(seconds)),
    ]
  }
  |> json.object
  |> json.to_string
}

fn service_error_decoder() -> Decoder(service.Error) {
  let message = decode.at(["message"], decode.string)
  use kind <- decode.field("kind", decode.string)
  case kind {
    "not_found" -> decode.map(message, service.NotFound)
    "invalid" -> decode.map(message, service.Invalid)
    "conflict" -> decode.map(message, service.Conflict)
    "unauthorized" -> decode.success(service.Unauthorized)
    "forbidden" -> decode.success(service.Forbidden)
    "unsupported_media_type" ->
      decode.map(message, service.UnsupportedMediaType)
    "internal" -> decode.success(service.Internal(""))
    "validation" ->
      decode.at(
        ["fields"],
        decode.list({
          use field <- decode.field("field", decode.string)
          use message <- decode.field("message", decode.string)
          decode.success(service.FieldError(field:, message:))
        }),
      )
      |> decode.map(service.Validation)
    "too_many_requests" ->
      decode.at(["retry_after"], decode.int)
      |> decode.map(service.TooManyRequests)
    _ -> decode.failure(service.Internal(""), "service error")
  }
}

/// Turn a handler's encoded error back into a call error. The remote
/// `Internal` detail is never sent, so the procedure name stands in.
fn decode_failure(name: String, error: String) -> Error {
  case json.parse(error, service_error_decoder()) {
    Ok(service.Internal(_)) ->
      Failed(service.Internal(name <> " failed remotely"))
    Ok(error) -> Failed(error)
    Error(error) -> BadResponse(name <> ": " <> describe_json_error(error))
  }
}

fn describe_json_error(error: json.DecodeError) -> String {
  case error {
    json.UnexpectedEndOfInput -> "unexpected end of JSON"
    json.UnexpectedByte(byte) -> "unexpected byte " <> byte
    json.UnexpectedSequence(sequence) -> "unexpected sequence " <> sequence
    json.UnableToDecode(errors) ->
      errors
      |> list.map(fn(error) {
        "expected "
        <> error.expected
        <> ", found "
        <> error.found
        <> case error.path {
          [] -> ""
          path -> " at " <> string.join(path, ".")
        }
      })
      |> string.join("; ")
  }
}

// -- Calling -------------------------------------------------------------------

/// Where a call goes.
pub opaque type Target {
  Cluster
  OnNode(name: String)
  Http(url: String, token: String)
}

/// Any connected node that serves the procedure, preferring this one. With
/// several nodes serving it, each call picks one at random. Nodes join and
/// leave automatically as they start servers, stop or disconnect.
pub fn cluster() -> Target {
  Cluster
}

/// The node with this full name, such as `"users@10.0.0.5"`. The node is
/// connected on first use if the cookies match.
pub fn node(name: String) -> Target {
  OnNode(name:)
}

/// A server mounted with `controller`, at the URL of its prefix such as
/// `"https://users.internal/rpc"`.
pub fn http(url: String, token token: String) -> Target {
  Http(url: string.remove_suffix(url, "/"), token:)
}

@external(erlang, "howdy_remote_ffi", "call_cluster")
fn call_cluster(
  name: String,
  payload: String,
  trace_headers: List(#(String, String)),
  timeout: Int,
) -> Result(Result(String, String), Error)

@external(erlang, "howdy_remote_ffi", "call_node")
fn call_node(
  node: String,
  name: String,
  payload: String,
  trace_headers: List(#(String, String)),
  timeout: Int,
) -> Result(Result(String, String), Error)

/// Call a procedure and wait up to `timeout` milliseconds for its output.
pub fn call(
  target: Target,
  procedure: Procedure(input, output),
  input: input,
  timeout timeout: Int,
) -> Result(output, Error) {
  let payload = json.to_string(procedure.input.encode(input))
  use <- calling_span(procedure.name, trace.Client, target)
  let headers = trace.inject([])
  case target {
    Cluster -> call_cluster(procedure.name, payload, headers, timeout)
    OnNode(name:) -> call_node(name, procedure.name, payload, headers, timeout)
    Http(url:, token:) ->
      call_http(url, token, procedure.name, payload, headers, timeout)
  }
  |> result.try(decode_reply(procedure, _))
}

fn decode_reply(
  procedure: Procedure(input, output),
  reply: Result(String, String),
) -> Result(output, Error) {
  case reply {
    Ok(output) ->
      json.parse(output, procedure.output.decoder)
      |> result.map_error(fn(error) {
        BadResponse(procedure.name <> ": " <> describe_json_error(error))
      })
    Error(error) -> Error(decode_failure(procedure.name, error))
  }
}

@external(erlang, "howdy_remote_ffi", "cast_cluster")
fn cast_cluster(
  name: String,
  payload: String,
  trace_headers: List(#(String, String)),
) -> Nil

@external(erlang, "howdy_remote_ffi", "cast_node")
fn cast_node(
  node: String,
  name: String,
  payload: String,
  trace_headers: List(#(String, String)),
) -> Nil

@external(erlang, "howdy_remote_ffi", "spawn_cast")
fn spawn_cast(run: fn() -> a) -> Nil

/// Call a procedure without waiting for, or learning about, the outcome.
/// Over distribution nothing waits at all; over HTTP the request is made
/// from a new process with a 30 second timeout. At most 64 casts are in
/// flight at once; beyond that they are dropped with a warning.
pub fn cast(
  target: Target,
  procedure: Procedure(input, output),
  input: input,
) -> Nil {
  let payload = json.to_string(procedure.input.encode(input))
  let _ = {
    use <- calling_span(procedure.name, trace.Producer, target)
    let headers = trace.inject([])
    case target {
      Cluster -> cast_cluster(procedure.name, payload, headers)
      OnNode(name:) -> cast_node(name, procedure.name, payload, headers)
      Http(url:, token:) ->
        spawn_cast(fn() {
          call_http(url, token, procedure.name, payload, headers, 30_000)
        })
    }
    Ok(Nil)
  }
  Nil
}

@external(erlang, "howdy_remote_ffi", "multicall")
fn multicall_ffi(
  name: String,
  payload: String,
  trace_headers: List(#(String, String)),
  timeout: Int,
) -> List(#(String, Result(Result(String, String), Error)))

/// Call a procedure on every node in the cluster that serves it, in
/// parallel, and wait up to `timeout` milliseconds for them all. Returns
/// each node's name and result, sorted by node name. Useful for clearing
/// caches or collecting statistics.
pub fn multicall(
  procedure: Procedure(input, output),
  input: input,
  timeout timeout: Int,
) -> List(#(String, Result(output, Error))) {
  let payload = json.to_string(procedure.input.encode(input))
  use <- trace.span(procedure.name, rpc_attributes(procedure.name))
  multicall_ffi(procedure.name, payload, trace.inject([]), timeout)
  |> list.map(fn(pair) {
    #(pair.0, result.try(pair.1, decode_reply(procedure, _)))
  })
}

@external(erlang, "howdy_remote_ffi", "providers")
fn providers_ffi(name: String) -> List(String)

/// The nodes in the cluster that serve a procedure, sorted. Useful for
/// health checks.
pub fn providers(procedure: Procedure(input, output)) -> List(String) {
  providers_ffi(procedure.name)
}

// -- Plain Erlang ----------------------------------------------------------------

@external(erlang, "howdy_remote_ffi", "apply")
fn apply_ffi(
  node: String,
  module: String,
  function: String,
  args: List(Dynamic),
  timeout: Int,
) -> Result(Dynamic, Error)

/// Call any exported function on a node, for services that do not use
/// `howdy_remote`. `module` is the Erlang module name: `"users@api"` for the
/// Gleam module `users/api`, `"Elixir.Billing"` for Elixir's `Billing`.
/// Nothing checks the arguments, so build them with `gleam/dynamic`; the
/// return value is checked with `decoder`.
///
/// ```gleam
/// remote.apply(
///   on: "billing@10.0.0.7",
///   module: "Elixir.Billing",
///   function: "balance",
///   args: [dynamic.int(account_id)],
///   decoder: decode.int,
///   timeout: 5000,
/// )
/// ```
pub fn apply(
  on node: String,
  module module: String,
  function function: String,
  args args: List(Dynamic),
  decoder decoder: Decoder(a),
  timeout timeout: Int,
) -> Result(a, Error) {
  use value <- result.try(apply_ffi(node, module, function, args, timeout))
  decode.run(value, decoder)
  |> result.map_error(fn(errors) {
    BadResponse(
      module
      <> ":"
      <> function
      <> " returned "
      <> describe_decode_errors(errors),
    )
  })
}

fn describe_decode_errors(errors: List(decode.DecodeError)) -> String {
  errors
  |> list.map(fn(error) {
    "a " <> error.found <> ", expected " <> error.expected
  })
  |> string.join("; ")
}

// -- Nodes -----------------------------------------------------------------------

@external(erlang, "howdy_remote_ffi", "connect")
fn connect_ffi(node: String) -> Result(Nil, Error)

/// Connect to a node now, rather than on the first call. Connecting to one
/// node of a cluster connects to the rest. A name that is not `name@host`
/// is `Unavailable`.
pub fn connect(node: String) -> Result(Nil, Error) {
  connect_ffi(node)
}

@external(erlang, "howdy_remote_ffi", "connect_to")
fn connect_to_ffi(nodes: List(String)) -> Result(Nil, Error)

/// Keep this node connected to `nodes`. Erlang connects to a node once and
/// does not try again when the connection drops, so a service that depends
/// on another node needs something that does. A connector under the
/// `howdy_remote` application's supervisor connects to each node, retries
/// a lost one with a backoff that doubles from a second to half a minute,
/// and logs each connection and loss once. Calling it again adds nodes.
///
/// ```gleam
/// let assert Ok(Nil) = remote.connect_to(["users@10.0.0.5"])
/// ```
///
/// The call returns as soon as the connector is running, not once the nodes
/// are connected. A name that is not `name@host`, or a node that is not
/// distributed, is `Unavailable`. Apps that run their own supervision tree
/// can use `connector_supervised` instead.
pub fn connect_to(nodes: List(String)) -> Result(Nil, Error) {
  connect_to_ffi(nodes)
}

@external(erlang, "howdy_remote_ffi", "start_connector")
fn start_connector(
  nodes: List(String),
) -> Result(actor.Started(Nil), actor.StartError)

/// `connect_to` as a child of the application's own supervisor:
///
/// ```gleam
/// static_supervisor.new(static_supervisor.OneForOne)
/// |> static_supervisor.add(remote.connector_supervised(["users@10.0.0.5"]))
/// |> static_supervisor.add(howdy.supervised(app))
/// ```
pub fn connector_supervised(
  nodes: List(String),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() { start_connector(nodes) })
}

@external(erlang, "howdy_remote_ffi", "self_node")
fn self_node() -> String

/// The full name of this node, such as `"users@10.0.0.5"`, or
/// `"nonode@nohost"` when distribution is off.
pub fn self() -> String {
  self_node()
}

// -- HTTP transport --------------------------------------------------------------

fn call_http(
  url: String,
  token: String,
  name: String,
  payload: String,
  trace_headers: List(#(String, String)),
  timeout: Int,
) -> Result(Result(String, String), Error) {
  use req <- result.try(
    request.to(url <> "/" <> name)
    |> result.replace_error(Unavailable("invalid URL " <> url)),
  )
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("authorization", "Bearer " <> token)
    |> request.set_body(payload)
  let req =
    list.fold(trace_headers, req, fn(req, header) {
      request.set_header(req, header.0, header.1)
    })
  case httpc.configure() |> httpc.timeout(timeout) |> httpc.dispatch(req) {
    Error(httpc.ResponseTimeout) -> Error(Timeout)
    Error(error) -> Error(Unavailable(describe_http_error(url, error)))
    Ok(res) -> http_reply(url, name, res)
  }
}

fn http_reply(
  url: String,
  name: String,
  res: Response(String),
) -> Result(Result(String, String), Error) {
  let kind = json.parse(res.body, decode.at(["kind"], decode.string))
  case res.status, kind {
    200, _ -> Ok(Ok(res.body))
    401, Ok("refused") -> Error(Refused)
    404, Ok("no_handler") -> Error(NoHandler(name))
    500, Ok("crashed") -> Error(Crashed("see the serving node's log"))
    _, Ok(_) -> Ok(Error(res.body))
    status, Error(_) ->
      Error(Unavailable(
        url <> " answered " <> int.to_string(status) <> " without a reply",
      ))
  }
}

fn describe_http_error(url: String, error: httpc.HttpError) -> String {
  case error {
    httpc.InvalidUtf8Response -> url <> " sent a response that is not UTF-8"
    httpc.FailedToConnect(..) -> "could not connect to " <> url
    httpc.ResponseTimeout -> url <> " timed out"
  }
}
