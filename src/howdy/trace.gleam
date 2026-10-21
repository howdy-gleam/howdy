//// Tracing with OpenTelemetry.
////
//// Howdy and its packages open a span around each request, database query,
//// remote call and email, and your code can add its own:
////
//// ```gleam
//// import howdy/trace
////
//// pub fn checkout(cart: Cart) {
////   use <- trace.span("checkout", [trace.int("cart.items", cart.count)])
////   ...
//// }
//// ```
////
//// Nothing is recorded or sent anywhere until an OpenTelemetry SDK is
//// running. Without one every function here does next to nothing, so
//// instrumented code costs almost nothing in an app that does not collect
//// telemetry. Add `howdy_telemetry` to switch it on; see its docs.
////
//// Spans nest by process: a span opened while another is running in the
//// same process becomes its child. Other Gleam libraries built on
//// `opentelemetry_api`, such as `opengleametry`, share the same context, so
//// their spans nest under Howdy's and the other way round. Work handed to
//// another process starts a new trace unless you carry the context across
//// with `context` and `within`.

import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// A key and value recorded on a span or event. Use the OpenTelemetry
/// semantic convention names where one fits, such as `http.route` or
/// `db.system.name`.
pub opaque type Attribute {
  Attribute(key: String, value: Dynamic)
}

pub fn string(key: String, value: String) -> Attribute {
  Attribute(key, to_dynamic(value))
}

pub fn int(key: String, value: Int) -> Attribute {
  Attribute(key, to_dynamic(value))
}

pub fn float(key: String, value: Float) -> Attribute {
  Attribute(key, to_dynamic(value))
}

pub fn bool(key: String, value: Bool) -> Attribute {
  Attribute(key, to_dynamic(value))
}

/// A list of strings, such as the tags on a message.
pub fn strings(key: String, values: List(String)) -> Attribute {
  Attribute(key, to_dynamic(values))
}

/// What a span represents. Tracing backends use it to recognise requests,
/// so the request Howdy serves is a `Server` span and a call out to another
/// service is a `Client` span.
pub type Kind {
  Internal
  Server
  Client
  Producer
  Consumer
}

/// A reference to another span, usually in another trace, that caused this
/// one: an email sent by a worker links to the request that queued it.
pub opaque type Link {
  Link(Dynamic)
}

/// The tracing context of a process, to carry into another process with
/// `within`.
pub opaque type Context {
  Context(Dynamic)
}

/// A span waiting to be run. Build one with `new` when you need more than
/// `span` offers.
pub opaque type Builder {
  Builder(
    name: String,
    kind: Kind,
    attributes: List(Attribute),
    links: List(Link),
    headers: Option(List(#(String, String))),
  )
}

/// Run `run` inside a span called `name`, and return what it returns.
/// The span ends when `run` returns. If `run` panics, the panic is recorded
/// on the span, the span is marked as failed, and the panic carries on.
pub fn span(name: String, with: List(Attribute), body: fn() -> a) -> a {
  new(name) |> attributes(with) |> run(body)
}

/// Start building a span called `name`. It is an `Internal` span with no
/// attributes until you say otherwise.
pub fn new(name: String) -> Builder {
  Builder(name:, kind: Internal, attributes: [], links: [], headers: None)
}

pub fn kind(builder: Builder, kind: Kind) -> Builder {
  Builder(..builder, kind:)
}

/// Add attributes to the span when it starts. Samplers only see attributes
/// given here, not ones added later with `set_attributes`.
pub fn attributes(builder: Builder, attributes: List(Attribute)) -> Builder {
  Builder(..builder, attributes: list.append(builder.attributes, attributes))
}

pub fn link(builder: Builder, link: Link) -> Builder {
  Builder(..builder, links: [link, ..builder.links])
}

/// Continue the trace described by the `traceparent` and `tracestate`
/// headers of an incoming request, if they are there. Header names must be
/// lowercase, as they are in a `gleam/http` request. Without trace headers
/// the span starts a new trace, or continues the current one.
pub fn continue_from(
  builder: Builder,
  headers: List(#(String, String)),
) -> Builder {
  Builder(..builder, headers: Some(headers))
}

/// Run `run` inside the span and return what it returns.
pub fn run(builder: Builder, body: fn() -> a) -> a {
  let Builder(name:, kind:, attributes:, links:, headers:) = builder
  with_span(
    name,
    kind,
    list_to_pairs(attributes),
    list.reverse(links)
      |> list.map(fn(link) {
        let Link(link) = link
        link
      }),
    option.unwrap(headers, []),
    body,
  )
}

/// Add attributes to the current span. Does nothing outside a span.
pub fn set_attributes(attributes: List(Attribute)) -> Nil {
  set_current_attributes(list_to_pairs(attributes))
}

/// Record that something happened at this moment in the current span.
pub fn event(name: String, attributes: List(Attribute)) -> Nil {
  add_event(name, list_to_pairs(attributes))
}

/// Mark the current span as failed, with a short description of what went
/// wrong. A span that panics is marked for you.
pub fn set_error(message: String) -> Nil {
  set_error_status(message)
}

/// Whether the current span is being recorded. Use it to skip work that
/// only feeds a span, such as formatting a large attribute.
@external(erlang, "howdy_trace_ffi", "is_recording")
pub fn is_recording() -> Bool

/// The current trace's id as 32 lowercase hex characters, if the current
/// span is being recorded. Show it on an error page or in a log line so the trace can be
/// found later.
pub fn trace_id() -> Option(String) {
  current_ids() |> option.from_result |> option.map(fn(ids) { ids.0 })
}

/// The current span as a W3C `traceparent` header value, if it is being
/// recorded. Store it alongside work queued for later, then `link_to` it.
pub fn traceparent() -> Option(String) {
  case current_ids() {
    Ok(#(trace, span)) -> Some("00-" <> trace <> "-" <> span <> "-01")
    Error(Nil) -> None
  }
}

/// A link to the span a `traceparent` value describes.
pub fn link_to(traceparent: String) -> Result(Link, Nil) {
  case string.split(traceparent, "-") {
    ["00", trace, span, flags] ->
      case string.length(trace) == 32 && string.length(span) == 16 {
        True ->
          make_link(trace, span, flags)
          |> result.map(Link)
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// Add the current trace's `traceparent` and `tracestate` headers to
/// `headers`, so a service you call can continue the trace. Returns
/// `headers` unchanged outside a span.
@external(erlang, "howdy_trace_ffi", "inject")
pub fn inject(headers: List(#(String, String))) -> List(#(String, String))

/// The tracing context of this process.
pub fn context() -> Context {
  Context(current_context())
}

/// Run `run` in `context`, typically one captured with `context` in the
/// process that handed over the work. Spans `run` opens become children of
/// the span that was current there.
pub fn within(context: Context, run: fn() -> a) -> a {
  let Context(context) = context
  with_context(context, run)
}

// -- FFI ----------------------------------------------------------------------

fn list_to_pairs(attributes: List(Attribute)) -> List(#(String, Dynamic)) {
  list.map(attributes, fn(attribute) { #(attribute.key, attribute.value) })
}

@external(erlang, "howdy_trace_ffi", "identity")
fn to_dynamic(value: a) -> Dynamic

@external(erlang, "howdy_trace_ffi", "with_span")
fn with_span(
  name: String,
  kind: Kind,
  attributes: List(#(String, Dynamic)),
  links: List(Dynamic),
  headers: List(#(String, String)),
  run: fn() -> a,
) -> a

@external(erlang, "howdy_trace_ffi", "set_attributes")
fn set_current_attributes(attributes: List(#(String, Dynamic))) -> Nil

@external(erlang, "howdy_trace_ffi", "add_event")
fn add_event(name: String, attributes: List(#(String, Dynamic))) -> Nil

@external(erlang, "howdy_trace_ffi", "set_error")
fn set_error_status(message: String) -> Nil

@external(erlang, "howdy_trace_ffi", "current_ids")
fn current_ids() -> Result(#(String, String), Nil)

@external(erlang, "howdy_trace_ffi", "make_link")
fn make_link(trace: String, span: String, flags: String) -> Result(Dynamic, Nil)

@external(erlang, "howdy_trace_ffi", "current_context")
fn current_context() -> Dynamic

@external(erlang, "howdy_trace_ffi", "with_context")
fn with_context(context: Dynamic, run: fn() -> a) -> a
