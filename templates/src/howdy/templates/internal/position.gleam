//// LSP positions are a line and a UTF-16 column; templates and modules are
//// indexed by byte. These convert between the two.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// The byte offset of a line and UTF-16 column. Past the end of a line
/// clamps to the line's end.
pub fn to_offset(text: String, line: Int, column: Int) -> Int {
  to_offset_loop(string.to_utf_codepoints(text), line, column, 0)
}

fn to_offset_loop(
  codepoints: List(UtfCodepoint),
  line: Int,
  column: Int,
  offset: Int,
) -> Int {
  case codepoints {
    [] -> offset
    [cp, ..rest] -> {
      let n = string.utf_codepoint_to_int(cp)
      case line, column {
        0, 0 -> offset
        0, _ if n == 10 -> offset
        0, _ -> to_offset_loop(rest, 0, column - utf16(n), offset + utf8(n))
        _, _ if n == 10 -> to_offset_loop(rest, line - 1, column, offset + 1)
        _, _ -> to_offset_loop(rest, line, column, offset + utf8(n))
      }
    }
  }
}

/// The line and UTF-16 column of a byte offset.
pub fn from_offset(text: String, offset: Int) -> #(Int, Int) {
  from_offset_loop(string.to_utf_codepoints(text), offset, 0, 0)
}

fn from_offset_loop(
  codepoints: List(UtfCodepoint),
  offset: Int,
  line: Int,
  column: Int,
) -> #(Int, Int) {
  case codepoints {
    [cp, ..rest] if offset > 0 -> {
      let n = string.utf_codepoint_to_int(cp)
      case n {
        10 -> from_offset_loop(rest, offset - 1, line + 1, 0)
        _ -> from_offset_loop(rest, offset - utf8(n), line, column + utf16(n))
      }
    }
    _ -> #(line, column)
  }
}

fn utf8(n: Int) -> Int {
  case n {
    _ if n < 0x80 -> 1
    _ if n < 0x800 -> 2
    _ if n < 0x10000 -> 3
    _ -> 4
  }
}

fn utf16(n: Int) -> Int {
  case n < 0x10000 {
    True -> 1
    False -> 2
  }
}

/// The text of the line an offset is on, and the offset that line starts at.
pub fn line_at(text: String, offset: Int) -> #(String, Int) {
  let #(line, _) = from_offset(text, offset)
  let start = to_offset(text, line, 0)
  let line_text =
    text
    |> string.split("\n")
    |> list.drop(line)
    |> list.first
    |> result.unwrap("")
    |> string.replace("\r", "")
  #(line_text, start)
}

/// Columns in characters, as compiler messages count them: the UTF-16
/// column with astral characters counted once.
pub fn character_column(text: String, offset: Int) -> Int {
  let #(line, start) = line_at(text, offset)
  let before = <<line:utf8>>
  case
    bit_array.slice(
      before,
      0,
      int.min(offset - start, bit_array.byte_size(before)),
    )
  {
    Ok(bytes) ->
      case bit_array.to_string(bytes) {
        Ok(prefix) -> string.length(prefix)
        Error(_) -> 0
      }
    Error(_) -> 0
  }
}

/// The byte offset of a 1-based line and character column.
pub fn from_line_and_character(text: String, line: Int, column: Int) -> Int {
  let start = to_offset(text, line - 1, 0)
  let #(line_text, _) = line_at(text, start)
  let prefix = string.slice(line_text, 0, column - 1)
  start + string.byte_size(prefix)
}
