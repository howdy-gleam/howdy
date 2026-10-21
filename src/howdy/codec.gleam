//// How to turn a value into JSON and back, as one value. Anything that
//// stores or sends a value and reads it back later takes a codec: a remote
//// procedure's input and output, or an entry in a cache.
////
//// ```gleam
//// import gleam/dynamic/decode
//// import gleam/json
//// import howdy/codec
////
//// pub fn user_codec() -> codec.Codec(User) {
////   codec.new(
////     encode: fn(user: User) {
////       json.object([#("id", json.int(user.id)), #("name", json.string(user.name))])
////     },
////     decoder: {
////       use id <- decode.field("id", decode.int)
////       use name <- decode.field("name", decode.string)
////       decode.success(User(id:, name:))
////     },
////   )
//// }
//// ```
////
//// The encoder and decoder must agree: decoding what `encode` produced
//// gives back the same value.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}

/// An encoder and the decoder that reads its output back.
pub type Codec(a) {
  Codec(encode: fn(a) -> Json, decoder: Decoder(a))
}

/// A codec from an encoder and a decoder that agree with each other.
pub fn new(
  encode encode: fn(a) -> Json,
  decoder decoder: Decoder(a),
) -> Codec(a) {
  Codec(encode:, decoder:)
}

pub fn int() -> Codec(Int) {
  Codec(encode: json.int, decoder: decode.int)
}

pub fn float() -> Codec(Float) {
  Codec(encode: json.float, decoder: decode.float)
}

pub fn string() -> Codec(String) {
  Codec(encode: json.string, decoder: decode.string)
}

pub fn bool() -> Codec(Bool) {
  Codec(encode: json.bool, decoder: decode.bool)
}

/// For values that carry nothing, such as a procedure with no input.
pub fn nil() -> Codec(Nil) {
  Codec(encode: fn(_) { json.null() }, decoder: decode.success(Nil))
}

pub fn list(of item: Codec(a)) -> Codec(List(a)) {
  Codec(
    encode: fn(items) { json.array(items, item.encode) },
    decoder: decode.list(item.decoder),
  )
}

/// `None` is encoded as `null`.
pub fn optional(of item: Codec(a)) -> Codec(Option(a)) {
  Codec(
    encode: fn(value) { json.nullable(value, item.encode) },
    decoder: decode.optional(item.decoder),
  )
}

/// A codec for `b`, by converting to and from a type that already has one.
///
/// ```gleam
/// codec.map(codec.int(), from: fn(id: UserId) { id.value }, to: UserId)
/// ```
pub fn map(
  codec: Codec(a),
  from from: fn(b) -> a,
  to to: fn(a) -> b,
) -> Codec(b) {
  Codec(
    encode: fn(value) { codec.encode(from(value)) },
    decoder: decode.map(codec.decoder, to),
  )
}

/// The value as a JSON string.
pub fn to_string(codec: Codec(a), value: a) -> String {
  json.to_string(codec.encode(value))
}

/// Read a value back from a JSON string `to_string` produced.
pub fn from_string(
  codec: Codec(a),
  text: String,
) -> Result(a, json.DecodeError) {
  json.parse(text, codec.decoder)
}
