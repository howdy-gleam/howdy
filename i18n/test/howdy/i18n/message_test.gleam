import howdy/i18n/internal/message.{
  Argument, Category, Date, Exact, Integer, Number, Percent, Plural, Pound,
  Select, Text, Time,
}

pub fn text_and_arguments_test() {
  assert message.parse("Hello, {name}!")
    == Ok([Text("Hello, "), Argument("name"), Text("!")])
  assert message.parse("") == Ok([])
  assert message.parse("{ name }") == Ok([Argument("name")])
}

pub fn typed_arguments_test() {
  assert message.parse("{n, number}") == Ok([Number("n", Integer)])
  assert message.parse("{n, number, integer}") == Ok([Number("n", Integer)])
  assert message.parse("{r, number, percent}") == Ok([Number("r", Percent)])
  assert message.parse("{d, date}") == Ok([Date("d", "medium")])
  assert message.parse("{d, date, full}") == Ok([Date("d", "full")])
  assert message.parse("{t, time, short}") == Ok([Time("t", "short")])
}

pub fn plurals_test() {
  assert message.parse("{n, plural, =0 {none} one {# thing} other {# things}}")
    == Ok([
      Plural("n", False, 0, [
        #(Exact(0), [Text("none")]),
        #(Category("one"), [Pound("n", 0), Text(" thing")]),
        #(Category("other"), [Pound("n", 0), Text(" things")]),
      ]),
    ])
  assert message.parse("{n, plural, offset:1 other {# more}}")
    == Ok([
      Plural("n", False, 1, [
        #(Category("other"), [Pound("n", 1), Text(" more")]),
      ]),
    ])
  assert message.parse("{n, selectordinal, other {#th}}")
    == Ok([
      Plural("n", True, 0, [#(Category("other"), [Pound("n", 0), Text("th")])]),
    ])
}

pub fn pound_outside_a_plural_is_text_test() {
  assert message.parse("#1") == Ok([Text("#1")])
}

pub fn nested_test() {
  assert message.parse(
      "{g, select, female {{n, plural, one {her item} other {her # items}}} other {theirs}}",
    )
    == Ok([
      Select("g", [
        #("female", [
          Plural("n", False, 0, [
            #(Category("one"), [Text("her item")]),
            #(Category("other"), [Text("her "), Pound("n", 0), Text(" items")]),
          ]),
        ]),
        #("other", [Text("theirs")]),
      ]),
    ])
}

pub fn apostrophes_test() {
  assert message.parse("It''s") == Ok([Text("It's")])
  assert message.parse("It's") == Ok([Text("It's")])
  assert message.parse("'{name}'") == Ok([Text("{name}")])
  assert message.parse("a '{' b") == Ok([Text("a { b")])
  assert message.parse("{n, plural, other {'#' is #}}")
    == Ok([
      Plural("n", False, 0, [
        #(Category("other"), [Text("# is "), Pound("n", 0)]),
      ]),
    ])
}

pub fn errors_test() {
  let assert Error(_) = message.parse("{name")
  let assert Error(_) = message.parse("name}")
  let assert Error(_) = message.parse("{}")
  let assert Error(_) = message.parse("{n, plural, one {x}}")
  let assert Error(_) = message.parse("{n, select, a {x}}")
  let assert Error(_) = message.parse("{n, plural, lots {x} other {y}}")
  let assert Error(_) = message.parse("{n, number, currency}")
  let assert Error(_) = message.parse("{d, date, sometime}")
  let assert Error(_) = message.parse("{n, wibble}")
  Nil
}

pub fn offsets_need_a_number_test() {
  assert message.parse("{n, plural, offset: other {#}}")
    == Error("offset: needs a non-negative whole number")
  assert message.parse("{n, plural, offset:-1 other {#}}")
    == Error("offset: needs a non-negative whole number")
}

pub fn case_selectors_must_be_unique_test() {
  assert message.parse("{n, plural, one {a} one {b} other {c}}")
    == Error("duplicate case one")
  assert message.parse("{n, plural, =0 {a} =0 {b} other {c}}")
    == Error("duplicate case =0")
  assert message.parse("{g, select, a {one} a {two} other {three}}")
    == Error("duplicate case a")
}
