import gleam/list
import howdy/i18n/plural.{Few, Many, One, Other, Two, Zero}

fn cardinals(locale: String, numbers: List(Int)) {
  list.map(numbers, plural.cardinal(locale, _))
}

pub fn english_test() {
  assert cardinals("en", [0, 1, 2, 11, 21]) == [Other, One, Other, Other, Other]
  assert cardinals("en-GB", [1]) == [One]
  assert list.map([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101], plural.ordinal(
      "en",
      _,
    ))
    == [One, Two, Few, Other, Other, Other, Other, One, Two, Few, One]
}

pub fn polish_test() {
  assert cardinals("pl", [1, 2, 4, 5, 12, 14, 21, 22, 25, 112])
    == [One, Few, Few, Many, Many, Many, Many, Few, Many, Many]
}

pub fn arabic_test() {
  assert cardinals("ar", [0, 1, 2, 3, 10, 11, 99, 100, 102])
    == [Zero, One, Two, Few, Few, Many, Many, Other, Other]
}

pub fn french_and_portuguese_test() {
  assert cardinals("fr", [0, 1, 2, 1_000_000]) == [One, One, Other, Many]
  // Portugal differs from Brazil: zero is other.
  assert cardinals("pt", [0, 1]) == [One, One]
  assert cardinals("pt-PT", [0, 1]) == [Other, One]
  assert cardinals("pt_BR", [0]) == [One]
}

pub fn languages_without_plurals_test() {
  assert cardinals("ja", [0, 1, 2]) == [Other, Other, Other]
  assert cardinals("xx", [1]) == [Other]
}

pub fn negative_numbers_use_their_size_test() {
  assert plural.cardinal("en", -1) == One
  assert plural.cardinal("pl", -3) == Few
}

pub fn categories_test() {
  assert plural.cardinal_categories("en") == [One, Other]
  assert plural.cardinal_categories("pl") == [One, Few, Many, Other]
  assert plural.cardinal_categories("ja") == [Other]
  assert plural.cardinal_categories("xx") == [Other]
  assert plural.ordinal_categories("en") == [One, Two, Few, Other]
}

pub fn names_test() {
  assert list.map([Zero, One, Two, Few, Many, Other], plural.to_string)
    == ["zero", "one", "two", "few", "many", "other"]
  assert plural.from_string("few") == Ok(Few)
  assert plural.from_string("lots") == Error(Nil)
}
