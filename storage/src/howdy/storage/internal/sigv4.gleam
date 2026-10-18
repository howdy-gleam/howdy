//// AWS Signature Version 4 for S3: signing a request in its
//// `Authorization` header, and presigning a URL in its query string.
////
//// Paths are given already encoded, one percent-encoding per segment, and
//// are signed exactly as sent, which is what S3 expects. Query values are
//// given raw and encoded here.

import gleam/bit_array
import gleam/crypto
import gleam/http.{type Method}
import gleam/http/request.{type Request, Request}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}
import howdy/storage

pub type Credentials {
  Credentials(
    access_key_id: String,
    secret_access_key: String,
    session_token: Option(String),
    region: String,
  )
}

/// The hash S3 accepts in place of the payload's.
pub const unsigned_payload = "UNSIGNED-PAYLOAD"

/// Sign `request`, whose path is already encoded and whose query is given
/// as raw pairs, adding the headers S3 needs.
pub fn sign(
  request: Request(BitArray),
  query: List(#(String, String)),
  credentials: Credentials,
  now: Timestamp,
) -> Request(BitArray) {
  let #(date, date_time) = stamp(now)
  let payload_hash = hex(crypto.hash(crypto.Sha256, request.body))
  let headers =
    list.flatten([
      [
        #("host", host(request)),
        #("x-amz-date", date_time),
        #("x-amz-content-sha256", payload_hash),
      ],
      case credentials.session_token {
        Some(token) -> [#("x-amz-security-token", token)]
        None -> []
      },
      list.map(request.headers, fn(header) {
        #(string.lowercase(header.0), header.1)
      }),
    ])
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  let signed_headers =
    list.map(headers, fn(header) { header.0 }) |> string.join(";")
  let canonical =
    canonical_request(
      request.method,
      request.path,
      query,
      headers,
      signed_headers,
      payload_hash,
    )
  let signature = signature(credentials, date, date_time, canonical)
  let authorization =
    "AWS4-HMAC-SHA256 Credential="
    <> credentials.access_key_id
    <> "/"
    <> scope(credentials, date)
    <> ",SignedHeaders="
    <> signed_headers
    <> ",Signature="
    <> signature
  Request(
    ..request,
    headers: [#("authorization", authorization), ..headers],
    query: case query {
      [] -> None
      _ -> Some(query_string(query))
    },
  )
}

/// A URL for `method` on `path`, valid for `expires_in` seconds from
/// `now`, carrying its signature in the query.
pub fn presign(
  method: Method,
  scheme: http.Scheme,
  host_name: String,
  port: Option(Int),
  path: String,
  query: List(#(String, String)),
  credentials: Credentials,
  now: Timestamp,
  expires_in: Int,
) -> String {
  let #(date, date_time) = stamp(now)
  let host = host_header(host_name, port)
  let query =
    list.flatten([
      query,
      [
        #("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
        #(
          "X-Amz-Credential",
          credentials.access_key_id <> "/" <> scope(credentials, date),
        ),
        #("X-Amz-Date", date_time),
        #("X-Amz-Expires", int.to_string(expires_in)),
        #("X-Amz-SignedHeaders", "host"),
      ],
      case credentials.session_token {
        Some(token) -> [#("X-Amz-Security-Token", token)]
        None -> []
      },
    ])
  let canonical =
    canonical_request(
      method,
      path,
      query,
      [#("host", host)],
      "host",
      unsigned_payload,
    )
  let signature = signature(credentials, date, date_time, canonical)
  http.scheme_to_string(scheme)
  <> "://"
  <> host
  <> path
  <> "?"
  <> query_string(query)
  <> "&X-Amz-Signature="
  <> signature
}

fn canonical_request(
  method: Method,
  path: String,
  query: List(#(String, String)),
  headers: List(#(String, String)),
  signed_headers: String,
  payload_hash: String,
) -> String {
  string.join(
    [
      string.uppercase(http.method_to_string(method)),
      case path {
        "" -> "/"
        _ -> path
      },
      query_string(query),
      headers
        |> list.map(fn(header) {
          header.0 <> ":" <> trim_value(header.1) <> "\n"
        })
        |> string.concat,
      signed_headers,
      payload_hash,
    ],
    "\n",
  )
}

/// The query encoded and sorted as SigV4 wants, which S3 accepts as sent.
pub fn query_string(query: List(#(String, String))) -> String {
  query
  |> list.map(fn(pair) {
    #(storage.percent_encode(pair.0), storage.percent_encode(pair.1))
  })
  |> list.sort(fn(a, b) {
    case string.compare(a.0, b.0) {
      order.Eq -> string.compare(a.1, b.1)
      other -> other
    }
  })
  |> list.map(fn(pair) { pair.0 <> "=" <> pair.1 })
  |> string.join("&")
}

fn signature(
  credentials: Credentials,
  date: String,
  date_time: String,
  canonical: String,
) -> String {
  let to_sign =
    string.join(
      [
        "AWS4-HMAC-SHA256",
        date_time,
        scope(credentials, date),
        hex(crypto.hash(crypto.Sha256, <<canonical:utf8>>)),
      ],
      "\n",
    )
  let key =
    <<"AWS4":utf8, credentials.secret_access_key:utf8>>
    |> crypto.hmac(<<date:utf8>>, crypto.Sha256, _)
    |> crypto.hmac(<<credentials.region:utf8>>, crypto.Sha256, _)
    |> crypto.hmac(<<"s3":utf8>>, crypto.Sha256, _)
    |> crypto.hmac(<<"aws4_request":utf8>>, crypto.Sha256, _)
  hex(crypto.hmac(<<to_sign:utf8>>, crypto.Sha256, key))
}

fn scope(credentials: Credentials, date: String) -> String {
  date <> "/" <> credentials.region <> "/s3/aws4_request"
}

fn host(request: Request(a)) -> String {
  host_header(request.host, request.port)
}

fn host_header(host: String, port: Option(Int)) -> String {
  case port {
    Some(port) -> host <> ":" <> int.to_string(port)
    None -> host
  }
}

/// Trim a header value and squeeze its runs of spaces to one.
fn trim_value(value: String) -> String {
  value
  |> string.trim
  |> string.split(" ")
  |> list.filter(fn(part) { part != "" })
  |> string.join(" ")
}

/// `#("20130524", "20130524T000000Z")`.
fn stamp(now: Timestamp) -> #(String, String) {
  let #(day, time) = timestamp.to_calendar(now, calendar.utc_offset)
  let pad = fn(n, width) { string.pad_start(int.to_string(n), width, "0") }
  let date =
    pad(day.year, 4)
    <> pad(calendar.month_to_int(day.month), 2)
    <> pad(day.day, 2)
  #(
    date,
    date
      <> "T"
      <> pad(time.hours, 2)
      <> pad(time.minutes, 2)
      <> pad(time.seconds, 2)
      <> "Z",
  )
}

fn hex(bytes: BitArray) -> String {
  bytes |> bit_array.base16_encode |> string.lowercase
}
