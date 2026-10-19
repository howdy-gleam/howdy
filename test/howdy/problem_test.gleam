import gleam/json
import gleam/list
import howdy/locale
import howdy/problem.{
  Blank, Custom, FileTooLarge, FileType, NotEmail, NotInteger, NotOneOf,
  Repeated, Required, TooFewItems, TooLarge, TooLong, TooManyItems, TooShort,
  TooSmall,
}

const every = [
  Required,
  Repeated,
  Blank,
  TooShort(3),
  TooLong(10),
  TooSmall(1),
  TooLarge(99),
  NotEmail,
  NotInteger,
  NotOneOf(["a", "b"]),
  TooFewItems(1),
  TooManyItems(2),
  FileTooLarge(1_048_576),
  FileType(["image/*"]),
  Custom("taken", "is already taken"),
]

fn words(tag: String) {
  let assert Ok(l) = locale.parse(tag)
  problem.translated(l)
}

pub fn english_messages_test() {
  let en = problem.english()
  assert list.map(every, problem.message(_, en))
    == [
      "is required", "must occur only once", "must not be empty",
      "must be at least 3 characters", "must be at most 10 characters",
      "must be at least 1", "must be at most 99",
      "must be a valid email address", "must be an integer",
      "must be one of a, b", "must have at least 1 item",
      "must have at most 2 items", "must be at most 1 MB",
      "must be one of image/*", "is already taken",
    ]
  assert problem.message(TooShort(1), en) == "must be at least 1 character"
}

pub fn translated_messages_test() {
  assert problem.message(Required, words("de-CH")) == "ist erforderlich"
  assert problem.message(TooShort(5), words("pl"))
    == "musi mieć co najmniej 5 znaków"
  assert problem.message(TooShort(3), words("pl"))
    == "musi mieć co najmniej 3 znaki"
  assert problem.message(TooShort(2), words("ar")) == "يجب ألا يقل عن حرفين"
  assert problem.message(TooLong(8), words("ja")) == "8文字以内で入力してください"
  // Locales without words fall back to English.
  assert problem.message(Required, words("sv")) == "is required"
  // Custom problems keep their own message.
  assert problem.message(Custom("taken", "x"), words("de")) == "x"
}

pub fn locales_test() {
  assert list.contains(problem.locales(), "en")
  assert list.contains(problem.locales(), "zh")
}

pub fn codes_test() {
  assert list.map(every, problem.code)
    == [
      "required", "repeated", "blank", "too_short", "too_long", "too_small",
      "too_large", "email", "integer", "one_of", "too_few_items",
      "too_many_items", "file_too_large", "file_type", "taken",
    ]
}

pub fn json_round_trip_test() {
  list.each(every, fn(p) {
    let text = json.to_string(json.object(problem.to_json_fields(p)))
    assert json.parse(text, problem.decoder()) == Ok(p)
  })
  assert json.to_string(json.object(problem.to_json_fields(TooLong(10))))
    == "{\"code\":\"too_long\",\"message\":\"must be at most 10 characters\",\"maximum\":10}"
}

pub fn decoder_falls_back_to_custom_test() {
  // A known code without its details, as a float limit would send.
  assert json.parse(
      "{\"code\":\"too_small\",\"message\":\"must be at least 0.5\"}",
      problem.decoder(),
    )
    == Ok(Custom("too_small", "must be at least 0.5"))
}

pub fn describe_size_test() {
  assert problem.describe_size(5_242_880) == "5 MB"
  assert problem.describe_size(2000) == "2 KB"
  assert problem.describe_size(1500) == "1500 bytes"
}
