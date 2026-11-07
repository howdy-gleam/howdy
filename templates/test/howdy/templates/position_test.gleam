import howdy/templates/internal/position

// é is two bytes and one UTF-16 unit; 😀 is four bytes and two units.
const text = "aé😀b\nsecond\n"

pub fn line_and_column_to_offset_test() {
  assert position.to_offset(text, 0, 0) == 0
  assert position.to_offset(text, 0, 2) == 3
  assert position.to_offset(text, 0, 4) == 7
  assert position.to_offset(text, 1, 3) == 12
  // Past the end of a line stays on the line.
  assert position.to_offset(text, 0, 99) == 8
}

pub fn offset_to_line_and_column_test() {
  assert position.from_offset(text, 0) == #(0, 0)
  assert position.from_offset(text, 3) == #(0, 2)
  assert position.from_offset(text, 7) == #(0, 4)
  assert position.from_offset(text, 12) == #(1, 3)
}

pub fn the_line_at_an_offset_test() {
  assert position.line_at(text, 12) == #("second", 9)
  assert position.line_at("one\r\ntwo", 1) == #("one", 0)
}

pub fn columns_in_characters_test() {
  // The emoji counts once, as it does in compiler messages.
  assert position.character_column(text, 7) == 3
  assert position.character_column(text, 12) == 3
  assert position.from_line_and_character(text, 1, 4) == 7
  assert position.from_line_and_character(text, 2, 4) == 12
}
