//// What is wrong with one field of some input.
////
//// Rules in `howdy/validate` and `howdy/form` report a `Problem` rather
//// than a sentence, so the words can be chosen later, in the reader's
//// language. JSON error responses carry each problem's `code` and its
//// details, such as `maximum`, with an English `message`; a client can
//// translate by code, and a page rendered on the server can use `message`
//// with words for its locale:
////
//// ```gleam
//// let words = problem.translated(locale)
//// form.error(errors, "name") |> option.map(problem.message(_, words))
//// ```
////
//// `translated` covers the locales Howdy ships words for; build a
//// `Messages` of your own for any other, or to change a few words:
//// `problem.Messages(..problem.english(), required: "can't be blank")`.

import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/result
import gleam/string
import howdy/locale.{type Locale}
import howdy/problem/translations

pub type Problem {
  /// Nothing was given.
  Required
  /// The field was given more than once.
  Repeated
  /// The text is empty.
  Blank
  /// The text has fewer than `minimum` characters.
  TooShort(minimum: Int)
  /// The text has more than `maximum` characters.
  TooLong(maximum: Int)
  /// The number is less than `minimum`.
  TooSmall(minimum: Int)
  /// The number is more than `maximum`.
  TooLarge(maximum: Int)
  /// The text is not an email address.
  NotEmail
  /// The text is not a whole number.
  NotInteger
  /// The value is not one of `allowed`.
  NotOneOf(allowed: List(String))
  /// The list has fewer than `minimum` items.
  TooFewItems(minimum: Int)
  /// The list has more than `maximum` items.
  TooManyItems(maximum: Int)
  /// The file has more than `maximum` bytes.
  FileTooLarge(maximum: Int)
  /// The file's type is not one of `allowed`, such as `image/*`.
  FileType(allowed: List(String))
  /// Anything else. `code` is for clients and `message` for people, such as
  /// `Custom("taken", "is already taken")`.
  Custom(code: String, message: String)
}

/// A short stable name for the problem, sent to clients as `code`.
pub fn code(problem: Problem) -> String {
  case problem {
    Required -> "required"
    Repeated -> "repeated"
    Blank -> "blank"
    TooShort(_) -> "too_short"
    TooLong(_) -> "too_long"
    TooSmall(_) -> "too_small"
    TooLarge(_) -> "too_large"
    NotEmail -> "email"
    NotInteger -> "integer"
    NotOneOf(_) -> "one_of"
    TooFewItems(_) -> "too_few_items"
    TooManyItems(_) -> "too_many_items"
    FileTooLarge(_) -> "file_too_large"
    FileType(_) -> "file_type"
    Custom(code:, ..) -> code
  }
}

/// The words for each problem. Each describes the field, as in "Name must
/// not be empty", and so starts in lower case in English.
pub type Messages {
  Messages(
    required: String,
    repeated: String,
    blank: String,
    too_short: fn(Int) -> String,
    too_long: fn(Int) -> String,
    too_small: fn(Int) -> String,
    too_large: fn(Int) -> String,
    email: String,
    integer: String,
    one_of: fn(List(String)) -> String,
    too_few_items: fn(Int) -> String,
    too_many_items: fn(Int) -> String,
    file_too_large: fn(String) -> String,
    file_type: fn(List(String)) -> String,
  )
}

/// The messages in English.
pub fn english() -> Messages {
  messages_for("en")
}

/// The messages for a locale, or for the nearest one Howdy has words for,
/// falling back to English. These were machine translated and are waiting
/// for review by native speakers.
pub fn translated(locale: Locale) -> Messages {
  let tag =
    locale.fallbacks(locale)
    |> list.map(locale.to_string)
    |> list.find(list.contains(translations.locales, _))
    |> result.unwrap("en")
  messages_for(tag)
}

fn messages_for(tag: String) -> Messages {
  Messages(
    required: translations.required(tag),
    repeated: translations.repeated(tag),
    blank: translations.blank(tag),
    too_short: fn(minimum) { translations.too_short(tag, minimum:) },
    too_long: fn(maximum) { translations.too_long(tag, maximum:) },
    too_small: fn(minimum) { translations.too_small(tag, minimum:) },
    too_large: fn(maximum) { translations.too_large(tag, maximum:) },
    email: translations.email(tag),
    integer: translations.integer(tag),
    one_of: fn(allowed) { translations.one_of(tag, allowed: join(allowed)) },
    too_few_items: fn(minimum) { translations.too_few_items(tag, minimum:) },
    too_many_items: fn(maximum) { translations.too_many_items(tag, maximum:) },
    file_too_large: fn(maximum) { translations.file_too_large(tag, maximum:) },
    file_type: fn(allowed) {
      translations.file_type(tag, allowed: join(allowed))
    },
  )
}

/// The locales `translated` has words for.
pub fn locales() -> List(String) {
  translations.locales
}

/// The message for a problem.
pub fn message(problem: Problem, messages: Messages) -> String {
  case problem {
    Required -> messages.required
    Repeated -> messages.repeated
    Blank -> messages.blank
    TooShort(minimum) -> messages.too_short(minimum)
    TooLong(maximum) -> messages.too_long(maximum)
    TooSmall(minimum) -> messages.too_small(minimum)
    TooLarge(maximum) -> messages.too_large(maximum)
    NotEmail -> messages.email
    NotInteger -> messages.integer
    NotOneOf(allowed) -> messages.one_of(allowed)
    TooFewItems(minimum) -> messages.too_few_items(minimum)
    TooManyItems(maximum) -> messages.too_many_items(maximum)
    FileTooLarge(maximum) -> messages.file_too_large(describe_size(maximum))
    FileType(allowed) -> messages.file_type(allowed)
    Custom(message:, ..) -> message
  }
}

/// The JSON fields describing a problem: `code`, an English `message`, and
/// the details the code needs, such as `maximum` or `allowed`.
pub fn to_json_fields(problem: Problem) -> List(#(String, Json)) {
  let details = case problem {
    TooShort(minimum) | TooSmall(minimum) | TooFewItems(minimum) -> [
      #("minimum", json.int(minimum)),
    ]
    TooLong(maximum)
    | TooLarge(maximum)
    | TooManyItems(maximum)
    | FileTooLarge(maximum) -> [#("maximum", json.int(maximum))]
    NotOneOf(allowed) | FileType(allowed) -> [
      #("allowed", json.array(allowed, json.string)),
    ]
    _ -> []
  }
  [
    #("code", json.string(code(problem))),
    #("message", json.string(message(problem, english()))),
    ..details
  ]
}

/// Read back the fields `to_json_fields` writes. An unknown code, or one
/// without the details it needs, becomes `Custom` with the message sent.
pub fn decoder() -> Decoder(Problem) {
  use code <- decode.field("code", decode.string)
  use message <- decode.field("message", decode.string)
  let custom = decode.success(Custom(code:, message:))
  let int_field = fn(name, make) {
    decode.one_of(
      decode.field(name, decode.int, fn(value) { decode.success(make(value)) }),
      [custom],
    )
  }
  let list_field = fn(make) {
    decode.one_of(
      decode.field("allowed", decode.list(decode.string), fn(value) {
        decode.success(make(value))
      }),
      [custom],
    )
  }
  case code {
    "required" -> decode.success(Required)
    "repeated" -> decode.success(Repeated)
    "blank" -> decode.success(Blank)
    "too_short" -> int_field("minimum", TooShort)
    "too_long" -> int_field("maximum", TooLong)
    "too_small" -> int_field("minimum", TooSmall)
    "too_large" -> int_field("maximum", TooLarge)
    "email" -> decode.success(NotEmail)
    "integer" -> decode.success(NotInteger)
    "one_of" -> list_field(NotOneOf)
    "too_few_items" -> int_field("minimum", TooFewItems)
    "too_many_items" -> int_field("maximum", TooManyItems)
    "file_too_large" -> int_field("maximum", FileTooLarge)
    "file_type" -> list_field(FileType)
    _ -> custom
  }
}

/// A size in bytes as people write it: `5 MB`, `512 KB` or `1500 bytes`.
pub fn describe_size(bytes: Int) -> String {
  let in = fn(unit, name) {
    case bytes >= unit && bytes % unit == 0 {
      True -> Ok(int.to_string(bytes / unit) <> " " <> name)
      False -> Error(Nil)
    }
  }
  in(1_048_576, "MB")
  |> result.lazy_or(fn() { in(1_000_000, "MB") })
  |> result.lazy_or(fn() { in(1024, "KB") })
  |> result.lazy_or(fn() { in(1000, "KB") })
  |> result.unwrap(int.to_string(bytes) <> " bytes")
}

fn join(items: List(String)) -> String {
  string.join(items, ", ")
}
