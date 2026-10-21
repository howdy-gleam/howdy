//// Reading an OpenAPI 3.1 document for the API pages: its operations and
//// security schemes, what its JSON Schemas look like to a person, and an
//// example body to start a request from.
////
//// The document is read as JSON, not from `howdy/openapi`'s own values, so
//// anything the pages show is what a client of the document would see.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string

pub type Document {
  Document(
    title: String,
    version: String,
    description: String,
    operations: List(Operation),
    schemes: List(#(String, Scheme)),
    /// Schemes every operation requires unless it names its own.
    security: List(String),
    schemas: Dict(String, Dynamic),
  )
}

pub type Operation {
  Operation(
    method: String,
    path: String,
    id: String,
    summary: String,
    description: String,
    tags: List(String),
    parameters: List(Parameter),
    /// The JSON Schema of the request body, if it takes one.
    body: Option(Dynamic),
    responses: List(Reply),
    /// The schemes it requires, when it names its own.
    security: Option(List(String)),
    deprecated: Bool,
  )
}

pub type Parameter {
  Parameter(
    name: String,
    /// `path`, `query`, `header` or `cookie`.
    location: String,
    required: Bool,
    description: String,
    schema: Option(Dynamic),
  )
}

pub type Reply {
  Reply(
    status: String,
    description: String,
    media_type: Option(String),
    schema: Option(Dynamic),
  )
}

pub type Scheme {
  /// `authorization: Bearer <token>`.
  Bearer
  /// A key in a header or a cookie, under `name`.
  ApiKey(location: String, name: String)
  /// A scheme the pages cannot fill in, such as OAuth.
  Other(kind: String)
}

/// Parse a document. `Error` with a reason when it is not one.
pub fn parse(text: String) -> Result(Document, String) {
  json.parse(text, document_decoder())
  |> result.replace_error("not an OpenAPI document")
}

fn document_decoder() -> Decoder(Document) {
  use title <- decode.subfield(["info", "title"], decode.string)
  use version <- decode.subfield(["info", "version"], decode.string)
  use description <- decode.then(decode.optionally_at(
    ["info", "description"],
    "",
    decode.string,
  ))
  use paths <- decode.optional_field(
    "paths",
    dict.new(),
    decode.dict(decode.string, decode.dict(decode.string, decode.dynamic)),
  )
  use security <- decode.optional_field("security", [], requirement_decoder())
  use schemes <- decode.then(decode.optionally_at(
    ["components", "securitySchemes"],
    dict.new(),
    decode.dict(decode.string, scheme_decoder()),
  ))
  use schemas <- decode.then(decode.optionally_at(
    ["components", "schemas"],
    dict.new(),
    decode.dict(decode.string, decode.dynamic),
  ))
  let operations =
    dict.to_list(paths)
    |> list.flat_map(fn(entry) {
      let #(path, item) = entry
      list.filter_map(methods, fn(method) {
        use data <- result.try(dict.get(item, method))
        decode.run(data, operation_decoder(method, path))
        |> result.replace_error(Nil)
      })
    })
    |> list.sort(fn(a, b) {
      case string.compare(a.path, b.path) {
        order.Eq -> int.compare(method_rank(a.method), method_rank(b.method))
        other -> other
      }
    })
  decode.success(Document(
    title:,
    version:,
    description:,
    operations:,
    schemes: dict.to_list(schemes)
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) }),
    security:,
    schemas:,
  ))
}

const methods = ["get", "post", "put", "patch", "delete", "head", "options"]

fn method_rank(method: String) -> Int {
  list.index_fold(methods, 99, fn(found, candidate, index) {
    case candidate == method {
      True -> index
      False -> found
    }
  })
}

fn operation_decoder(method: String, path: String) -> Decoder(Operation) {
  use id <- decode.optional_field("operationId", "", decode.string)
  use summary <- decode.optional_field("summary", "", decode.string)
  use description <- decode.optional_field("description", "", decode.string)
  use tags <- decode.optional_field("tags", [], decode.list(decode.string))
  use parameters <- decode.optional_field(
    "parameters",
    [],
    decode.list(parameter_decoder()),
  )
  use body <- decode.optional_field(
    "requestBody",
    None,
    decode.map(content_decoder(), fn(content) {
      option.then(content, fn(entry) { entry.1 })
    }),
  )
  use responses <- decode.optional_field(
    "responses",
    [],
    decode.dict(decode.string, reply_decoder())
      |> decode.map(fn(replies) {
        dict.to_list(replies)
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
        |> list.map(fn(entry) {
          let #(status, #(description, content)) = entry
          Reply(
            status:,
            description:,
            media_type: option.map(content, fn(entry) { entry.0 }),
            schema: option.then(content, fn(entry) { entry.1 }),
          )
        })
      }),
  )
  use security <- decode.optional_field(
    "security",
    None,
    decode.map(requirement_decoder(), Some),
  )
  use deprecated <- decode.optional_field("deprecated", False, decode.bool)
  decode.success(Operation(
    method:,
    path:,
    id:,
    summary:,
    description:,
    tags:,
    parameters:,
    body:,
    responses:,
    security:,
    deprecated:,
  ))
}

fn parameter_decoder() -> Decoder(Parameter) {
  use name <- decode.field("name", decode.string)
  use location <- decode.field("in", decode.string)
  use required <- decode.optional_field("required", False, decode.bool)
  use description <- decode.optional_field("description", "", decode.string)
  use schema <- decode.optional_field(
    "schema",
    None,
    decode.map(decode.dynamic, Some),
  )
  decode.success(Parameter(name:, location:, required:, description:, schema:))
}

fn reply_decoder() -> Decoder(#(String, Option(#(String, Option(Dynamic))))) {
  use description <- decode.optional_field("description", "", decode.string)
  use content <- decode.then(content_decoder())
  decode.success(#(description, content))
}

/// The media type and schema of a `content` object, preferring JSON.
fn content_decoder() -> Decoder(Option(#(String, Option(Dynamic)))) {
  use content <- decode.optional_field(
    "content",
    dict.new(),
    decode.dict(
      decode.string,
      decode.optional_field(
        "schema",
        None,
        decode.map(decode.dynamic, Some),
        decode.success,
      ),
    ),
  )
  let entries = dict.to_list(content)
  let json =
    list.find(entries, fn(entry) { string.contains(entry.0, "json") })
    |> result.or(list.first(entries))
  decode.success(option.from_result(json))
}

fn requirement_decoder() -> Decoder(List(String)) {
  decode.list(decode.dict(decode.string, decode.dynamic))
  |> decode.map(list.flat_map(_, dict.keys))
}

fn scheme_decoder() -> Decoder(Scheme) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "http" -> {
      use scheme <- decode.optional_field("scheme", "", decode.string)
      case string.lowercase(scheme) {
        "bearer" -> decode.success(Bearer)
        other -> decode.success(Other("http " <> other))
      }
    }
    "apiKey" -> {
      use location <- decode.field("in", decode.string)
      use name <- decode.field("name", decode.string)
      decode.success(ApiKey(location:, name:))
    }
    other -> decode.success(Other(other))
  }
}

/// The schemes an operation requires: its own, or the document's.
pub fn security_of(document: Document, operation: Operation) -> List(String) {
  option.unwrap(operation.security, document.security)
}

// -- Schemas for people -------------------------------------------------------

/// Follow a `$ref` to a component schema, once.
pub fn resolve(document: Document, schema: Dynamic) -> Dynamic {
  case reference(schema) {
    Some(name) -> result.unwrap(dict.get(document.schemas, name), schema)
    None -> schema
  }
}

/// The component a schema refers to, as in `#/components/schemas/User`.
pub fn reference(schema: Dynamic) -> Option(String) {
  case decode.run(schema, decode.at(["$ref"], decode.string)) {
    Ok("#/components/schemas/" <> name) -> Some(name)
    _ -> None
  }
}

/// The item schema of an array schema.
pub fn items(schema: Dynamic) -> Option(Dynamic) {
  decode.run(schema, decode.at(["items"], decode.dynamic))
  |> option.from_result
}

/// A short description of a schema's type, such as `array of User` or
/// `string (email)`.
pub fn type_text(schema: Dynamic) -> String {
  case reference(schema) {
    Some(name) -> name
    None -> {
      let kind = string_at(schema, "type")
      case kind, list_at(schema, "enum"), list_at(schema, "anyOf") {
        _, [_, ..] as values, _ ->
          "one of " <> string.join(list.map(values, show), ", ")
        _, _, [_, ..] as options ->
          list.map(options, type_text) |> string.join(" or ")
        Ok("array"), _, _ ->
          case decode.run(schema, decode.at(["items"], decode.dynamic)) {
            Ok(items) -> "array of " <> type_text(items)
            Error(_) -> "array"
          }
        Ok("object"), _, _ ->
          case
            decode.run(
              schema,
              decode.at(["additionalProperties"], decode.dynamic),
            )
          {
            Ok(values) -> "map of " <> type_text(values)
            Error(_) -> "object"
          }
        Ok(kind), _, _ ->
          case string_at(schema, "format") {
            Ok(format) -> kind <> " (" <> format <> ")"
            Error(Nil) -> kind
          }
        Error(Nil), _, _ -> "any"
      }
    }
  }
}

/// Constraints and a description worth showing next to a type.
pub fn notes(schema: Dynamic) -> String {
  let bound = fn(key, before, after) {
    case decode.run(schema, decode.at([key], decode.int)), after {
      Ok(1), " characters" -> [before <> "1 character"]
      Ok(value), _ -> [before <> int.to_string(value) <> after]
      Error(_), _ -> []
    }
  }
  list.flatten([
    bound("minLength", "at least ", " characters"),
    bound("maxLength", "at most ", " characters"),
    bound("minimum", "at least ", ""),
    bound("maximum", "at most ", ""),
    case string_at(schema, "format") {
      Ok(format) -> [format]
      Error(Nil) -> []
    },
    case string_at(schema, "description") {
      Ok(text) -> [text]
      Error(Nil) -> []
    },
    case decode.run(schema, decode.at(["deprecated"], decode.bool)) {
      Ok(True) -> ["deprecated"]
      _ -> []
    },
  ])
  |> string.join("; ")
}

/// An object schema's properties: name, schema and whether it is required.
pub fn properties(
  document: Document,
  schema: Dynamic,
) -> List(#(String, Dynamic, Bool)) {
  let schema = resolve(document, schema)
  let required =
    decode.run(schema, decode.at(["required"], decode.list(decode.string)))
    |> result.unwrap([])
  let names =
    decode.run(
      schema,
      decode.at(["properties"], decode.dict(decode.string, decode.dynamic)),
    )
    |> result.unwrap(dict.new())
  // Property order is lost when JSON is decoded, so required fields come
  // first, in their declared order, then the rest by name.
  let ordered =
    list.append(
      required,
      dict.keys(names)
        |> list.filter(fn(name) { !list.contains(required, name) })
        |> list.sort(string.compare),
    )
  list.filter_map(ordered, fn(name) {
    dict.get(names, name)
    |> result.map(fn(property) {
      #(name, property, list.contains(required, name))
    })
  })
}

fn string_at(schema: Dynamic, key: String) -> Result(String, Nil) {
  decode.run(schema, decode.at([key], decode.string))
  |> result.replace_error(Nil)
}

fn list_at(schema: Dynamic, key: String) -> List(Dynamic) {
  decode.run(schema, decode.at([key], decode.list(decode.dynamic)))
  |> result.unwrap([])
}

fn show(value: Dynamic) -> String {
  case decode.run(value, value_decoder()) {
    Ok(String(text)) -> text
    Ok(value) -> pretty(value)
    Error(_) -> "?"
  }
}

// -- JSON values ---------------------------------------------------------------

/// A JSON value, to build examples and to print responses readably.
pub type Value {
  Object(List(#(String, Value)))
  Array(List(Value))
  String(String)
  Int(Int)
  Float(Float)
  Bool(Bool)
  Null
}

/// Decode any JSON value. Object keys come back sorted, since the order is
/// lost when JSON is decoded.
pub fn value_decoder() -> Decoder(Value) {
  use <- decode.recursive
  decode.one_of(decode.string |> decode.map(String), [
    decode.int |> decode.map(Int),
    decode.float |> decode.map(Float),
    decode.bool |> decode.map(Bool),
    decode.list(value_decoder()) |> decode.map(Array),
    decode.dict(decode.string, value_decoder())
      |> decode.map(fn(fields) {
        dict.to_list(fields)
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
        |> Object
      }),
    decode.success(Null),
  ])
}

/// JSON text indented by two spaces.
pub fn pretty(value: Value) -> String {
  indent(value, "")
}

fn indent(value: Value, at: String) -> String {
  let inner = at <> "  "
  case value {
    Object([]) -> "{}"
    Array([]) -> "[]"
    Object(fields) ->
      "{\n"
      <> list.map(fields, fn(field) {
        inner <> quote(field.0) <> ": " <> indent(field.1, inner)
      })
      |> string.join(",\n")
      <> "\n"
      <> at
      <> "}"
    Array(items) ->
      "[\n"
      <> list.map(items, fn(item) { inner <> indent(item, inner) })
      |> string.join(",\n")
      <> "\n"
      <> at
      <> "]"
    String(text) -> quote(text)
    Int(number) -> int.to_string(number)
    Float(number) -> float.to_string(number)
    Bool(True) -> "true"
    Bool(False) -> "false"
    Null -> "null"
  }
}

fn quote(text: String) -> String {
  json.to_string(json.string(text))
}

/// Pretty-print JSON text, or give it back unchanged if it is not JSON.
pub fn pretty_text(text: String) -> String {
  case json.parse(text, value_decoder()) {
    Ok(value) -> pretty(value)
    Error(_) -> text
  }
}

/// An example value for a schema: its own example if it has one, or else
/// one made up from its type and constraints.
pub fn example(document: Document, schema: Dynamic) -> Value {
  sample(document, schema, 0)
}

fn sample(document: Document, schema: Dynamic, depth: Int) -> Value {
  let own =
    decode.run(schema, decode.at(["examples"], decode.list(value_decoder())))
  case own, reference(schema), depth > 6 {
    Ok([value, ..]), _, _ -> value
    _, _, True -> Null
    _, Some(_), _ -> sample(document, resolve(document, schema), depth + 1)
    _, None, False -> made_up(document, schema, depth)
  }
}

fn made_up(document: Document, schema: Dynamic, depth: Int) -> Value {
  let kind = string_at(schema, "type")
  case list_at(schema, "enum"), list_at(schema, "anyOf"), kind {
    [first, ..], _, _ -> result.unwrap(decode.run(first, value_decoder()), Null)
    _, options, _ if options != [] ->
      list.find(options, fn(option) { string_at(option, "type") != Ok("null") })
      |> result.map(sample(document, _, depth + 1))
      |> result.unwrap(Null)
    _, _, Ok("object") ->
      properties(document, schema)
      |> list.map(fn(property) {
        #(property.0, sample(document, property.1, depth + 1))
      })
      |> Object
    _, _, Ok("array") ->
      case decode.run(schema, decode.at(["items"], decode.dynamic)) {
        Ok(items) -> Array([sample(document, items, depth + 1)])
        Error(_) -> Array([])
      }
    _, _, Ok("string") ->
      case string_at(schema, "format") {
        Ok("email") -> String("user@example.com")
        Ok("date-time") -> String("2026-01-01T00:00:00Z")
        Ok("date") -> String("2026-01-01")
        Ok("uuid") -> String("00000000-0000-0000-0000-000000000000")
        _ -> String("string")
      }
    _, _, Ok("integer") ->
      decode.run(schema, decode.at(["minimum"], decode.int))
      |> result.unwrap(0)
      |> Int
    _, _, Ok("number") -> Float(0.0)
    _, _, Ok("boolean") -> Bool(False)
    _, _, _ -> Null
  }
}

/// A single value a parameter should start with, such as the only value of
/// a version header's enum.
pub fn preset(schema: Option(Dynamic)) -> String {
  case option.map(schema, list_at(_, "enum")) {
    Some([only]) -> show(only)
    _ -> ""
  }
}

/// Whether a parameter schema is an array, sent as repeated keys.
pub fn is_array(schema: Option(Dynamic)) -> Bool {
  case schema {
    Some(schema) -> string_at(schema, "type") == Ok("array")
    None -> False
  }
}

/// The `enum` values of a parameter, to offer as a choice.
pub fn choices(schema: Option(Dynamic)) -> List(String) {
  case schema {
    Some(schema) -> list.map(list_at(schema, "enum"), show)
    None -> []
  }
}

/// Where a document says its JSON responses are, if not `application/json`:
/// a vendor media type, used to ask for a version with `accept`.
pub fn accept_for(operation: Operation) -> String {
  list.find_map(operation.responses, fn(reply) {
    case reply.media_type {
      Some(media_type) ->
        case string.starts_with(reply.status, "2") {
          True -> Ok(media_type)
          False -> Error(Nil)
        }
      None -> Error(Nil)
    }
  })
  |> result.unwrap("application/json")
}
