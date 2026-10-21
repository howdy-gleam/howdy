//// An `Outgoing` as an RFC 5322 message: the text an SMTP server receives,
//// the content of an `.eml` file, and what providers such as Amazon SES
//// accept as a raw message.
////
//// Bodies are quoted-printable UTF-8, attachments base64. Headers with
//// non-ASCII text use RFC 2047 encoded words. `Bcc` is left out: those
//// recipients are only in the envelope. Lines end in CRLF.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}
import howdy/mail.{type Address, type Attachment, type Outgoing}

const crlf = "\r\n"

/// The whole message, headers and body.
pub fn encode(outgoing: Outgoing) -> String {
  let headers =
    list.flatten([
      [
        #("Date", date(outgoing.date)),
        #("From", addresses([outgoing.from])),
      ],
      case outgoing.to {
        [] -> []
        to -> [#("To", addresses(to))]
      },
      case outgoing.cc {
        [] -> []
        cc -> [#("Cc", addresses(cc))]
      },
      case outgoing.reply_to {
        Some(address) -> [#("Reply-To", addresses([address]))]
        None -> []
      },
      [
        #("Subject", text_header(outgoing.subject, string.length("Subject: "))),
        #("Message-ID", message_id(outgoing)),
        #("MIME-Version", "1.0"),
      ],
      list.map(outgoing.headers, fn(header) {
        #(header.0, text_header(header.1, string.length(header.0) + 2))
      }),
    ])
  let body = body(outgoing)
  list.map(headers, fn(header) { header.0 <> ": " <> header.1 <> crlf })
  |> string.concat
  <> body
}

/// `<id@domain>`, with the sender's domain.
pub fn message_id(outgoing: Outgoing) -> String {
  let domain = case string.split_once(outgoing.from.email, "@") {
    Ok(#(_, domain)) -> domain
    Error(Nil) -> "localhost"
  }
  "<" <> outgoing.id <> "@" <> domain <> ">"
}

// -- Structure ---------------------------------------------------------------

/// A MIME part: its own headers, then its content after a blank line.
type Part {
  Leaf(headers: List(#(String, String)), content: String)
  Multi(kind: String, parts: List(Part))
}

fn body(outgoing: Outgoing) -> String {
  let #(inline, attached) =
    list.partition(outgoing.attachments, fn(attachment) {
      attachment.content_id != None
    })
  let text =
    option.map(outgoing.text, fn(text) {
      Leaf(
        [
          #("Content-Type", "text/plain; charset=utf-8"),
          #("Content-Transfer-Encoding", "quoted-printable"),
        ],
        quoted_printable(text),
      )
    })
  let html =
    option.map(outgoing.html, fn(html) {
      let part =
        Leaf(
          [
            #("Content-Type", "text/html; charset=utf-8"),
            #("Content-Transfer-Encoding", "quoted-printable"),
          ],
          quoted_printable(html),
        )
      case inline {
        [] -> part
        inline -> Multi("related", [part, ..list.map(inline, attachment_part)])
      }
    })
  let readable = case text, html {
    Some(text), Some(html) -> Multi("alternative", [text, html])
    Some(part), None | None, Some(part) -> part
    // `mail.prepare` requires one of them.
    None, None -> Leaf([#("Content-Type", "text/plain; charset=utf-8")], "")
  }
  let root = case attached {
    [] -> readable
    attached ->
      Multi("mixed", [readable, ..list.map(attached, attachment_part)])
  }
  let #(headers, content) = render(root, outgoing.id, 0)
  list.map(headers, fn(header) { header.0 <> ": " <> header.1 <> crlf })
  |> string.concat
  <> crlf
  <> content
}

/// The headers and content of a part. Boundaries start with `=_`, which
/// quoted-printable and base64 content can never contain.
fn render(
  part: Part,
  id: String,
  depth: Int,
) -> #(List(#(String, String)), String) {
  case part {
    Leaf(headers, content) -> #(headers, content)
    Multi(kind, parts) -> {
      let boundary = "=_howdy_" <> id <> "_" <> int.to_string(depth)
      let rendered =
        list.index_map(parts, fn(part, index) {
          let #(headers, content) = render(part, id, depth * 10 + index + 1)
          "--"
          <> boundary
          <> crlf
          <> {
            list.map(headers, fn(header) {
              header.0 <> ": " <> header.1 <> crlf
            })
            |> string.concat
          }
          <> crlf
          <> content
          <> crlf
        })
        |> string.concat
      #(
        [
          #(
            "Content-Type",
            "multipart/" <> kind <> "; boundary=\"" <> boundary <> "\"",
          ),
        ],
        rendered <> "--" <> boundary <> "--" <> crlf,
      )
    }
  }
}

fn attachment_part(attachment: Attachment) -> Part {
  let disposition = case attachment.content_id {
    Some(_) -> "inline"
    None -> "attachment"
  }
  Leaf(
    list.flatten([
      [
        #(
          "Content-Type",
          attachment.content_type
            <> "; "
            <> parameter("name", attachment.filename),
        ),
        #("Content-Transfer-Encoding", "base64"),
        #(
          "Content-Disposition",
          disposition <> "; " <> parameter("filename", attachment.filename),
        ),
      ],
      case attachment.content_id {
        Some(id) -> [#("Content-ID", "<" <> id <> ">")]
        None -> []
      },
    ]),
    base64_lines(attachment.content),
  )
}

/// `name="value"`, or RFC 2231 `name*=UTF-8''value` when the value is not
/// plain ASCII.
fn parameter(name: String, value: String) -> String {
  case plain_ascii(value) {
    True -> name <> "=\"" <> quote(value) <> "\""
    False -> name <> "*=UTF-8''" <> percent(bit_array.from_string(value))
  }
}

fn percent(bytes: BitArray) -> String {
  case bytes {
    <<byte, rest:bytes>> ->
      case
        { byte >= 48 && byte <= 57 }
        || { byte >= 65 && byte <= 90 }
        || { byte >= 97 && byte <= 122 }
        || byte == 45
        || byte == 46
        || byte == 95
      {
        True -> char(byte)
        False -> "%" <> hex(byte)
      }
      <> percent(rest)
    _ -> ""
  }
}

// -- Headers -----------------------------------------------------------------

/// A comma-separated list of addresses, folded one per line.
pub fn addresses(addresses: List(Address)) -> String {
  list.map(addresses, fn(address) {
    case address.name {
      None -> address.email
      Some(name) -> display_name(name) <> " <" <> address.email <> ">"
    }
  })
  |> string.join("," <> crlf <> " ")
}

/// Letters, digits, spaces and the atom specials pass as they are; other
/// ASCII is quoted; anything else is an encoded word.
fn display_name(name: String) -> String {
  case plain_ascii(name) {
    False -> encoded_words(name)
    True ->
      case atoms(bit_array.from_string(name)) {
        True -> name
        False -> "\"" <> quote(name) <> "\""
      }
  }
}

fn quote(text: String) -> String {
  text |> string.replace("\\", "\\\\") |> string.replace("\"", "\\\"")
}

/// RFC 5322 atext and spaces.
fn atoms(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bytes>> ->
      {
        { byte >= 48 && byte <= 57 }
        || { byte >= 65 && byte <= 90 }
        || { byte >= 97 && byte <= 122 }
        || list.contains(
          [
            32,
            33,
            35,
            36,
            37,
            38,
            39,
            42,
            43,
            45,
            47,
            61,
            63,
            94,
            95,
            96,
            123,
            124,
            125,
            126,
          ],
          byte,
        )
      }
      && atoms(rest)
    _ -> False
  }
}

/// Unstructured header text. ASCII is folded at spaces to keep lines under
/// 78 characters; anything else becomes encoded words. `used` is how much
/// of the first line the header name took.
fn text_header(text: String, used: Int) -> String {
  case plain_ascii(text) {
    True -> fold(string.split(text, " "), used, "")
    False -> encoded_words(text)
  }
}

fn fold(words: List(String), used: Int, acc: String) -> String {
  case words {
    [] -> acc
    [word, ..rest] ->
      case acc {
        "" -> fold(rest, used + string.length(word), word)
        _ ->
          case used + 1 + string.length(word) > 76 {
            True ->
              fold(rest, 1 + string.length(word), acc <> crlf <> " " <> word)
            False ->
              fold(rest, used + 1 + string.length(word), acc <> " " <> word)
          }
      }
  }
}

/// RFC 2047 `=?UTF-8?B?...?=` words of at most 36 bytes of text each, which
/// keeps a line with a header name under 78 characters, split between characters rather than
/// inside one.
fn encoded_words(text: String) -> String {
  chunks(string.to_graphemes(text), <<>>, [])
  |> list.map(fn(chunk) {
    "=?UTF-8?B?" <> bit_array.base64_encode(chunk, True) <> "?="
  })
  |> string.join(crlf <> " ")
}

fn chunks(
  graphemes: List(String),
  current: BitArray,
  done: List(BitArray),
) -> List(BitArray) {
  case graphemes {
    [] ->
      case current {
        <<>> -> list.reverse(done)
        _ -> list.reverse([current, ..done])
      }
    [grapheme, ..rest] -> {
      let bytes = bit_array.from_string(grapheme)
      case bit_array.byte_size(current) + bit_array.byte_size(bytes) > 36 {
        True if current != <<>> -> chunks(rest, bytes, [current, ..done])
        _ -> chunks(rest, bit_array.append(current, bytes), done)
      }
    }
  }
}

/// Printable ASCII and spaces.
fn plain_ascii(text: String) -> Bool {
  plain_bytes(bit_array.from_string(text))
}

fn plain_bytes(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bytes>> -> byte >= 32 && byte < 127 && plain_bytes(rest)
    _ -> False
  }
}

/// `Thu, 25 Sep 2026 10:00:00 +0000`.
pub fn date(at: Timestamp) -> String {
  let #(day, time) = timestamp.to_calendar(at, calendar.utc_offset)
  let month = calendar.month_to_string(day.month) |> string.slice(0, 3)
  weekday(day.year, calendar.month_to_int(day.month), day.day)
  <> ", "
  <> int.to_string(day.day)
  <> " "
  <> month
  <> " "
  <> int.to_string(day.year)
  <> " "
  <> two(time.hours)
  <> ":"
  <> two(time.minutes)
  <> ":"
  <> two(time.seconds)
  <> " +0000"
}

/// Sakamoto's method.
fn weekday(year: Int, month: Int, day: Int) -> String {
  let offsets = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
  let year = case month < 3 {
    True -> year - 1
    False -> year
  }
  let offset = case list.drop(offsets, month - 1) {
    [offset, ..] -> offset
    [] -> 0
  }
  let index = { year + year / 4 - year / 100 + year / 400 + offset + day } % 7
  case index {
    0 -> "Sun"
    1 -> "Mon"
    2 -> "Tue"
    3 -> "Wed"
    4 -> "Thu"
    5 -> "Fri"
    _ -> "Sat"
  }
}

fn two(value: Int) -> String {
  string.pad_start(int.to_string(value), 2, "0")
}

// -- Transfer encodings ------------------------------------------------------

/// RFC 2045 quoted-printable, with CRLF line breaks and lines of at most 76
/// characters.
pub fn quoted_printable(text: String) -> String {
  text
  |> string.replace("\r\n", "\n")
  |> string.replace("\r", "\n")
  |> string.split("\n")
  |> list.map(fn(line) {
    soft_wrap(encode_line(bit_array.from_string(line), []), 0, "")
  })
  |> string.join(crlf)
}

/// Each byte's encoded form. Spaces and tabs are only literal when
/// something follows them on the line.
fn encode_line(bytes: BitArray, acc: List(String)) -> List(String) {
  case bytes {
    <<>> -> list.reverse(acc)
    <<byte>> if byte == 32 || byte == 9 ->
      list.reverse(["=" <> hex(byte), ..acc])
    <<byte, rest:bytes>> -> {
      let encoded = case byte {
        61 -> "=3D"
        32 | 9 -> char(byte)
        _ if byte >= 33 && byte <= 126 -> char(byte)
        _ -> "=" <> hex(byte)
      }
      encode_line(rest, [encoded, ..acc])
    }
    _ -> list.reverse(acc)
  }
}

/// Join encoded pieces, breaking with a soft `=` line end before a line
/// would pass 76 characters. A piece is never split, so `=XX` stays whole.
fn soft_wrap(pieces: List(String), width: Int, acc: String) -> String {
  case pieces {
    [] -> acc
    [piece, ..rest] -> {
      let size = string.length(piece)
      // Leave room for the `=` of a soft break, unless this is the last
      // piece of the line.
      let limit = case rest {
        [] -> 76
        _ -> 75
      }
      case width + size > limit {
        True -> soft_wrap(rest, size, acc <> "=" <> crlf <> piece)
        False -> soft_wrap(rest, width + size, acc <> piece)
      }
    }
  }
}

fn base64_lines(content: BitArray) -> String {
  lines(bit_array.from_string(bit_array.base64_encode(content, True)), [])
  |> string.join(crlf)
}

/// Base64 is ASCII, so slicing bytes is slicing characters.
fn lines(encoded: BitArray, acc: List(String)) -> List(String) {
  case encoded {
    <<line:bytes-size(76), rest:bytes>> if rest != <<>> ->
      lines(rest, [ascii(line), ..acc])
    rest -> list.reverse([ascii(rest), ..acc])
  }
}

fn ascii(bytes: BitArray) -> String {
  case bit_array.to_string(bytes) {
    Ok(text) -> text
    Error(Nil) -> ""
  }
}

fn hex(byte: Int) -> String {
  string.pad_start(int.to_base16(byte), 2, "0")
}

fn char(byte: Int) -> String {
  case bit_array.to_string(<<byte>>) {
    Ok(text) -> text
    Error(Nil) -> ""
  }
}
