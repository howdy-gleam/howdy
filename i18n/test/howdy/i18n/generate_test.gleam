import gleam/list
import gleam/option.{None}
import gleam/string
import howdy/i18n/internal/catalogue.{Catalogue}
import howdy/i18n/internal/generate

fn options() {
  generate.Options(source: "en", standalone: False, origin: "locales")
}

fn catalogue(locale: String, messages: List(#(String, String))) {
  Catalogue(locale:, file: locale <> ".json", messages:, review: None)
}

fn errors(catalogues) {
  generate.check(catalogues, options()).errors
}

pub fn needs_the_source_test() {
  let assert [error] = errors([catalogue("de", [#("a", "A")])])
  assert string.contains(error, "en.json")
}

pub fn parse_errors_are_reported_test() {
  assert errors([catalogue("en", [#("a", "{oops")])])
    == ["en.json: a: expected } or , after the argument name oops"]
}

pub fn arguments_must_agree_test() {
  let source = catalogue("en", [#("a", "{n, plural, other {#}}")])
  assert errors([source, catalogue("de", [#("a", "{n, date}")])])
    == ["a: {n} is used as a whole number and as a date; it must have one type"]
  assert errors([source, catalogue("de", [#("a", "{n} {m}")])])
    == ["de.json: a: uses {m}, which the en message does not"]
}

pub fn function_names_must_not_clash_test() {
  let assert [error] =
    errors([catalogue("en", [#("cart.items", "A"), #("cartItems", "B")])])
  assert string.contains(error, "cart_items")
}

pub fn function_names_test() {
  assert generate.function_name("cart.items") == "cart_items"
  assert generate.function_name("signIn") == "sign_in"
  assert generate.function_name("HTTPError") == "httperror"
  assert generate.function_name("nav-home") == "nav_home"
  assert generate.function_name("type") == "message_type"
  assert generate.function_name("404") == "message_404"
}

pub fn warnings_test() {
  let report =
    generate.check(
      [
        catalogue("en", [#("a", "A"), #("b", "{n, plural, one {#} other {#}}")]),
        catalogue("pl", [#("b", "{n, plural, one {#} other {#}}"), #("c", "C")]),
      ],
      options(),
    )
  assert report.errors == []
  assert list.length(report.warnings) == 4
  let assert [missing, extra, few, many] = report.warnings
  assert string.contains(missing, "missing 1 message")
  assert string.contains(extra, "ignored: c")
  assert string.contains(few, "no few case")
  assert string.contains(many, "no many case")
}

pub fn standalone_limits_test() {
  let report =
    generate.check(
      [
        catalogue("en", [
          #("a", "{d, date}"),
          #("b", "{n, selectordinal, other {#}}"),
        ]),
      ],
      generate.Options(..options(), standalone: True),
    )
  assert list.length(report.errors) >= 2
}

pub fn literal_test() {
  assert generate.literal("a \"b\" \\ c\nd") == "\"a \\\"b\\\" \\\\ c\\nd\""
}

pub fn catalogue_decoding_test() {
  let assert Ok(c) =
    catalogue.decode_catalogue(
      "de",
      "de.json",
      "{\"@@locale\": \"de\", \"@@x-review\": \"machine\", \"a\": {\"b\": \"X\", \"@b\": {\"d\": 1}}, \"@a\": {}}",
    )
  assert c.messages == [#("a.b", "X")]
  assert c.review == option.Some("machine")
  let assert Error(_) =
    catalogue.decode_catalogue("de", "de.json", "{\"@@locale\": \"fr\"}")
  let assert Error(_) = catalogue.decode_catalogue("de", "de.json", "[1]")
  let assert Error(_) =
    catalogue.decode_catalogue("de", "de.json", "{\"a\": 1}")
  Nil
}

pub fn generated_names_must_not_clash_test() {
  let report =
    errors([catalogue("en", [#("source", "Source"), #("locales", "Locales")])])
  assert list.length(report) == 2
  assert list.all(report, string.contains(_, "reserved generated name"))
  let report =
    generate.check(
      [catalogue("en", [#("cardinal.en", "{n, plural, other {#}}")])],
      generate.Options(..options(), standalone: True),
    )
  assert list.length(report.errors) == 1
  assert list.all(report.errors, string.contains(
    _,
    "reserved generated name cardinal_en",
  ))
}

pub fn argument_labels_must_be_valid_and_unique_test() {
  let report =
    errors([
      catalogue("en", [
        #("colliding", "{firstName} {first_name}"),
        #("reserved", "{translator} {translator_}"),
        #("digit", "{0}"),
        #("empty", "{_}"),
      ]),
    ])
  assert list.length(report) == 4
  assert list.contains(
    report,
    "colliding: arguments would share the label first_name",
  )
  assert list.contains(
    report,
    "reserved: arguments would share the label translator_",
  )
  assert list.contains(
    report,
    "digit: the argument label 0_ must start with a letter",
  )
  assert list.contains(
    report,
    "empty: an argument has no letters or digits in its name",
  )
}

pub fn catalogue_locales_must_be_distinct_test() {
  let report =
    errors([
      catalogue("en", [#("greeting", "Hello")]),
      catalogue("zh-TW", [#("greeting", "Hello")]),
      catalogue("zh-Hant-TW", [#("greeting", "Hello")]),
    ])
  let assert [error] = report
  assert string.contains(error, "share the locale zh-Hant-TW")
}

pub fn generated_comments_stay_on_one_line_test() {
  let assert Ok(#(source, _)) =
    generate.generate(
      [
        catalogue("en", [
          #(
            "greeting\npub const injected = 1\n//",
            "Hello\rpub const text_injected = 3\r//",
          ),
        ]),
      ],
      generate.Options(
        ..options(),
        standalone: True,
        origin: "locales\r\npub const header_injected = 2\n////",
      ),
    )
  let definitions =
    string.split(source, "\n")
    |> list.filter(string.starts_with(_, "pub const "))
  assert list.length(definitions) == 2
  assert string.contains(
    source,
    "/// greeting pub const injected = 1 //: Hello pub const text_injected = 3 //",
  )
  assert string.contains(
    source,
    "//// Messages from locales  pub const header_injected = 2 ////, generated",
  )
}

pub fn catalogue_tags_reject_unsafe_characters_test() {
  list.each(
    ["12", "de-CH!", "de-../x", "de-foo_bar", "de-abcdefghi", "de-\n"],
    fn(tag) {
      let report =
        errors([
          catalogue("en", [#("greeting", "Hello")]),
          catalogue(tag, [#("greeting", "Hello")]),
        ])
      assert list.any(report, string.contains(_, "is not named by a locale tag"))
    },
  )
  list.each(["de", "zh-Hant-TW", "es-419", "en-u-ca-gregory"], fn(tag) {
    assert catalogue.valid_locale(tag)
  })
}
