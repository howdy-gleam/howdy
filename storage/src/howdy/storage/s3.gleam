//// Storage in an S3-compatible bucket: AWS S3, Cloudflare R2, Tigris,
//// MinIO, Garage, SeaweedFS, Backblaze B2 and others.
////
//// ```gleam
//// let assert Ok(config) = s3.from_env()
//// let files = s3.adapter(config)
//// ```
////
//// Or describe the bucket in code:
////
//// ```gleam
//// s3.new(
////   bucket: "acme-uploads",
////   region: "auto",
////   access_key_id: key_id,
////   secret_access_key: secret,
//// )
//// |> s3.endpoint("https://<account>.r2.cloudflarestorage.com")
//// |> s3.adapter
//// ```
////
//// Without an `endpoint` the bucket is on AWS, addressed as
//// `<bucket>.s3.<region>.amazonaws.com`. With one, the bucket goes in the
//// path, which every S3-compatible service understands; `path_style`
//// changes either default.
////
//// `put_file` sends a file of up to 16 MiB in one request and a larger one
//// in 8 MiB parts, so no more than a part is in memory at a time. A failed
//// upload in parts is aborted, so its parts are not left to be charged for.
//// `get` reads the whole object into memory: send browsers to `url`
//// instead.

import bucket
import bucket/complete_multipart_upload
import bucket/create_multipart_upload
import bucket/delete_object
import bucket/list_objects
import bucket/put_object
import bucket/upload_part
import gleam/bit_array
import gleam/bool
import gleam/http.{type Method}
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import gleam/uri
import howdy/env
import howdy/storage.{
  type Error, type Put, type Storage, type UrlRequest, Invalid, NotFound,
  Refused, Unavailable,
}
import howdy/storage/internal/sigv4
import simplifile

pub opaque type Config {
  Config(
    bucket: String,
    region: String,
    access_key_id: String,
    secret_access_key: String,
    session_token: Option(String),
    endpoint: Option(String),
    path_style: Option(Bool),
    public_url: Option(String),
    timeout: Int,
    part_size: Int,
    multipart_threshold: Int,
  )
}

pub fn new(
  bucket bucket: String,
  region region: String,
  access_key_id access_key_id: String,
  secret_access_key secret_access_key: String,
) -> Config {
  Config(
    bucket:,
    region:,
    access_key_id:,
    secret_access_key:,
    session_token: None,
    endpoint: None,
    path_style: None,
    public_url: None,
    timeout: 60_000,
    part_size: 8 * mebibyte,
    multipart_threshold: 16 * mebibyte,
  )
}

const mebibyte = 1_048_576

/// Why `from_env` could not build a config.
pub type EnvError {
  MissingVariable(String)
}

/// Read the bucket from the environment, as AWS's own tools and hosts such
/// as Fly.io's Tigris set it:
///
/// - `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, and
///   `AWS_SESSION_TOKEN` for temporary credentials;
/// - `S3_BUCKET`, or `BUCKET_NAME`;
/// - `AWS_REGION` or `AWS_DEFAULT_REGION`, else `us-east-1`;
/// - `AWS_ENDPOINT_URL_S3` or `AWS_ENDPOINT_URL` for a service other than
///   AWS.
pub fn from_env() -> Result(Config, EnvError) {
  let required = fn(names: List(String)) {
    first_set(names)
    |> result.replace_error(MissingVariable(string.join(names, " or ")))
  }
  use access_key_id <- result.try(required(["AWS_ACCESS_KEY_ID"]))
  use secret_access_key <- result.try(required(["AWS_SECRET_ACCESS_KEY"]))
  use bucket <- result.try(required(["S3_BUCKET", "BUCKET_NAME"]))
  let region =
    first_set(["AWS_REGION", "AWS_DEFAULT_REGION"])
    |> result.unwrap("us-east-1")
  let config =
    new(bucket:, region:, access_key_id:, secret_access_key:)
    |> session_token(option.from_result(first_set(["AWS_SESSION_TOKEN"])))
  Ok(case first_set(["AWS_ENDPOINT_URL_S3", "AWS_ENDPOINT_URL"]) {
    Ok(url) -> endpoint(config, url)
    Error(Nil) -> config
  })
}

fn first_set(names: List(String)) -> Result(String, Nil) {
  list.find_map(names, fn(name) {
    case env.get(name) {
      Ok("") -> Error(Nil)
      found -> found
    }
  })
}

/// The service's URL, such as `http://localhost:9000` for MinIO, for a
/// service other than AWS.
pub fn endpoint(config: Config, url: String) -> Config {
  Config(..config, endpoint: Some(url))
}

/// Whether the bucket goes in the path (`True`) or the host name
/// (`False`). By default it goes in the host on AWS and in the path
/// elsewhere. AWS bucket names with dots always go in the path, since TLS
/// certificates do not cover them as host names.
pub fn path_style(config: Config, path_style: Bool) -> Config {
  Config(..config, path_style: Some(path_style))
}

/// Temporary credentials' session token.
pub fn session_token(config: Config, token: Option(String)) -> Config {
  Config(..config, session_token: token)
}

/// Where the objects are public, such as a CDN or a public bucket's URL,
/// without a trailing slash. `storage.public_url` gives this followed by
/// the key.
pub fn public_url(config: Config, base_url: String) -> Config {
  Config(..config, public_url: Some(base_url))
}

/// How long to wait for each request. Default 60 seconds.
pub fn timeout(config: Config, milliseconds: Int) -> Config {
  Config(..config, timeout: milliseconds)
}

/// Upload files larger than `threshold` bytes in parts of `part_size`
/// bytes. S3 needs parts of at least 5 MiB and allows at most 10,000 of
/// them. Default 16 MiB and 8 MiB.
pub fn multipart(
  config: Config,
  threshold threshold: Int,
  part_size part_size: Int,
) -> Config {
  Config(..config, multipart_threshold: threshold, part_size:)
}

pub fn adapter(config: Config) -> Storage {
  let storage =
    storage.adapter(
      named: "s3",
      put: put(config, _),
      get: get(config, _),
      head: head(config, _),
      delete: delete(config, _),
      list: fn(prefix, after, limit) { list_page(config, prefix, after, limit) },
      url: url(config, _),
    )
    |> storage.with_direct_uploads(upload(config, _))
  case config.public_url {
    Some(base) ->
      storage.with_public_url(storage, fn(key) {
        string.remove_suffix(base, "/") <> "/" <> encode_key(key)
      })
    None -> storage
  }
}

// -- Operations --------------------------------------------------------------

fn put(config: Config, put: Put) -> Result(Nil, Error) {
  let headers = object_headers(put)
  case put.body {
    storage.Bytes(bytes) -> put_object(config, put.key, headers, bytes)
    storage.File(path) -> {
      use info <- result.try(
        simplifile.file_info(path)
        |> result.map_error(fn(error) {
          Invalid(
            "cannot read " <> path <> ": " <> simplifile.describe_error(error),
          )
        }),
      )
      case info.size > config.multipart_threshold {
        False -> {
          use bytes <- result.try(read_part(path, 0, info.size))
          put_object(config, put.key, headers, bytes)
        }
        True -> put_in_parts(config, put.key, headers, path, info.size)
      }
    }
  }
}

fn object_headers(put: Put) -> List(#(String, String)) {
  list.flatten([
    [#("content-type", put.content_type)],
    case put.cache_control {
      Some(value) -> [#("cache-control", value)]
      None -> []
    },
    case put.download_as {
      Some(name) -> [#("content-disposition", storage.attachment(name))]
      None -> []
    },
  ])
}

fn put_object(
  config: Config,
  key: String,
  headers: List(#(String, String)),
  bytes: BitArray,
) -> Result(Nil, Error) {
  use response <- result.try(send(config, http.Put, key, [], headers, bytes))
  put_object.response(response)
  |> result.replace(Nil)
  |> result.map_error(failure)
}

fn put_in_parts(
  config: Config,
  key: String,
  headers: List(#(String, String)),
  path: String,
  size: Int,
) -> Result(Nil, Error) {
  use <- bool.guard(
    config.part_size < 5 * mebibyte,
    Error(Invalid("S3 parts must be at least 5 MiB")),
  )
  let count = { size + config.part_size - 1 } / config.part_size
  use <- bool.guard(
    count > 10_000,
    Error(Invalid("a file this large needs parts bigger than the part size")),
  )
  use response <- result.try(
    send(config, http.Post, key, [#("uploads", "")], headers, <<>>),
  )
  use started <- result.try(
    create_multipart_upload.response(response) |> result.map_error(failure),
  )
  let upload_id = started.upload_id
  let uploaded = {
    use parts <- result.try(
      int.range(from: count, to: 0, with: [], run: list.prepend)
      |> list.try_map(fn(number) {
        let offset = { number - 1 } * config.part_size
        use bytes <- result.try(read_part(path, offset, config.part_size))
        let query = [
          #("partNumber", int.to_string(number)),
          #("uploadId", upload_id),
        ]
        use response <- result.try(send(config, http.Put, key, query, [], bytes))
        use part <- result.map(
          upload_part.response(response) |> result.map_error(failure),
        )
        complete_multipart_upload.Part(part_number: number, etag: part.etag)
      }),
    )
    let body = complete_body(parts)
    use response <- result.try(send(
      config,
      http.Post,
      key,
      [#("uploadId", upload_id)],
      [],
      body,
    ))
    complete_multipart_upload.response(response)
    |> result.replace(Nil)
    |> result.map_error(failure)
  }
  case uploaded {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> {
      // Best effort: parts left behind are stored, and charged for, until
      // the upload is aborted.
      let _ =
        send(config, http.Delete, key, [#("uploadId", upload_id)], [], <<>>)
      Error(error)
    }
  }
}

fn complete_body(parts: List(complete_multipart_upload.Part)) -> BitArray {
  let parts =
    list.map(parts, fn(part) {
      "<Part><PartNumber>"
      <> int.to_string(part.part_number)
      <> "</PartNumber><ETag>"
      <> escape_xml(part.etag)
      <> "</ETag></Part>"
    })
  <<
    "<CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">":utf8,
    string.concat(parts):utf8,
    "</CompleteMultipartUpload>":utf8,
  >>
}

fn escape_xml(text: String) -> String {
  text
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
}

fn get(config: Config, key: String) -> Result(BitArray, Error) {
  use response <- result.try(send(config, http.Get, key, [], [], <<>>))
  case response.status {
    200 -> Ok(response.body)
    _ -> Error(error_from(response))
  }
}

fn head(config: Config, key: String) -> Result(storage.Object, Error) {
  use response <- result.try(send(config, http.Head, key, [], [], <<>>))
  case response.status {
    200 -> {
      let header = fn(name) { response.get_header(response, name) }
      let size =
        header("content-length") |> result.try(int.parse) |> result.unwrap(0)
      let last_modified =
        header("last-modified")
        |> result.try(parse_http_date)
        |> result.map(timestamp.from_unix_seconds)
        |> result.unwrap(timestamp.unix_epoch)
      Ok(storage.Object(
        key:,
        size:,
        content_type: header("content-type")
          |> result.unwrap("application/octet-stream"),
        etag: header("etag") |> result.unwrap(""),
        last_modified:,
      ))
    }
    // A HEAD response has no body to explain itself.
    404 -> Error(NotFound)
    _ -> Error(error_from(response))
  }
}

fn delete(config: Config, key: String) -> Result(Nil, Error) {
  use response <- result.try(send(config, http.Delete, key, [], [], <<>>))
  case response.status {
    200 | 204 -> Ok(Nil)
    _ -> delete_object.response(response) |> result.map_error(failure)
  }
}

fn list_page(
  config: Config,
  prefix: String,
  after: Option(String),
  limit: Int,
) -> Result(storage.Page, Error) {
  let query =
    list.flatten([
      [#("list-type", "2"), #("max-keys", int.to_string(limit))],
      case prefix {
        "" -> []
        _ -> [#("prefix", prefix)]
      },
      case after {
        Some(key) -> [#("start-after", key)]
        None -> []
      },
    ])
  use location <- result.try(location(config))
  use response <- result.try(
    dispatch(config, location, http.Get, bucket_path(location), query, [], <<>>),
  )
  use listed <- result.try(
    list_objects.response(response) |> result.map_error(failure),
  )
  let objects =
    listed.contents
    |> list.reverse
    |> list.map(fn(object) {
      storage.Summary(
        key: object.key,
        size: object.size,
        etag: object.etag,
        last_modified: timestamp.parse_rfc3339(object.last_modified)
          |> result.unwrap(timestamp.unix_epoch),
      )
    })
  let next = case listed.is_truncated, list.last(objects) {
    True, Ok(last) -> Some(last.key)
    _, _ -> None
  }
  Ok(storage.Page(objects:, next:))
}

fn url(config: Config, request: UrlRequest) -> Result(String, Error) {
  let query = case request.download_as {
    Some(name) -> [#("response-content-disposition", storage.attachment(name))]
    None -> []
  }
  presign(
    config,
    request.key,
    query,
    request.expires_in,
    timestamp.system_time(),
  )
}

/// A presigned `PUT` whose signature covers the content type and length,
/// so S3 refuses an upload of any other size or type.
fn upload(
  config: Config,
  request: storage.UploadRequest,
) -> Result(storage.DirectUpload, Error) {
  use location <- result.try(location(config))
  let url =
    sigv4.presign(
      http.Put,
      location.scheme,
      location.host,
      location.port,
      object_path(location, request.key),
      [],
      [
        #("content-type", request.content_type),
        #("content-length", int.to_string(request.size)),
      ],
      credentials(config),
      timestamp.system_time(),
      request.expires_in,
    )
  Ok(
    storage.DirectUpload(url:, method: "PUT", headers: [
      #("content-type", request.content_type),
    ]),
  )
}

/// A signed `GET` URL for `key`. Public so tests can fix the clock.
@internal
pub fn presign(
  config: Config,
  key: String,
  query: List(#(String, String)),
  expires_in: Int,
  now: Timestamp,
) -> Result(String, Error) {
  use location <- result.try(location(config))
  Ok(sigv4.presign(
    http.Get,
    location.scheme,
    location.host,
    location.port,
    object_path(location, key),
    query,
    [],
    credentials(config),
    now,
    expires_in,
  ))
}

// -- Requests ----------------------------------------------------------------

/// Where requests go: the bucket in the host, or in `base_path`.
type Location {
  Location(
    scheme: http.Scheme,
    host: String,
    port: Option(Int),
    base_path: String,
  )
}

fn location(config: Config) -> Result(Location, Error) {
  case config.endpoint {
    None -> {
      let path_style =
        option.unwrap(config.path_style, string.contains(config.bucket, "."))
      let host = "s3." <> config.region <> ".amazonaws.com"
      Ok(case path_style {
        True -> Location(http.Https, host, None, "/" <> config.bucket)
        False -> Location(http.Https, config.bucket <> "." <> host, None, "")
      })
    }
    Some(endpoint) -> {
      let invalid = Refused("invalid S3 endpoint URL " <> endpoint)
      use parsed <- result.try(
        uri.parse(endpoint) |> result.replace_error(invalid),
      )
      use scheme <- result.try(case parsed.scheme {
        Some("https") -> Ok(http.Https)
        Some("http") -> Ok(http.Http)
        _ -> Error(invalid)
      })
      use host <- result.try(option.to_result(parsed.host, invalid))
      use <- bool.guard(parsed.path != "" && parsed.path != "/", Error(invalid))
      Ok(case option.unwrap(config.path_style, True) {
        True -> Location(scheme, host, parsed.port, "/" <> config.bucket)
        False -> Location(scheme, config.bucket <> "." <> host, parsed.port, "")
      })
    }
  }
}

fn bucket_path(location: Location) -> String {
  case location.base_path {
    "" -> "/"
    path -> path
  }
}

fn object_path(location: Location, key: String) -> String {
  location.base_path <> "/" <> encode_key(key)
}

/// Each segment percent-encoded, keeping the `/` between them.
fn encode_key(key: String) -> String {
  key
  |> string.split("/")
  |> list.map(storage.percent_encode)
  |> string.join("/")
}

fn credentials(config: Config) -> sigv4.Credentials {
  sigv4.Credentials(
    access_key_id: config.access_key_id,
    secret_access_key: config.secret_access_key,
    session_token: config.session_token,
    region: config.region,
  )
}

fn send(
  config: Config,
  method: Method,
  key: String,
  query: List(#(String, String)),
  headers: List(#(String, String)),
  body: BitArray,
) -> Result(Response(BitArray), Error) {
  use location <- result.try(location(config))
  dispatch(
    config,
    location,
    method,
    object_path(location, key),
    query,
    headers,
    body,
  )
}

fn dispatch(
  config: Config,
  location: Location,
  method: Method,
  path: String,
  query: List(#(String, String)),
  headers: List(#(String, String)),
  body: BitArray,
) -> Result(Response(BitArray), Error) {
  let request =
    request.Request(
      method:,
      headers:,
      body:,
      scheme: location.scheme,
      host: location.host,
      port: location.port,
      path:,
      query: None,
    )
    |> sigv4.sign(query, credentials(config), timestamp.system_time())
  case
    httpc.configure()
    |> httpc.timeout(config.timeout)
    |> httpc.follow_redirects(False)
    |> httpc.dispatch_bits(request)
  {
    Ok(response) -> Ok(response)
    Error(httpc.ResponseTimeout) ->
      Error(Unavailable(
        "no response within " <> int.to_string(config.timeout) <> "ms",
      ))
    Error(httpc.FailedToConnect(ip4, ip6)) ->
      Error(Unavailable(
        "could not connect to "
        <> location.host
        <> ": "
        <> string.inspect(ip4)
        <> ", "
        <> string.inspect(ip6),
      ))
    Error(error) -> Error(Unavailable(string.inspect(error)))
  }
}

fn read_part(path: String, offset: Int, size: Int) -> Result(BitArray, Error) {
  ffi_read_part(path, offset, size)
  |> result.map_error(fn(reason) {
    Invalid("cannot read " <> path <> ": " <> reason)
  })
}

@external(erlang, "howdy_storage_ffi", "read_part")
fn ffi_read_part(
  path: String,
  offset: Int,
  size: Int,
) -> Result(BitArray, String)

@external(erlang, "howdy_storage_ffi", "parse_http_date")
fn parse_http_date(date: String) -> Result(Int, Nil)

// -- Failures ----------------------------------------------------------------

/// The error a failed response stands for. `bucket` reads S3's error
/// document; its delete parser accepts only `204`, so it reads any
/// failure's.
fn error_from(response: Response(BitArray)) -> Error {
  case delete_object.response(response) {
    Ok(Nil) -> Unavailable("unexpected 204")
    Error(error) -> failure(error)
  }
}

fn failure(error: bucket.BucketError) -> Error {
  case error {
    bucket.S3Error(http_status:, error:) ->
      case error.code, http_status {
        "NoSuchKey", _ -> NotFound
        code, status -> by_status(status, code <> ": " <> error.message)
      }
    bucket.UnexpectedResponseError(response) ->
      case response.status {
        404 -> NotFound
        status ->
          by_status(
            status,
            "S3 answered "
              <> int.to_string(status)
              <> ": "
              <> string.slice(
              bit_array.to_string(response.body) |> result.unwrap(""),
              0,
              300,
            ),
          )
      }
    bucket.InvalidXmlSyntaxError(reason)
    | bucket.UnexpectedXmlFormatError(reason) ->
      Refused("S3 answered with an unexpected document: " <> reason)
  }
}

/// Throttling, timeouts and server errors are worth retrying; anything else
/// was refused.
fn by_status(status: Int, reason: String) -> Error {
  case status {
    408 | 429 -> Unavailable(reason)
    _ if status >= 500 -> Unavailable(reason)
    _ -> Refused(reason)
  }
}
