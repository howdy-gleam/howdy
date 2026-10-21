//// Schemas describe a JSON value once and give you everything built from
//// that description: the decoder a handler reads it with, the encoder a
//// response writes it with, and the JSON Schema the OpenAPI document shows.
//// Because all three come from one definition, the document cannot drift
//// from what the server really accepts and sends.
////
//// ```gleam
//// import howdy/openapi/schema.{type Schema}
////
//// pub fn user() -> Schema(User) {
////   {
////     use id <- schema.field("id", schema.int(), fn(user: User) { user.id })
////     use name <- schema.field(
////       "name",
////       schema.string() |> schema.max_length(50),
////       fn(user: User) { user.name },
////     )
////     schema.success(User(id:, name:))
////   }
////   |> schema.named("User")
//// }
//// ```
////
//// Objects are built like `gleam/dynamic/decode` decoders, with one extra
//// argument per field: a function reading the field back out of the value,
//// which is what lets the same schema encode.
////
//// To document an object, the fields after each one are found by calling
//// the rest of the chain with a placeholder value, such as `""` or `0`. So
//// keep the chain to `field` calls and a final `success`: code that
//// branches on a field's value only has its placeholder branch documented.
////
//// Constraints such as `max_length` are checked while decoding, and shown
//// in the document as the matching JSON Schema keyword. `rule` runs any
//// `howdy/validate` rule too, but the document cannot show what it checks.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import howdy/problem.{type Problem}
import howdy/validate

/// A JSON value's description, decoder and encoder, for values of type `a`.
pub opaque type Schema(a) {
  Schema(
    node: fn() -> Node,
    decoder: Decoder(a),
    encode: fn(a) -> Json,
    placeholder: fn() -> a,
    text: Text,
    members: fn() -> List(fn(a) -> List(#(String, Json))),
  )
}

/// The JSON Schema of a schema, without its types. What `howdy/openapi`
/// renders into the document.
///
/// A named node is shown as a reference to its component, with `outer`
/// keywords, those added after naming, beside the reference. `kind` is the
/// JSON type, rendered as the `type` keyword; a node that is a choice
/// between others, such as `nullable` or `one_of`, has none.
pub opaque type Node {
  Node(
    kind: Option(String),
    keywords: List(#(String, Json)),
    items: Option(Node),
    values: Option(Node),
    properties: List(#(String, Node)),
    required: List(String),
    any_of: List(Node),
    name: Option(String),
    outer: List(#(String, Json)),
  )
}

/// How a schema reads a value from text, for path, query and header
/// parameters. The text becomes the `Dynamic` the decoder expects.
type Text {
  Single(fn(String) -> Dynamic)
  Repeated(fn(String) -> Dynamic)
}

// -- Primitives --------------------------------------------------------------

pub fn string() -> Schema(String) {
  primitive("string", decode.string, json.string, "", dynamic.string)
}

pub fn int() -> Schema(Int) {
  primitive("integer", decode.int, json.int, 0, fn(text) {
    case int.parse(text) {
      Ok(value) -> dynamic.int(value)
      Error(Nil) -> dynamic.string(text)
    }
  })
}

/// A JSON number. Integers such as `5` are accepted too.
pub fn float() -> Schema(Float) {
  let decoder =
    decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
  primitive("number", decoder, json.float, 0.0, fn(text) {
    case float.parse(text), int.parse(text) {
      Ok(value), _ -> dynamic.float(value)
      _, Ok(value) -> dynamic.float(int.to_float(value))
      _, _ -> dynamic.string(text)
    }
  })
}

/// `true` or `false`. As a parameter, only the text `true` or `false`.
pub fn bool() -> Schema(Bool) {
  primitive("boolean", decode.bool, json.bool, False, fn(text) {
    case text {
      "true" -> dynamic.bool(True)
      "false" -> dynamic.bool(False)
      _ -> dynamic.string(text)
    }
  })
}

fn primitive(
  kind: String,
  decoder: Decoder(a),
  encode: fn(a) -> Json,
  placeholder: a,
  from_text: fn(String) -> Dynamic,
) -> Schema(a) {
  Schema(
    node: fn() { typed(kind, []) },
    decoder:,
    encode:,
    placeholder: fn() { placeholder },
    text: Single(from_text),
    members: fn() { [] },
  )
}

// -- Collections -------------------------------------------------------------

/// A JSON array. As a query parameter, every occurrence of the key, as in
/// `?tag=a&tag=b`.
pub fn list(of inner: Schema(a)) -> Schema(List(a)) {
  Schema(
    node: fn() { Node(..typed("array", []), items: Some(inner.node())) },
    decoder: decode.list(inner.decoder),
    encode: fn(values) { json.array(values, inner.encode) },
    placeholder: fn() { [] },
    text: Repeated(text_reader(inner.text)),
    members: fn() { [] },
  )
}

/// A JSON object used as a map from string keys to values of one schema.
pub fn dict(of inner: Schema(a)) -> Schema(Dict(String, a)) {
  Schema(
    node: fn() { Node(..typed("object", []), values: Some(inner.node())) },
    decoder: decode.dict(decode.string, inner.decoder),
    encode: fn(values) { json.dict(values, fn(key) { key }, inner.encode) },
    placeholder: fn() { dict.new() },
    text: Single(dynamic.string),
    members: fn() { [] },
  )
}

/// A value that may be `null`. For a field that may be left out, use
/// `optional_field` instead.
pub fn nullable(inner: Schema(a)) -> Schema(Option(a)) {
  Schema(
    node: fn() { Node(..leaf([]), any_of: [inner.node(), typed("null", [])]) },
    decoder: decode.optional(inner.decoder),
    encode: fn(value) { json.nullable(value, inner.encode) },
    placeholder: fn() { None },
    text: inner.text,
    members: fn() { [] },
  )
}

/// A string that is the name of one of `variants`, as `name` gives it.
/// Decoding accepts only the listed variants; encoding names any value with
/// `name`, so write it as a `case` over the type and the compiler sees that
/// every variant has a name. Panics if `variants` is empty.
///
/// ```gleam
/// schema.enum([Admin, Member], fn(role) {
///   case role {
///     Admin -> "admin"
///     Member -> "member"
///   }
/// })
/// ```
pub fn enum(variants: List(a), name: fn(a) -> String) -> Schema(a) {
  let assert [first, ..] = variants
    as "howdy/openapi/schema: enum needs at least one variant"
  let named = list.map(variants, fn(variant) { #(name(variant), variant) })
  let names = list.map(named, fn(variant) { variant.0 })
  let message = failure(problem.NotOneOf(names))
  Schema(
    node: fn() { typed("string", [#("enum", json.array(names, json.string))]) },
    decoder: decode.then(decode.string, fn(text) {
      case list.key_find(named, text) {
        Ok(value) -> decode.success(value)
        Error(Nil) -> decode.failure(first, message)
      }
    }),
    encode: fn(value) { json.string(name(value)) },
    placeholder: fn() { first },
    text: Single(dynamic.string),
    members: fn() { [] },
  )
}

/// One of several shapes, each described by its own schema and turned into
/// a variant of one type with `variant`. Decoding tries the variants in
/// order and takes the first that matches, so put the most specific first.
/// Encoding is `encode`, which picks the variant's schema for a value:
/// write it as a `case` over the type, with `schema.to_json`, and the
/// compiler sees that every variant is covered. Shown as `anyOf` over the
/// variants' schemas. Panics if `variants` is empty.
///
/// ```gleam
/// schema.one_of(
///   [
///     schema.variant(circle(), fn(c) { Circle(c) }),
///     schema.variant(square(), fn(s) { Square(s) }),
///   ],
///   encode: fn(shape) {
///     case shape {
///       Circle(c) -> schema.to_json(c, circle())
///       Square(s) -> schema.to_json(s, square())
///     }
///   },
/// )
/// ```
pub fn one_of(
  variants: List(Variant(a)),
  encode encode: fn(a) -> Json,
) -> Schema(a) {
  let assert [first, ..rest] = variants
    as "howdy/openapi/schema: one_of needs at least one variant"
  Schema(
    node: fn() {
      Node(
        ..leaf([]),
        any_of: list.map(variants, fn(variant) { variant.node() }),
      )
    },
    decoder: decode.one_of(
      first.decoder,
      list.map(rest, fn(variant) { variant.decoder }),
    ),
    encode:,
    placeholder: first.placeholder,
    text: Single(dynamic.string),
    members: fn() { [] },
  )
}

/// One shape a `one_of` accepts: `inner` describes and decodes it, and
/// `to` makes the union's value from the decoded one.
pub opaque type Variant(a) {
  Variant(node: fn() -> Node, decoder: Decoder(a), placeholder: fn() -> a)
}

pub fn variant(inner: Schema(b), to to: fn(b) -> a) -> Variant(a) {
  Variant(
    node: inner.node,
    decoder: decode.map(inner.decoder, to),
    placeholder: fn() { to(inner.placeholder()) },
  )
}

// -- Objects -----------------------------------------------------------------

/// A required object field. `get` reads the field from the finished value,
/// for encoding. See the module docs for how chains are built.
pub fn field(
  name: String,
  schema: Schema(a),
  get: fn(r) -> a,
  next: fn(a) -> Schema(r),
) -> Schema(r) {
  let rest = fn() { next(schema.placeholder()) }
  let member = fn(value) { [#(name, schema.encode(get(value)))] }
  object_step(
    rest:,
    property: #(name, schema),
    required: True,
    member:,
    decoder: decode.field(name, schema.decoder, fn(value) {
      next(value).decoder
    }),
  )
}

/// An object field that may be missing or `null`, both of which decode to
/// `None`. `None` is left out when encoding.
pub fn optional_field(
  name: String,
  schema: Schema(a),
  get: fn(r) -> Option(a),
  next: fn(Option(a)) -> Schema(r),
) -> Schema(r) {
  let rest = fn() { next(None) }
  let member = fn(value) {
    case get(value) {
      Some(inner) -> [#(name, schema.encode(inner))]
      None -> []
    }
  }
  object_step(
    rest:,
    property: #(name, schema),
    required: False,
    member:,
    decoder: decode.optional_field(
      name,
      None,
      decode.optional(schema.decoder),
      fn(value) { next(value).decoder },
    ),
  )
}

fn object_step(
  rest rest: fn() -> Schema(r),
  property property: #(String, Schema(a)),
  required required: Bool,
  member member: fn(r) -> List(#(String, Json)),
  decoder decoder: Decoder(r),
) -> Schema(r) {
  let #(name, schema) = property
  let members = fn() { [member, ..rest().members()] }
  Schema(
    node: fn() {
      let object = unnamed(rest().node())
      Node(
        ..object,
        properties: [#(name, schema.node()), ..object.properties],
        required: case required {
          True -> [name, ..object.required]
          False -> object.required
        },
      )
    },
    decoder:,
    encode: fn(value) { encode_object(members(), value) },
    placeholder: fn() { rest().placeholder() },
    text: Single(dynamic.string),
    members:,
  )
}

/// Finish an object with the value built from its fields.
pub fn success(value: r) -> Schema(r) {
  Schema(
    node: fn() { typed("object", []) },
    decoder: decode.success(value),
    encode: fn(_) { json.object([]) },
    placeholder: fn() { value },
    text: Single(dynamic.string),
    members: fn() { [] },
  )
}

fn encode_object(
  members: List(fn(r) -> List(#(String, Json))),
  value: r,
) -> Json {
  json.object(list.flat_map(members, fn(member) { member(value) }))
}

// -- Changing types ----------------------------------------------------------

/// Change the type a schema decodes to and encodes from. Both directions
/// must always succeed; see `try_map` for conversions that can fail.
///
/// ```gleam
/// pub fn user_id() -> Schema(UserId) {
///   schema.int() |> schema.map(to: UserId, from: fn(id) { id.value })
/// }
/// ```
pub fn map(
  schema: Schema(a),
  to to: fn(a) -> b,
  from from: fn(b) -> a,
) -> Schema(b) {
  Schema(
    node: schema.node,
    decoder: decode.map(schema.decoder, to),
    encode: fn(value) { schema.encode(from(value)) },
    placeholder: fn() { to(schema.placeholder()) },
    text: schema.text,
    members: fn() {
      list.map(schema.members(), fn(member) {
        fn(value) { member(from(value)) }
      })
    },
  )
}

/// Like `map`, but decoding can fail with a message such as
/// `"must be a date"`. `placeholder` stands in for the value when the
/// document is built and when decoding fails.
pub fn try_map(
  schema: Schema(a),
  to to: fn(a) -> Result(b, String),
  from from: fn(b) -> a,
  placeholder placeholder: b,
) -> Schema(b) {
  Schema(
    node: schema.node,
    decoder: decode.then(schema.decoder, fn(value) {
      case to(value) {
        Ok(value) -> decode.success(value)
        Error(message) -> decode.failure(placeholder, message)
      }
    }),
    encode: fn(value) { schema.encode(from(value)) },
    placeholder: fn() { placeholder },
    text: schema.text,
    members: fn() {
      list.map(schema.members(), fn(member) {
        fn(value) { member(from(value)) }
      })
    },
  )
}

// -- Constraints -------------------------------------------------------------

pub fn min_length(schema: Schema(String), length: Int) -> Schema(String) {
  constrain(
    schema,
    [#("minLength", json.int(length))],
    validate.min_length(length),
  )
}

pub fn max_length(schema: Schema(String), length: Int) -> Schema(String) {
  constrain(
    schema,
    [#("maxLength", json.int(length))],
    validate.max_length(length),
  )
}

/// At least one character. Shown as `minLength: 1`, with the message
/// `"must not be empty"`.
pub fn not_empty(schema: Schema(String)) -> Schema(String) {
  constrain(schema, [#("minLength", json.int(1))], validate.not_empty())
}

/// The light email check from `howdy/validate`, shown as `format: email`.
pub fn email(schema: Schema(String)) -> Schema(String) {
  constrain(schema, [#("format", json.string("email"))], validate.email())
}

pub fn minimum(schema: Schema(Int), value: Int) -> Schema(Int) {
  constrain(schema, [#("minimum", json.int(value))], validate.min(value))
}

pub fn maximum(schema: Schema(Int), value: Int) -> Schema(Int) {
  constrain(schema, [#("maximum", json.int(value))], validate.max(value))
}

/// `minimum` for a `float`, with the message `"must be at least 0.5"`.
pub fn float_minimum(schema: Schema(Float), value: Float) -> Schema(Float) {
  constrain(
    schema,
    [#("minimum", json.float(value))],
    validate.custom(
      fn(number) { number >=. value },
      problem.Custom("too_small", "must be at least " <> float.to_string(value)),
    ),
  )
}

/// `maximum` for a `float`, with the message `"must be at most 9.5"`.
pub fn float_maximum(schema: Schema(Float), value: Float) -> Schema(Float) {
  constrain(
    schema,
    [#("maximum", json.float(value))],
    validate.custom(
      fn(number) { number <=. value },
      problem.Custom("too_large", "must be at most " <> float.to_string(value)),
    ),
  )
}

/// At least `count` items, shown as `minItems`, with the message
/// `"must have at least 1 item"`.
pub fn min_items(schema: Schema(List(a)), count: Int) -> Schema(List(a)) {
  constrain(
    schema,
    [#("minItems", json.int(count))],
    validate.custom(
      fn(items) { list.length(items) >= count },
      problem.TooFewItems(count),
    ),
  )
}

/// At most `count` items, shown as `maxItems`, with the message
/// `"must have at most 10 items"`.
pub fn max_items(schema: Schema(List(a)), count: Int) -> Schema(List(a)) {
  constrain(
    schema,
    [#("maxItems", json.int(count))],
    validate.custom(
      fn(items) { list.length(items) <= count },
      problem.TooManyItems(count),
    ),
  )
}

/// Run a `howdy/validate` rule while decoding. Rules may change the value,
/// as `validate.trim()` does, and a failing rule reports its problem for
/// the field. The document does not show what a rule checks; add a
/// `description` if clients need to know.
pub fn rule(schema: Schema(a), rule: validate.Rule(a)) -> Schema(a) {
  constrain(schema, [], rule)
}

fn constrain(
  schema: Schema(a),
  keywords: List(#(String, Json)),
  rule: validate.Rule(a),
) -> Schema(a) {
  Schema(
    ..schema,
    node: fn() { add_keywords(schema.node(), keywords) },
    decoder: decode.then(schema.decoder, fn(value) {
      case rule(value) {
        Ok(value) -> decode.success(value)
        Error(problem) -> decode.failure(value, failure(problem))
      }
    }),
  )
}

/// A decode error's `expected` carries only a string, so a failing rule's
/// problem travels in it as JSON behind this prefix, for `problem` to read.
const problem_prefix = "howdy/problem:"

fn failure(problem: Problem) -> String {
  problem_prefix <> json.to_string(json.object(problem.to_json_fields(problem)))
}

/// The problem a decode error from a schema describes. A rule's problem is
/// read back as it was; the decoders' type names become the matching
/// problem; any other text, such as a `try_map` message, is a `Custom`
/// problem with the code `invalid`.
pub fn problem(error: decode.DecodeError) -> Problem {
  let type_error = fn(message) { problem.Custom("type", message) }
  case error.expected {
    "String" -> type_error("must be a string")
    "Int" -> problem.NotInteger
    "Float" -> type_error("must be a number")
    "Bool" -> type_error("must be true or false")
    "List" -> type_error("must be an array")
    "Dict" -> type_error("must be an object")
    "Field" -> problem.Required
    "Nil" -> type_error("must be null")
    expected ->
      case string.split_once(expected, problem_prefix) {
        Ok(#("", encoded)) ->
          json.parse(encoded, problem.decoder())
          |> result.unwrap(problem.Custom("invalid", expected))
        _ -> problem.Custom("invalid", expected)
      }
  }
}

/// The English message for a decode error from a schema.
pub fn message(error: decode.DecodeError) -> String {
  problem.message(problem(error), problem.english())
}

// -- Documentation -----------------------------------------------------------

/// Show the schema once, under `components/schemas/<name>`, and refer to it
/// by name everywhere it is used. Two different schemas with the same name
/// make building the document panic.
pub fn named(schema: Schema(a), name: String) -> Schema(a) {
  Schema(..schema, node: fn() {
    Node(..unnamed(schema.node()), name: Some(name), outer: [])
  })
}

pub fn description(schema: Schema(a), text: String) -> Schema(a) {
  document(schema, "description", json.string(text))
}

/// An example value, encoded with the schema itself.
pub fn example(schema: Schema(a), value: a) -> Schema(a) {
  document(schema, "examples", json.preprocessed_array([schema.encode(value)]))
}

/// A format hint such as `"date-time"` or `"uuid"`. Only documents the
/// value; pair it with `try_map` or `rule` to check it.
pub fn format(schema: Schema(a), name: String) -> Schema(a) {
  document(schema, "format", json.string(name))
}

pub fn deprecated(schema: Schema(a)) -> Schema(a) {
  document(schema, "deprecated", json.bool(True))
}

fn document(schema: Schema(a), key: String, value: Json) -> Schema(a) {
  Schema(..schema, node: fn() { add_keywords(schema.node(), [#(key, value)]) })
}

// -- Using a schema ----------------------------------------------------------

/// Encode a value, for a response body. Pass it to `service.respond` as
/// `schema.to_json(_, user())`.
pub fn to_json(value: a, schema: Schema(a)) -> Json {
  schema.encode(value)
}

/// The decoder for a schema, for reading JSON outside a handler.
pub fn decoder(schema: Schema(a)) -> Decoder(a) {
  schema.decoder
}

/// The JSON Schema of a schema, for `howdy/openapi`.
@internal
pub fn node(schema: Schema(a)) -> Node {
  schema.node()
}

/// A placeholder value, for documenting an endpoint's later inputs.
@internal
pub fn placeholder(schema: Schema(a)) -> a {
  schema.placeholder()
}

/// Decode parameter text. Every occurrence of a key is given; a schema that
/// is not a `list` fails unless there is exactly one.
@internal
pub fn from_text(
  schema: Schema(a),
  values: List(String),
) -> Result(a, List(decode.DecodeError)) {
  let data = case schema.text {
    Repeated(read) -> dynamic.list(list.map(values, read))
    Single(read) ->
      case values {
        [value] -> read(value)
        _ -> dynamic.list(list.map(values, dynamic.string))
      }
  }
  decode.run(data, schema.decoder)
}

/// Whether a schema describes a JSON object.
@internal
pub fn is_object(schema: Schema(a)) -> Bool {
  schema.node().kind == Some("object")
}

/// Whether a parameter schema takes every occurrence of its key.
@internal
pub fn is_repeated(schema: Schema(a)) -> Bool {
  case schema.text {
    Repeated(_) -> True
    Single(_) -> False
  }
}

fn text_reader(text: Text) -> fn(String) -> Dynamic {
  case text {
    Single(read) | Repeated(read) -> read
  }
}

// -- Rendering ---------------------------------------------------------------

/// Named schemas seen while rendering, as their JSON and its text, so a
/// second, different schema with the same name can be caught.
pub opaque type Components {
  Components(schemas: Dict(String, #(Json, String)), order: List(String))
}

@internal
pub fn components() -> Components {
  Components(schemas: dict.new(), order: [])
}

/// The named schemas in the order they were first used.
@internal
pub fn component_list(components: Components) -> List(#(String, Json)) {
  list.reverse(components.order)
  |> list.filter_map(fn(name) {
    dict.get(components.schemas, name)
    |> result.map(fn(entry) { #(name, entry.0) })
  })
}

/// Render a node as JSON Schema, collecting named schemas as components.
@internal
pub fn render(node: Node, components: Components) -> #(Json, Components) {
  case node.name {
    Some(name) -> {
      let #(body, components) = render(unnamed(node), components)
      let text = json.to_string(body)
      let components = case dict.get(components.schemas, name) {
        Ok(#(_, existing)) if existing == text -> components
        Ok(_) ->
          panic as { "howdy/openapi: two different schemas are named " <> name }
        Error(Nil) ->
          Components(
            schemas: dict.insert(components.schemas, name, #(body, text)),
            order: [name, ..components.order],
          )
      }
      let reference = #("$ref", json.string("#/components/schemas/" <> name))
      #(json.object([reference, ..node.outer]), components)
    }
    None -> {
      let Node(
        kind:,
        keywords:,
        items:,
        values:,
        properties:,
        required:,
        any_of:,
        ..,
      ) = node
      let kind = case kind {
        Some(kind) -> [#("type", json.string(kind))]
        None -> []
      }
      let #(items, components) = render_option("items", items, components)
      let #(values, components) =
        render_option("additionalProperties", values, components)
      let #(properties, components) = case properties {
        [] -> #([], components)
        _ -> {
          let #(rendered, components) =
            list.fold(properties, #([], components), fn(acc, property) {
              let #(rendered, components) = acc
              let #(json, components) = render(property.1, components)
              #([#(property.0, json), ..rendered], components)
            })
          #([#("properties", json.object(list.reverse(rendered)))], components)
        }
      }
      let required = case required {
        [] -> []
        _ -> [#("required", json.array(required, json.string))]
      }
      let #(any_of, components) = case any_of {
        [] -> #([], components)
        _ -> {
          let #(rendered, components) =
            list.fold(any_of, #([], components), fn(acc, node) {
              let #(rendered, components) = acc
              let #(json, components) = render(node, components)
              #([json, ..rendered], components)
            })
          #(
            [#("anyOf", json.preprocessed_array(list.reverse(rendered)))],
            components,
          )
        }
      }
      #(
        json.object(
          list.flatten([
            kind,
            keywords,
            items,
            values,
            properties,
            required,
            any_of,
          ]),
        ),
        components,
      )
    }
  }
}

fn render_option(
  key: String,
  node: Option(Node),
  components: Components,
) -> #(List(#(String, Json)), Components) {
  case node {
    Some(node) -> {
      let #(json, components) = render(node, components)
      #([#(key, json)], components)
    }
    None -> #([], components)
  }
}

fn typed(kind: String, keywords: List(#(String, Json))) -> Node {
  Node(..leaf(keywords), kind: Some(kind))
}

fn leaf(keywords: List(#(String, Json))) -> Node {
  Node(
    kind: None,
    keywords:,
    items: None,
    values: None,
    properties: [],
    required: [],
    any_of: [],
    name: None,
    outer: [],
  )
}

/// A named node's own schema: its keywords, with those added after naming
/// kept beside the reference instead.
fn unnamed(node: Node) -> Node {
  Node(..node, name: None, outer: [])
}

fn add_keywords(node: Node, keywords: List(#(String, Json))) -> Node {
  case node.name {
    Some(_) -> Node(..node, outer: list.append(node.outer, keywords))
    None -> Node(..node, keywords: list.append(node.keywords, keywords))
  }
}
