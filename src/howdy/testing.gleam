//// Exercise an app without starting a server.
////
//// Build a request, send it through the app, and read the response. The
//// whole pipeline runs: routing, middleware, guards, versioning, body
//// decoding and validation. Nothing touches a socket, so tests are fast and
//// need no ports.
////
//// ```gleam
//// import howdy/testing
////
//// fn app() {
////   howdy.new() |> howdy.controller(user_controller())
//// }
////
//// pub fn create_user_test() {
////   let res =
////     testing.post("/user", json.object([#("name", json.string("Ada"))]))
////     |> testing.header("x-api-key", "secret")
////     |> testing.send(app())
////
////   assert res.status == 201
////   assert testing.json(res, user.decoder()) == Ok(User(id: 1, name: "Ada"))
//// }
////
//// pub fn rejects_blank_name_test() {
////   let res =
////     testing.post("/user", json.object([#("name", json.string(""))]))
////     |> testing.send(app())
////
////   assert res.status == 422
////   assert testing.field_errors(res)
////     == Ok([service.FieldError("name", "must not be empty")])
//// }
//// ```
////
//// Requests are ordinary `gleam/http/request` values, so anything that
//// module offers, such as `request.set_header`, works on them too.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/process.{type Subject}
import gleam/http.{type Method}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import howdy.{type App}
import howdy/content.{type Content}
import howdy/context.{type Body}
import howdy/service.{type FieldError}
import howdy/sse

// -- Building requests -------------------------------------------------------

/// A file to send in a form with `multipart_body`.
pub type FormFile {
  FormFile(
    field: String,
    file_name: String,
    content_type: String,
    content: BitArray,
  )
}

/// A request with the given method and no body. A query string in `path`,
/// such as `"/users?page=2"`, is split off and set as the query.
pub fn request(method: Method, path: String) -> Request(Body) {
  let #(path, query) = case string.split_once(path, "?") {
    Ok(#(path, query)) -> #(path, Some(query))
    Error(Nil) -> #(path, None)
  }
  request.new()
  |> request.set_method(method)
  |> request.set_path(path)
  |> request.set_body(context.fake(<<>>, None))
  |> fn(req) { request.Request(..req, query:) }
}

pub fn get(path: String) -> Request(Body) {
  request(http.Get, path)
}

pub fn delete(path: String) -> Request(Body) {
  request(http.Delete, path)
}

/// A `POST` with a JSON body and matching content type.
pub fn post(path: String, body: Json) -> Request(Body) {
  request(http.Post, path) |> json_body(body)
}

/// A `PUT` with a JSON body and matching content type.
pub fn put(path: String, body: Json) -> Request(Body) {
  request(http.Put, path) |> json_body(body)
}

/// A `PATCH` with a JSON body and matching content type.
pub fn patch(path: String, body: Json) -> Request(Body) {
  request(http.Patch, path) |> json_body(body)
}

/// A `POST` of an HTML form: the pairs are urlencoded and the content type
/// set, as a browser would submit them.
pub fn post_form(
  path: String,
  pairs: List(#(String, String)),
) -> Request(Body) {
  request(http.Post, path) |> form_body(pairs)
}

/// A `POST` of an HTML form with files, encoded as `multipart/form-data` as
/// a browser would submit it.
pub fn post_multipart(
  path: String,
  fields: List(#(String, String)),
  files: List(FormFile),
) -> Request(Body) {
  request(http.Post, path) |> multipart_body(fields, files)
}

/// Replace the body with a `multipart/form-data` form, the fields and then
/// the files, and set the content type. Read it with `form.read_with` and
/// limits that accept files.
pub fn multipart_body(
  req: Request(Body),
  fields: List(#(String, String)),
  files: List(FormFile),
) -> Request(Body) {
  let boundary = "howdy-test-boundary-5a1f0c"
  let part = fn(disposition, headers, content) {
    <<
      "--":utf8,
      boundary:utf8,
      "\r\nContent-Disposition: form-data; ":utf8,
      disposition:utf8,
      "\r\n":utf8,
      headers:utf8,
      "\r\n":utf8,
      content:bits,
      "\r\n":utf8,
    >>
  }
  let fields =
    list.map(fields, fn(field) {
      part("name=" <> quoted(field.0), "", <<field.1:utf8>>)
    })
  let files =
    list.map(files, fn(file) {
      part(
        "name=" <> quoted(file.field) <> "; filename=" <> quoted(file.file_name),
        "Content-Type: " <> file.content_type <> "\r\n",
        file.content,
      )
    })
  let body =
    list.append(fields, files)
    |> list.fold(<<>>, fn(body, part) { <<body:bits, part:bits>> })
  req
  |> bytes_body(<<body:bits, "--":utf8, boundary:utf8, "--\r\n":utf8>>)
  |> request.set_header(
    "content-type",
    "multipart/form-data; boundary=" <> boundary,
  )
}

/// A quoted parameter value, escaped as browsers do.
fn quoted(value: String) -> String {
  let value =
    value
    |> string.replace("\"", "%22")
    |> string.replace("\r", "%0D")
    |> string.replace("\n", "%0A")
  "\"" <> value <> "\""
}

/// Replace the body with JSON and set the content type.
pub fn json_body(req: Request(Body), body: Json) -> Request(Body) {
  req
  |> bytes_body(<<json.to_string(body):utf8>>)
  |> request.set_header("content-type", "application/json")
}

/// Replace the body with urlencoded form fields and set the content type.
/// Repeat a name for multi-value fields such as multi-selects.
pub fn form_body(
  req: Request(Body),
  pairs: List(#(String, String)),
) -> Request(Body) {
  req
  |> bytes_body(<<uri.query_to_string(pairs):utf8>>)
  |> request.set_header("content-type", "application/x-www-form-urlencoded")
}

/// Replace the body with text and set the content type.
pub fn text_body(req: Request(Body), body: String) -> Request(Body) {
  req
  |> bytes_body(<<body:utf8>>)
  |> request.set_header("content-type", "text/plain; charset=utf-8")
}

/// Replace the body with raw bytes. No content type is set.
pub fn bytes_body(req: Request(Body), body: BitArray) -> Request(Body) {
  request.set_body(req, context.with_bits(req.body, body))
}

/// Set a header, replacing any existing value.
pub fn header(
  req: Request(Body),
  name: String,
  value: String,
) -> Request(Body) {
  request.set_header(req, name, value)
}

/// Set the query string from key and value pairs, replacing any existing
/// query. Values are encoded for you.
pub fn query(
  req: Request(Body),
  pairs: List(#(String, String)),
) -> Request(Body) {
  request.set_query(req, pairs)
}

/// Add a cookie. The value is percent-encoded, matching what `cookie.set`
/// writes, so anything `cookie.string` can read round-trips.
pub fn cookie(
  req: Request(Body),
  name: String,
  value: String,
) -> Request(Body) {
  request.set_cookie(req, name, uri.percent_encode(value))
}

/// Make the request appear to come from `ip`. Without this the client
/// address is unknown and `rate_limit.by_ip` does not count the request.
pub fn from_ip(req: Request(Body), ip: String) -> Request(Body) {
  request.set_body(req, context.with_ip(req.body, ip))
}

// -- Sending -----------------------------------------------------------------

/// Run the request through the app and return the response, exactly as the
/// server would produce it.
pub fn send(req: Request(Body), app: App) -> Response(Content) {
  howdy.serve(app)(req)
}

// -- Cleaning up -------------------------------------------------------------

/// Run `run`, then `after`, even when `run` crashes, as a test does when an
/// assertion fails. A crash still fails the test once `after` has run. Use
/// it to release what a test opened, such as a database:
///
/// ```gleam
/// pub fn with_db(run_test: fn(Repo) -> a) -> a {
///   let assert Ok(db) = sqlite.start(sqlite.memory())
///   use <- testing.cleanup(fn() { repo.close(db) })
///   let assert Ok(_) = database.migrate(db)
///   run_test(db)
/// }
/// ```
@external(erlang, "howdy_ffi", "cleanup")
pub fn cleanup(after cleanup: fn() -> b, run run: fn() -> a) -> a

// -- Reading responses -------------------------------------------------------

/// The response body as text. `Empty` is `""`, and a body from
/// `howdy/stream` is written out in full. Panics for bodies that are not
/// UTF-8 or cannot be read in a test, such as a file or an event stream.
pub fn text(res: Response(Content)) -> String {
  case bit_array.to_string(bytes(res)) {
    Ok(text) -> text
    Error(Nil) -> panic as "howdy/testing: response body is not valid UTF-8"
  }
}

/// The response body as bytes. `Empty` is `<<>>`, and a body from
/// `howdy/stream` is written out in full. Panics for bodies that cannot be
/// read in a test, such as a file or an event stream.
pub fn bytes(res: Response(Content)) -> BitArray {
  case res.body {
    content.Text(text) -> <<text:utf8>>
    content.Bytes(tree) -> bytes_tree.to_bit_array(tree)
    content.Empty -> <<>>
    content.Native(_) ->
      case content.collect(res.body) {
        Ok(bits) -> bits
        Error(Nil) ->
          panic as "howdy/testing: response body is streamed and cannot be read"
      }
  }
}

// -- Event streams -----------------------------------------------------------

/// An event stream from `howdy/sse`, running in a test without a socket.
pub opaque type EventStream {
  EventStream(events: Subject(sse.Event), close: fn() -> Nil)
}

/// Open the event stream a response describes. Its `on_open` has run by
/// the time this returns, so it is already on its topics and anything the
/// test broadcasts reaches it. Heartbeats are not sent. Panics if the
/// response is not an event stream; check the status first.
///
/// ```gleam
/// let stream = testing.get("/orders/events") |> testing.send(app())
///   |> testing.open_events
/// sse.broadcast("orders", sse.event("hello"))
/// assert testing.next_event(stream) == Ok(sse.event("hello"))
/// testing.close_events(stream)
/// ```
pub fn open_events(res: Response(Content)) -> EventStream {
  let rehearse = case sse.rehearsal(res.body) {
    Ok(rehearse) -> rehearse
    Error(Nil) -> panic as "howdy/testing: response is not an event stream"
  }
  let events = process.new_subject()
  let close = rehearse(fn(event) { process.send(events, event) })
  EventStream(events:, close:)
}

/// The next event the stream sends, waiting up to a second for it.
/// `Error(Nil)` if none arrives in time.
pub fn next_event(stream: EventStream) -> Result(sse.Event, Nil) {
  process.receive(stream.events, 1000)
}

/// Every event the stream has sent that the test has not yet read, without
/// waiting for more.
pub fn sent_events(stream: EventStream) -> List(sse.Event) {
  case process.receive(stream.events, 0) {
    Ok(event) -> [event, ..sent_events(stream)]
    Error(Nil) -> []
  }
}

/// End the stream as a client going away would, and wait for its
/// `on_close` to run.
pub fn close_events(stream: EventStream) -> Nil {
  stream.close()
}

/// Decode the response body as JSON with `decoder`.
pub fn json(
  res: Response(Content),
  decoder: Decoder(a),
) -> Result(a, json.DecodeError) {
  json.parse_bits(bytes(res), decoder)
}

/// The message from a standard error response, `{"error": "..."}`, as
/// produced by `service.error_response`. `Error(Nil)` when the body is not
/// one.
pub fn error(res: Response(Content)) -> Result(String, Nil) {
  let decoder = {
    use message <- decode.field("error", decode.string)
    decode.success(message)
  }
  json(res, decoder) |> result.replace_error(Nil)
}

/// The field errors from a `422` validation response. `Error(Nil)` when the
/// body is not one.
pub fn field_errors(res: Response(Content)) -> Result(List(FieldError), Nil) {
  let field = {
    use field <- decode.field("field", decode.string)
    use message <- decode.field("message", decode.string)
    decode.success(service.FieldError(field:, message:))
  }
  let decoder = {
    use fields <- decode.field("fields", decode.list(field))
    decode.success(fields)
  }
  json(res, decoder) |> result.replace_error(Nil)
}

/// Every cookie the response sets, as name and decoded value pairs in the
/// order they were set. A deleted cookie appears with an empty value.
/// Attributes such as `Path` and `Max-Age` are dropped; read the raw
/// `set-cookie` headers to check those.
pub fn cookies(res: Response(Content)) -> List(#(String, String)) {
  res.headers
  |> list.filter(fn(pair) { pair.0 == "set-cookie" })
  // gleam/http prepends headers, so the newest cookie comes first.
  |> list.reverse
  |> list.filter_map(fn(pair) {
    let cookie = case string.split_once(pair.1, ";") {
      Ok(#(cookie, _)) -> cookie
      Error(Nil) -> pair.1
    }
    case string.split_once(cookie, "=") {
      Ok(#(name, value)) ->
        Ok(#(
          string.trim(name),
          uri.percent_decode(value) |> result.unwrap(value),
        ))
      Error(Nil) -> Error(Nil)
    }
  })
}
