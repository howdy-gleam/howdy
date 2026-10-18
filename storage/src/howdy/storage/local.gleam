//// Storage in a local folder, for development and for apps on one server.
//// Each object is a file at its key under the folder, so the folder can
//// be browsed, backed up or synced like any other.
////
//// ```gleam
//// let config =
////   local.new("storage")
////   |> local.serve(at: "/files", secret: env.get_or("STORAGE_SECRET", ""))
//// let files = local.adapter(config)
////
//// howdy.new()
//// |> howdy.controller(local.controller(config))
//// ```
////
//// A folder cannot hold both an object `a` and an object `a/b`, as a
//// bucket can, so the second is refused. The content type and other
//// details of each object are kept beside it under `.howdy-storage`, which
//// keys may not start with.
////
//// ## Serving files
////
//// `storage.url` needs `serve`: it gives a URL under that path, signed with
//// the secret, which `controller` answers until it expires. Use a secret
//// of at least 32 random bytes, and the same on every node. Files are
//// served from the app's own origin, so the controller sends them with
//// `X-Content-Type-Options: nosniff` and a sandboxing
//// `Content-Security-Policy`, and makes the browser download anything but
//// images, audio, video, PDFs and plain text rather than show it. An HTML
//// or SVG file someone uploaded cannot run script on your site.

import filepath
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import howdy/content.{type Content}
import howdy/controller.{type Controller}
import howdy/service
import howdy/static
import howdy/storage.{
  type Error, type Put, type Storage, type UrlRequest, Invalid, NotFound,
  Refused,
}
import howdy/storage/internal/page
import simplifile

pub opaque type Config {
  Config(directory: String, serving: Option(Serving), public: Bool)
}

type Serving {
  Serving(prefix: String, secret: BitArray)
}

/// Storage in `directory`, relative to the working directory unless
/// absolute. It is created when the first object is stored.
pub fn new(directory: String) -> Config {
  Config(directory:, serving: None, public: False)
}

/// Make URLs under `prefix`, where `controller` is mounted, signed with
/// `secret`.
pub fn serve(
  config: Config,
  at prefix: String,
  secret secret: String,
) -> Config {
  let prefix = case string.remove_suffix(prefix, "/") {
    "" -> "/"
    prefix -> prefix
  }
  Config(..config, serving: Some(Serving(prefix:, secret: <<secret:utf8>>)))
}

/// Serve every object to anyone, without a signature, and give
/// `storage.public_url`s. Needs `serve` too.
pub fn public(config: Config) -> Config {
  Config(..config, public: True)
}

pub fn adapter(config: Config) -> Storage {
  let storage =
    storage.adapter(
      named: "local",
      put: put(config, _),
      get: get(config, _),
      head: head(config, _),
      delete: delete(config, _),
      list: fn(prefix, after, limit) { list(config, prefix, after, limit) },
      url: url(config, _),
    )
  case config.public, config.serving {
    True, Some(serving) ->
      storage.with_public_url(storage, fn(key) { link(serving, key) })
    _, _ -> storage
  }
}

// -- Files -------------------------------------------------------------------

const reserved = ".howdy-storage"

/// The details kept beside each object.
type Details {
  Details(
    content_type: String,
    cache_control: Option(String),
    download_as: Option(String),
    etag: String,
  )
}

fn object_path(config: Config, key: String) -> Result(String, Error) {
  case string.split_once(key, "/") {
    Ok(#(first, _)) if first == reserved -> reserved_key(key)
    _ if key == reserved -> reserved_key(key)
    _ -> Ok(filepath.join(config.directory, key))
  }
}

fn reserved_key(key: String) -> Result(a, Error) {
  Error(Invalid("key " <> key <> " is reserved by local storage"))
}

fn details_path(config: Config, key: String) -> String {
  filepath.join(config.directory, reserved <> "/details/" <> key <> ".json")
}

fn put(config: Config, put: Put) -> Result(Nil, Error) {
  use path <- result.try(object_path(config, put.key))
  let temporary =
    filepath.join(config.directory, reserved <> "/tmp/" <> random_name())
  use Nil <- result.try(directory_for(temporary))
  let written = case put.body {
    storage.Bytes(bytes) -> simplifile.write_bits(temporary, bytes)
    storage.File(source) -> simplifile.copy_file(source, temporary)
  }
  use Nil <- result.try(written |> result.map_error(file_error))
  let stored = {
    use etag <- result.try(md5_file(temporary) |> result.map_error(Refused))
    let details =
      Details(
        content_type: put.content_type,
        cache_control: put.cache_control,
        download_as: put.download_as,
        etag:,
      )
    use Nil <- result.try(directory_for(path) |> clash(put.key))
    use Nil <- result.try(
      simplifile.rename(temporary, path)
      |> result.map_error(file_error)
      |> clash(put.key),
    )
    let details_path = details_path(config, put.key)
    use Nil <- result.try(directory_for(details_path))
    simplifile.write(details_path, json.to_string(details_to_json(details)))
    |> result.map_error(file_error)
  }
  case stored {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> {
      let _ = simplifile.delete(temporary)
      Error(error)
    }
  }
}

/// A key that cannot be stored because another is in the way, such as
/// `a/b` when `a` is a file.
fn clash(result: Result(a, Error), key: String) -> Result(a, Error) {
  result.replace_error(
    result,
    Invalid("key " <> key <> " clashes with another object in the folder"),
  )
}

fn directory_for(path: String) -> Result(Nil, Error) {
  simplifile.create_directory_all(filepath.directory_name(path))
  |> result.map_error(file_error)
}

fn get(config: Config, key: String) -> Result(BitArray, Error) {
  use path <- result.try(object_path(config, key))
  case simplifile.read_bits(path) {
    Ok(bytes) -> Ok(bytes)
    Error(simplifile.Enoent)
    | Error(simplifile.Eisdir)
    | Error(simplifile.Enotdir) -> Error(NotFound)
    Error(error) -> Error(file_error(error))
  }
}

fn head(config: Config, key: String) -> Result(storage.Object, Error) {
  use path <- result.try(object_path(config, key))
  use info <- result.try(file_info(path))
  let details = read_details(config, key, path)
  Ok(storage.Object(
    key:,
    size: info.size,
    content_type: details.content_type,
    etag: details.etag,
    last_modified: timestamp.from_unix_seconds(info.mtime_seconds),
  ))
}

fn file_info(path: String) -> Result(simplifile.FileInfo, Error) {
  case simplifile.file_info(path) {
    Ok(info) ->
      case simplifile.file_info_type(info) {
        simplifile.File -> Ok(info)
        _ -> Error(NotFound)
      }
    Error(simplifile.Enoent) | Error(simplifile.Enotdir) -> Error(NotFound)
    Error(error) -> Error(file_error(error))
  }
}

/// The details stored with an object, or ones worked out from the file
/// for a file put in the folder some other way.
fn read_details(config: Config, key: String, path: String) -> Details {
  let stored =
    simplifile.read(details_path(config, key))
    |> result.replace_error(Nil)
    |> result.try(fn(text) {
      json.parse(text, details_decoder()) |> result.replace_error(Nil)
    })
  case stored {
    Ok(details) -> details
    Error(Nil) ->
      Details(
        content_type: static.content_type(path),
        cache_control: None,
        download_as: None,
        etag: md5_file(path) |> result.unwrap(""),
      )
  }
}

fn delete(config: Config, key: String) -> Result(Nil, Error) {
  use path <- result.try(object_path(config, key))
  use Nil <- result.try(case file_info(path) {
    Ok(_) -> simplifile.delete(path) |> result.map_error(file_error)
    Error(NotFound) -> Ok(Nil)
    Error(error) -> Error(error)
  })
  let _ = simplifile.delete(details_path(config, key))
  remove_empty_parents(config.directory, filepath.directory_name(path))
  remove_empty_parents(
    config.directory,
    filepath.directory_name(details_path(config, key)),
  )
  Ok(Nil)
}

/// Remove directories left empty by a delete, up to the storage folder.
fn remove_empty_parents(root: String, directory: String) -> Nil {
  case directory == root || !string.starts_with(directory, root) {
    True -> Nil
    False ->
      case delete_empty_directory(directory) {
        Ok(Nil) ->
          remove_empty_parents(root, filepath.directory_name(directory))
        Error(Nil) -> Nil
      }
  }
}

fn list(
  config: Config,
  prefix: String,
  after: Option(String),
  limit: Int,
) -> Result(storage.Page, Error) {
  let root = string.remove_suffix(config.directory, "/") <> "/"
  use files <- result.try(case simplifile.get_files(config.directory) {
    Ok(files) -> Ok(files)
    Error(simplifile.Enoent) -> Ok([])
    Error(error) -> Error(file_error(error))
  })
  let matching =
    files
    |> list.filter_map(fn(path) {
      let key = string.remove_prefix(path, root)
      case
        string.starts_with(key, reserved <> "/")
        || !page.wanted(key, prefix, after)
      {
        True -> Error(Nil)
        False -> Ok(#(key, path))
      }
    })
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  let page = page.of(list.map(matching, summary(config, _)), limit)
  Ok(page)
}

fn summary(config: Config, entry: #(String, String)) -> storage.Summary {
  let #(key, path) = entry
  let #(size, mtime) = case simplifile.file_info(path) {
    Ok(info) -> #(info.size, info.mtime_seconds)
    Error(_) -> #(0, 0)
  }
  let etag =
    simplifile.read(details_path(config, key))
    |> result.replace_error(Nil)
    |> result.try(fn(text) {
      json.parse(text, details_decoder()) |> result.replace_error(Nil)
    })
    |> result.map(fn(details) { details.etag })
    |> result.unwrap("")
  storage.Summary(
    key:,
    size:,
    etag:,
    last_modified: timestamp.from_unix_seconds(mtime),
  )
}

fn file_error(error: simplifile.FileError) -> Error {
  Refused(simplifile.describe_error(error))
}

fn details_to_json(details: Details) -> json.Json {
  json.object([
    #("content_type", json.string(details.content_type)),
    #("cache_control", json.nullable(details.cache_control, json.string)),
    #("download_as", json.nullable(details.download_as, json.string)),
    #("etag", json.string(details.etag)),
  ])
}

fn details_decoder() -> decode.Decoder(Details) {
  use content_type <- decode.field("content_type", decode.string)
  use cache_control <- decode.field(
    "cache_control",
    decode.optional(decode.string),
  )
  use download_as <- decode.field("download_as", decode.optional(decode.string))
  use etag <- decode.field("etag", decode.string)
  decode.success(Details(content_type:, cache_control:, download_as:, etag:))
}

@external(erlang, "howdy_storage_ffi", "md5_file")
fn md5_file(path: String) -> Result(String, String)

@external(erlang, "howdy_storage_ffi", "random_name")
fn random_name() -> String

@external(erlang, "howdy_storage_ffi", "delete_empty_directory")
fn delete_empty_directory(path: String) -> Result(Nil, Nil)

// -- URLs --------------------------------------------------------------------

fn url(config: Config, request: UrlRequest) -> Result(String, Error) {
  use serving <- result.try(option.to_result(
    config.serving,
    Invalid("local storage needs local.serve to make URLs"),
  ))
  use _ <- result.try(object_path(config, request.key))
  let expires = int.to_string(now_seconds() + request.expires_in)
  let download = option.unwrap(request.download_as, "")
  let signature = sign(serving, request.key, expires, download)
  let query =
    list.flatten([
      [#("expires", expires)],
      case request.download_as {
        Some(name) -> [#("download", name)]
        None -> []
      },
      [#("signature", signature)],
    ])
    |> list.map(fn(pair) {
      storage.percent_encode(pair.0) <> "=" <> storage.percent_encode(pair.1)
    })
    |> string.join("&")
  Ok(link(serving, request.key) <> "?" <> query)
}

fn link(serving: Serving, key: String) -> String {
  let encoded =
    string.split(key, "/")
    |> list.map(storage.percent_encode)
    |> string.join("/")
  string.remove_suffix(serving.prefix, "/") <> "/" <> encoded
}

fn sign(
  serving: Serving,
  key: String,
  expires: String,
  download: String,
) -> String {
  crypto.hmac(
    <<
      "GET\n":utf8,
      key:utf8,
      "\n":utf8,
      expires:utf8,
      "\n":utf8,
      download:utf8,
    >>,
    crypto.Sha256,
    serving.secret,
  )
  |> bit_array.base64_url_encode(False)
}

fn now_seconds() -> Int {
  let #(seconds, _) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  seconds
}

// -- Serving -----------------------------------------------------------------

/// A controller answering the URLs `storage.url` makes, mounted at the
/// prefix given to `serve`. An expired or altered URL gets a `403`.
pub fn controller(config: Config) -> Controller {
  let assert Some(serving) = config.serving
    as "howdy/storage/local: controller needs local.serve"
  let handler = fn(ctx: controller.Context) {
    case controller.param(ctx, "key") {
      Ok(key) -> respond(ctx, config, serving, key)
      Error(Nil) -> not_found(ctx)
    }
  }
  controller.new(serving.prefix)
  |> controller.get("/*key", handler)
  |> controller.route(http.Head, "/*key", handler)
}

fn respond(
  ctx: controller.Context,
  config: Config,
  serving: Serving,
  key: String,
) -> Response(Content) {
  let query = request.get_query(ctx.request) |> result.unwrap([])
  let field = fn(name) { list.key_find(query, name) }
  let download = field("download") |> option.from_result
  let access = case field("signature"), field("expires") {
    Ok(signature), Ok(expires) -> {
      let expected = sign(serving, key, expires, option.unwrap(download, ""))
      let valid = crypto.secure_compare(<<signature:utf8>>, <<expected:utf8>>)
      let now = now_seconds()
      case valid, int.parse(expires) {
        True, Ok(expires) if expires >= now -> Ok(Some(expires - now))
        _, _ -> Error(Nil)
      }
    }
    _, _ if config.public -> Ok(None)
    _, _ -> Error(Nil)
  }
  case access, storage.valid_key(key), object_path(config, key) {
    Error(Nil), _, _ -> service.error_response(ctx, service.Forbidden)
    Ok(remaining), True, Ok(path) ->
      case file_info(path) {
        Ok(_) -> send(ctx, config, key, path, remaining, download)
        Error(_) -> not_found(ctx)
      }
    _, _, _ -> not_found(ctx)
  }
}

fn send(
  ctx: controller.Context,
  config: Config,
  key: String,
  path: String,
  remaining: Option(Int),
  download: Option(String),
) -> Response(Content) {
  let details = read_details(config, key, path)
  let response = static.file(ctx, path)
  use <- bool.guard(response.status >= 400, response)
  let disposition = case option.or(download, details.download_as) {
    Some(name) -> Some(storage.attachment(name))
    None ->
      case inline_safe(details.content_type) {
        True -> None
        False -> Some(storage.attachment(filepath.base_name(key)))
      }
  }
  let cache_control = case remaining {
    Some(seconds) -> Some("private, max-age=" <> int.to_string(seconds))
    None -> details.cache_control
  }
  response
  |> response.set_header("content-type", details.content_type)
  |> response.set_header("x-content-type-options", "nosniff")
  |> response.set_header(
    "content-security-policy",
    "default-src 'none'; img-src 'self'; media-src 'self'; style-src 'unsafe-inline'; sandbox",
  )
  |> maybe_header("content-disposition", disposition)
  |> maybe_header("cache-control", cache_control)
}

fn maybe_header(
  response: Response(a),
  name: String,
  value: Option(String),
) -> Response(a) {
  case value {
    Some(value) -> response.set_header(response, name, value)
    None -> response
  }
}

/// Types a browser shows without running anything from them.
fn inline_safe(content_type: String) -> Bool {
  let media =
    content_type
    |> string.split(";")
    |> list.first
    |> result.unwrap("")
    |> string.trim
    |> string.lowercase
  case media {
    "image/png"
    | "image/jpeg"
    | "image/gif"
    | "image/webp"
    | "image/avif"
    | "image/bmp"
    | "image/x-icon"
    | "image/vnd.microsoft.icon"
    | "application/pdf"
    | "text/plain" -> True
    _ ->
      string.starts_with(media, "video/") || string.starts_with(media, "audio/")
  }
}

fn not_found(ctx: controller.Context) -> Response(Content) {
  service.error_response(ctx, service.NotFound("file not found"))
}
