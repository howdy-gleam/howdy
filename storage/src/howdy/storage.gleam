//// File storage for Howdy apps: one API for keeping files in an
//// S3-compatible bucket, a local folder, or memory. Each file is an
//// object stored under a key such as `avatars/3f9c….png`.
////
//// ```gleam
//// import howdy/storage
//// import howdy/storage/s3
////
//// let assert Ok(config) = s3.from_env()
//// let files = s3.adapter(config)
////
//// let key = storage.new_key(prefix: "avatars", file_name: upload.file_name)
//// use Nil <- result.try(
////   storage.put_file(files, key, upload.path, content_type: "image/png"),
//// )
//// storage.url(files, key, expires_in: 3600)
//// ```
////
//// `howdy/storage/s3` talks to AWS S3, Cloudflare R2, Tigris, MinIO,
//// Garage and other S3-compatible services. `howdy/storage/local` keeps
//// files in a folder, for development and single-server apps, and serves
//// them through a controller. `howdy/storage/memory` is for tests.
////
//// Every call is synchronous: it waits for the adapter to answer, up to
//// its timeout. Keys are checked before any adapter sees them, so a key
//// that is valid works with every adapter; see `valid_key`.

import filepath
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import howdy/service
import howdy/trace

// -- Objects -----------------------------------------------------------------

/// What is stored under a key, as `head` describes it.
pub type Object {
  Object(
    key: String,
    /// The size in bytes.
    size: Int,
    content_type: String,
    /// Changes whenever the content does. Its format depends on the adapter.
    etag: String,
    last_modified: Timestamp,
  )
}

/// One object in a `Page` from `list`. Listing does not tell the content
/// type; `head` does.
pub type Summary {
  Summary(key: String, size: Int, etag: String, last_modified: Timestamp)
}

/// Some of the objects under a prefix, in key order.
pub type Page {
  Page(
    objects: List(Summary),
    /// When there are more, the key to pass as `after` for the next page.
    next: Option(String),
  )
}

/// The content to store.
pub type Body {
  Bytes(BitArray)
  /// The contents of a file, such as `form.UploadedFile`'s `path`. Adapters
  /// read it in parts, so a large file is not held in memory.
  File(path: String)
}

/// Something to store, built with `write` and stored with `put_with`.
pub opaque type Write {
  Write(
    key: String,
    body: Body,
    content_type: String,
    cache_control: Option(String),
    download_as: Option(String),
  )
}

/// A checked write, as an adapter receives it.
pub type Put {
  Put(
    key: String,
    body: Body,
    content_type: String,
    /// A `Cache-Control` header to serve the object with.
    cache_control: Option(String),
    /// A file name to download the object as, rather than show it.
    download_as: Option(String),
  )
}

/// A signed URL, as an adapter is asked for one.
pub type UrlRequest {
  UrlRequest(
    key: String,
    /// Seconds from now until the URL stops working.
    expires_in: Int,
    /// A file name to download the object as, rather than show it.
    download_as: Option(String),
  )
}

// -- Errors ------------------------------------------------------------------

/// Why a storage call failed.
pub type Error {
  /// Nothing is stored under the key.
  NotFound
  /// The call itself is wrong, such as a key that `valid_key` refuses.
  /// Trying again will not help.
  Invalid(String)
  /// The service could not be reached, timed out or asked to be tried
  /// later. Worth retrying.
  Unavailable(String)
  /// The service refused for good: bad credentials, no permission, or a
  /// bucket that does not exist.
  Refused(String)
}

/// Whether trying again later might work.
pub fn retryable(error: Error) -> Bool {
  case error {
    Unavailable(_) -> True
    NotFound | Invalid(_) | Refused(_) -> False
  }
}

pub fn error_to_string(error: Error) -> String {
  case error {
    NotFound -> "no such object"
    Invalid(reason) -> "invalid storage call: " <> reason
    Unavailable(reason) -> "storage unavailable: " <> reason
    Refused(reason) -> "storage refused: " <> reason
  }
}

/// A service error for a failed call. `NotFound` is a `404`; failures of
/// the service become `Internal`, which is logged and not shown.
pub fn to_service_error(error: Error) -> service.Error {
  case error {
    NotFound -> service.NotFound("file not found")
    Invalid(reason) -> service.Invalid(reason)
    Unavailable(_) | Refused(_) -> service.Internal(error_to_string(error))
  }
}

// -- Adapters ----------------------------------------------------------------

/// Somewhere objects are kept: `howdy/storage/s3`, `howdy/storage/local`,
/// `howdy/storage/memory`, or one of your own.
pub opaque type Storage {
  Storage(
    name: String,
    put: fn(Put) -> Result(Nil, Error),
    get: fn(String) -> Result(BitArray, Error),
    head: fn(String) -> Result(Object, Error),
    delete: fn(String) -> Result(Nil, Error),
    list: fn(String, Option(String), Int) -> Result(Page, Error),
    url: fn(UrlRequest) -> Result(String, Error),
    public_url: Option(fn(String) -> String),
  )
}

/// Storage for a service this package does not cover. Keys and URL
/// requests are checked before these functions see them. `delete` of a
/// missing key succeeds; `list` takes a prefix, the key to start after and
/// the most objects to return, at least 1 and at most 1000.
pub fn adapter(
  named name: String,
  put put: fn(Put) -> Result(Nil, Error),
  get get: fn(String) -> Result(BitArray, Error),
  head head: fn(String) -> Result(Object, Error),
  delete delete: fn(String) -> Result(Nil, Error),
  list list: fn(String, Option(String), Int) -> Result(Page, Error),
  url url: fn(UrlRequest) -> Result(String, Error),
) -> Storage {
  Storage(name:, put:, get:, head:, delete:, list:, url:, public_url: None)
}

/// Give the storage permanent, unsigned URLs, such as through a CDN in
/// front of a public bucket. `public_url` fails without one.
pub fn with_public_url(storage: Storage, url: fn(String) -> String) -> Storage {
  Storage(..storage, public_url: Some(url))
}

pub fn name(storage: Storage) -> String {
  storage.name
}

// -- Writing -----------------------------------------------------------------

/// Store `bytes` under `key`, replacing anything there.
pub fn put(
  storage: Storage,
  key: String,
  bytes: BitArray,
  content_type type_: String,
) -> Result(Nil, Error) {
  put_with(storage, write(key, Bytes(bytes)) |> content_type(type_))
}

/// Store the file at `path` under `key`, replacing anything there. The
/// file is read in parts, so it need not fit in memory.
pub fn put_file(
  storage: Storage,
  key: String,
  path: String,
  content_type type_: String,
) -> Result(Nil, Error) {
  put_with(storage, write(key, File(path)) |> content_type(type_))
}

/// Something to store under `key`, as `application/octet-stream` until
/// `content_type` says otherwise.
pub fn write(key: String, body: Body) -> Write {
  Write(
    key:,
    body:,
    content_type: "application/octet-stream",
    cache_control: None,
    download_as: None,
  )
}

/// The content type to serve the object with.
pub fn content_type(write: Write, content_type: String) -> Write {
  Write(..write, content_type:)
}

/// A `Cache-Control` header to serve the object with, such as
/// `"public, max-age=31536000, immutable"` for a key that never changes.
pub fn cache_control(write: Write, cache_control: String) -> Write {
  Write(..write, cache_control: Some(cache_control))
}

/// Download the object as a file with this name when it is opened, rather
/// than show it in the browser.
pub fn download_as(write: Write, file_name: String) -> Write {
  Write(..write, download_as: Some(file_name))
}

/// Store what `write` describes, replacing anything under its key.
pub fn put_with(storage: Storage, write: Write) -> Result(Nil, Error) {
  let size = case write.body {
    Bytes(bytes) -> [trace.int("storage.bytes", bit_array.byte_size(bytes))]
    File(_) -> []
  }
  use <- traced(storage, "put", write.key, size)
  use Nil <- result.try(check_key(write.key))
  use Nil <- result.try(single_line("content type", write.content_type))
  use Nil <- result.try(case write.cache_control {
    Some(value) -> single_line("cache control", value)
    None -> Ok(Nil)
  })
  use Nil <- result.try(case write.download_as {
    Some(name) -> check_file_name(name)
    None -> Ok(Nil)
  })
  storage.put(Put(
    key: write.key,
    body: write.body,
    content_type: write.content_type,
    cache_control: write.cache_control,
    download_as: write.download_as,
  ))
}

/// Remove the object under `key`. Removing one that is not there succeeds.
pub fn delete(storage: Storage, key: String) -> Result(Nil, Error) {
  use <- traced(storage, "delete", key, [])
  use Nil <- result.try(check_key(key))
  storage.delete(key)
}

// -- Reading -----------------------------------------------------------------

/// The whole content of the object under `key`, in memory. To send a file
/// to a browser, redirect it to a `url` instead.
pub fn get(storage: Storage, key: String) -> Result(BitArray, Error) {
  use <- traced(storage, "get", key, [])
  use Nil <- result.try(check_key(key))
  storage.get(key)
}

/// What is stored under `key`, without its content.
pub fn head(storage: Storage, key: String) -> Result(Object, Error) {
  use <- traced(storage, "head", key, [])
  use Nil <- result.try(check_key(key))
  storage.head(key)
}

/// Whether anything is stored under `key`.
pub fn exists(storage: Storage, key: String) -> Result(Bool, Error) {
  case head(storage, key) {
    Ok(_) -> Ok(True)
    Error(NotFound) -> Ok(False)
    Error(error) -> Error(error)
  }
}

/// Up to `limit` objects whose keys start with `prefix`, in key order,
/// starting after the key `after`. `limit` is kept between 1 and 1000. A
/// prefix is matched as text, so `"avatars/"` finds `avatars/a.png` but
/// `"avatars"` also finds `avatars-old/b.png`.
pub fn list(
  storage: Storage,
  prefix prefix: String,
  after after: Option(String),
  limit limit: Int,
) -> Result(Page, Error) {
  use <- traced(storage, "list", prefix, [])
  storage.list(prefix, after, int.clamp(limit, 1, 1000))
}

// -- URLs --------------------------------------------------------------------

/// The longest a signed URL may last: seven days, the most S3 allows.
pub const max_expiry = 604_800

/// A URL anyone holding it can read the object at, until `expires_in`
/// seconds from now. It is signed, so it cannot be changed to name
/// another object.
pub fn url(
  storage: Storage,
  key: String,
  expires_in expires_in: Int,
) -> Result(String, Error) {
  signed(storage, UrlRequest(key:, expires_in:, download_as: None))
}

/// Like `url`, but the browser downloads the object as `file_name` rather
/// than showing it.
pub fn download_url(
  storage: Storage,
  key: String,
  expires_in expires_in: Int,
  file_name file_name: String,
) -> Result(String, Error) {
  signed(storage, UrlRequest(key:, expires_in:, download_as: Some(file_name)))
}

fn signed(storage: Storage, request: UrlRequest) -> Result(String, Error) {
  use Nil <- result.try(check_key(request.key))
  use <- bool.guard(
    request.expires_in < 1 || request.expires_in > max_expiry,
    Error(Invalid("a URL must expire within 1 second and 7 days")),
  )
  use Nil <- result.try(case request.download_as {
    Some(name) -> check_file_name(name)
    None -> Ok(Nil)
  })
  storage.url(request)
}

/// A permanent URL for the object, for storage set up with
/// `with_public_url`, such as a public bucket behind a CDN.
pub fn public_url(storage: Storage, key: String) -> Result(String, Error) {
  use Nil <- result.try(check_key(key))
  case storage.public_url {
    Some(url) -> Ok(url(key))
    None -> Error(Invalid(storage.name <> " storage has no public URLs"))
  }
}

// -- Keys --------------------------------------------------------------------

/// A new, unguessable key under `prefix` that keeps the extension of
/// `file_name`, such as `avatars/3f9c0b…e1.png`. Never build a key from a
/// name a user chose: it may clash with another object or reveal more than
/// intended.
pub fn new_key(prefix prefix: String, file_name file_name: String) -> String {
  let id =
    crypto.strong_random_bytes(16)
    |> bit_array.base16_encode
    |> string.lowercase
  let extension = case filepath.extension(file_name) {
    Ok(extension) -> {
      let extension = string.lowercase(extension)
      case
        string.length(extension) <= 10
        && list.all(string.to_utf_codepoints(extension), fn(codepoint) {
          let c = string.utf_codepoint_to_int(codepoint)
          { c >= 97 && c <= 122 } || { c >= 48 && c <= 57 }
        })
      {
        True -> "." <> extension
        False -> ""
      }
    }
    Error(Nil) -> ""
  }
  case prefix {
    "" -> id <> extension
    _ -> string.remove_suffix(prefix, "/") <> "/" <> id <> extension
  }
}

/// Whether `key` can name an object in every adapter: 1 to 1024 bytes of
/// UTF-8, made of `/`-separated segments that are neither empty, `.` nor
/// `..`, nor longer than 255 bytes, with no control characters or
/// backslashes.
pub fn valid_key(key: String) -> Bool {
  check_key(key) == Ok(Nil)
}

fn check_key(key: String) -> Result(Nil, Error) {
  let size = string.byte_size(key)
  let invalid = fn(why) { Error(Invalid("key " <> string.inspect(key) <> why)) }
  use <- bool.guard(size == 0, invalid(" is empty"))
  use <- bool.guard(size > 1024, invalid(" is longer than 1024 bytes"))
  use <- bool.guard(
    has_control_or_backslash(bit_array.from_string(key)),
    invalid(" has a control character or backslash"),
  )
  let segment_ok = fn(segment) {
    segment != ""
    && segment != "."
    && segment != ".."
    && string.byte_size(segment) <= 255
  }
  case list.all(string.split(key, "/"), segment_ok) {
    True -> Ok(Nil)
    False -> invalid(" has an empty, `.`, `..` or overlong segment")
  }
}

fn has_control_or_backslash(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> False
    <<byte, rest:bytes>> ->
      byte < 32 || byte == 127 || byte == 92 || has_control_or_backslash(rest)
    _ -> True
  }
}

fn single_line(what: String, value: String) -> Result(Nil, Error) {
  case string.contains(value, "\r") || string.contains(value, "\n") {
    True -> Error(Invalid(what <> " contains a line break"))
    False -> Ok(Nil)
  }
}

fn check_file_name(name: String) -> Result(Nil, Error) {
  use <- bool.guard(
    string.trim(name) == "",
    Error(Invalid("a download name is empty")),
  )
  case has_control_or_backslash(bit_array.from_string(name)) {
    True -> Error(Invalid("a download name has a control character"))
    False -> Ok(Nil)
  }
}

/// A `Content-Disposition` value that downloads as `file_name`: a plain
/// ASCII name for old clients, and the exact name encoded as RFC 6266
/// allows.
pub fn attachment(file_name: String) -> String {
  let fallback =
    string.to_utf_codepoints(file_name)
    |> list.map(fn(codepoint) {
      case string.utf_codepoint_to_int(codepoint) {
        c if c < 32 || c > 126 || c == 34 || c == 92 || c == 37 -> "_"
        _ -> string.from_utf_codepoints([codepoint])
      }
    })
    |> string.concat
  "attachment; filename=\""
  <> fallback
  <> "\"; filename*=UTF-8''"
  <> percent_encode(file_name)
}

/// Percent-encode everything but RFC 3986's unreserved characters, as S3
/// signing and RFC 5987 both want.
pub fn percent_encode(text: String) -> String {
  encode_bytes(bit_array.from_string(text), "")
}

fn encode_bytes(bytes: BitArray, encoded: String) -> String {
  case bytes {
    <<byte, rest:bytes>> -> {
      let piece = case byte {
        _ if byte >= 65 && byte <= 90 -> int_to_char(byte)
        _ if byte >= 97 && byte <= 122 -> int_to_char(byte)
        _ if byte >= 48 && byte <= 57 -> int_to_char(byte)
        45 | 46 | 95 | 126 -> int_to_char(byte)
        _ -> "%" <> string.pad_start(int.to_base16(byte), 2, "0")
      }
      encode_bytes(rest, encoded <> piece)
    }
    _ -> encoded
  }
}

fn int_to_char(byte: Int) -> String {
  let assert Ok(text) = bit_array.to_string(<<byte>>)
  text
}

// -- Tracing -----------------------------------------------------------------

/// Run a call as a `storage.<operation>` span with the adapter and key.
fn traced(
  storage: Storage,
  operation: String,
  key: String,
  attributes: List(trace.Attribute),
  run: fn() -> Result(a, Error),
) -> Result(a, Error) {
  use <- trace.run(
    trace.new("storage." <> operation)
    |> trace.kind(trace.Client)
    |> trace.attributes([
      trace.string("storage.adapter", storage.name),
      trace.string("storage.key", key),
      ..attributes
    ]),
  )
  let result = run()
  case result {
    Ok(_) | Error(NotFound) -> Nil
    Error(error) -> {
      let kind = case error {
        Invalid(_) -> "invalid"
        Unavailable(_) -> "unavailable"
        Refused(_) -> "refused"
        NotFound -> "not_found"
      }
      trace.set_attributes([trace.string("error.type", kind)])
      trace.set_error("storage " <> kind)
    }
  }
  result
}
