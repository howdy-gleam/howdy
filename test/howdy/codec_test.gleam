import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import howdy/codec

pub fn codecs_round_trip_test() {
  let round_trip = fn(codec: codec.Codec(a), value: a) {
    codec.from_string(codec, codec.to_string(codec, value))
  }
  assert round_trip(codec.int(), 3) == Ok(3)
  assert round_trip(codec.float(), 1.5) == Ok(1.5)
  assert round_trip(codec.bool(), True) == Ok(True)
  assert round_trip(codec.string(), "hi") == Ok("hi")
  assert round_trip(codec.nil(), Nil) == Ok(Nil)
  assert round_trip(codec.list(codec.int()), [1, 2]) == Ok([1, 2])
  assert round_trip(codec.optional(codec.int()), Some(1)) == Ok(Some(1))
  assert round_trip(codec.optional(codec.int()), None) == Ok(None)
}

type UserId {
  UserId(Int)
}

pub fn map_converts_both_ways_test() {
  let ids =
    codec.map(
      codec.int(),
      from: fn(id) {
        let UserId(id) = id
        id
      },
      to: UserId,
    )
  assert codec.to_string(ids, UserId(7)) == "7"
  assert codec.from_string(ids, "7") == Ok(UserId(7))
}

pub fn new_pairs_an_encoder_with_a_decoder_test() {
  let pair =
    codec.new(
      encode: fn(pair: #(Int, String)) {
        json.preprocessed_array([json.int(pair.0), json.string(pair.1)])
      },
      decoder: {
        use first <- decode.field(0, decode.int)
        use second <- decode.field(1, decode.string)
        decode.success(#(first, second))
      },
    )
  assert codec.to_string(pair, #(1, "a")) == "[1,\"a\"]"
  assert codec.from_string(pair, "[1,\"a\"]") == Ok(#(1, "a"))
  let assert Error(_) = codec.from_string(pair, "{}")
}
