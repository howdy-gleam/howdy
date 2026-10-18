//// HTML forms, submitted as `application/x-www-form-urlencoded` or as
//// `multipart/form-data`, the encoding a form with a file input needs.
////
//// The body can be read only once, so `read` turns it into a `Form` and
//// every field is then taken from that value. Field problems are returned
//// as `validate` errors rather than responses, so a page can be rendered
//// again with its errors and the values the user typed.
////
//// A local variable named `form` would shadow this module, so call the
//// value something else, such as `fields`.
////
//// ```gleam
//// fn signup(fields: Form) -> validate.Result(Signup) {
////   use email <- form.string(fields, "email", [validate.email()])
////   use age <- form.int(fields, "age", [validate.min(13)])
////   use newsletter <- form.checkbox(fields, "newsletter")
////   validate.ok(Signup(email:, age:, newsletter:))
//// }
////
//// fn create(ctx: Context) {
////   use fields <- form.read(ctx)
////   case signup(fields) {
////     Ok(signup) -> ...
////     Error(errors) ->
////       controller.html(ctx, signup_page(fields, errors))
////       |> controller.with_status(422)
////   }
//// }
//// ```
////
//// Browsers submit an empty input as `name=`. `string` keeps the empty
//// string, so pair it with `validate.not_empty()`; `int` treats it as
//// missing; the `optional_*` helpers treat it as `None`. A singular field
//// submitted more than once is an error. Any other content type gets a
//// `415`.
////
//// ## Files
////
//// A form takes no files unless its limits accept them, so an endpoint that
//// does not expect uploads cannot be made to write them to disk. Each file
//// is written to a temporary file as it arrives rather than held in memory,
//// and deleted once the continuation returns, so store it or move it before
//// then.
////
//// ```gleam
//// fn change_avatar(ctx: Context) {
////   let limits =
////     form.limits() |> form.accept_files(max_files: 1, max_file_size: 5_000_000)
////   use fields <- form.read_with(ctx, limits)
////   let avatar = {
////     use avatar <- form.file(fields, "avatar", [
////       form.file_type(["image/png", "image/jpeg"]),
////     ])
////     validate.ok(avatar)
////   }
////   case avatar {
////     Ok(avatar) -> ... // copy avatar.path somewhere lasting
////     Error(errors) -> ...
////   }
//// }
//// ```
////
//// The file name and content type are what the browser claimed. Check the
//// content itself before relying on either, and never use the name as a
//// path. A file input left empty is not submitted as a file.
////
//// Form posts are not subject to CORS preflight, so cookie-authenticated
//// forms need CSRF protection. Use `howdy/csrf`, or the `Origin` check
//// `howdy_auth` already applies to routes behind its guard.

import filepath
import gleam/bit_array
import gleam/bool
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import howdy/body
import howdy/content.{type Content}
import howdy/context
import howdy/controller.{type GuardedContext}
import howdy/query
import howdy/service.{type FieldError}
import howdy/validate.{type Rule}
import simplifile

/// The fields of a submitted form, in the order they were sent.
pub opaque type Form {
  Form(fields: List(#(String, String)), files: List(#(String, UploadedFile)))
}

/// A file submitted with a form, written to a temporary file.
pub type UploadedFile {
  UploadedFile(
    /// The name the browser gave, without any directories. Do not use it as
    /// a path.
    file_name: String,
    /// The content type the browser claimed, or `application/octet-stream`.
    content_type: String,
    /// The size in bytes.
    size: Int,
    /// Where the file is. It is deleted once the continuation given to
    /// `read_with` returns.
    path: String,
  )
}

/// How much a form may carry. Build them from `limits`.
pub opaque type Limits {
  Limits(
    fields: Int,
    max_files: Int,
    max_file_size: Int,
    max_total_file_size: Option(Int),
    directory: Option(String),
    chunk_size: Int,
  )
}

// -- Limits ------------------------------------------------------------------

/// The limits `read` uses: up to `body.default_limit` bytes of fields, and
/// no files.
pub fn limits() -> Limits {
  Limits(
    fields: body.default_limit,
    max_files: 0,
    max_file_size: 0,
    max_total_file_size: None,
    directory: None,
    chunk_size: 65_536,
  )
}

/// The most bytes of everything but file contents: the whole body of a
/// urlencoded form, or the fields, part headers and boundaries of a
/// multipart one.
pub fn max_fields_size(limits: Limits, bytes: Int) -> Limits {
  Limits(..limits, fields: bytes)
}

/// Accept up to `max_files` files of up to `max_file_size` bytes each. A
/// larger file, or one too many, fails the whole form with a `400`. Check
/// smaller limits with validation rules such as `max_size` instead, to show
/// the user an error beside the field.
pub fn accept_files(
  limits: Limits,
  max_files max_files: Int,
  max_file_size max_file_size: Int,
) -> Limits {
  Limits(..limits, max_files:, max_file_size:)
}

/// The most bytes all the files together may have. By default it is
/// `max_files` times `max_file_size`.
pub fn max_total_file_size(limits: Limits, bytes: Int) -> Limits {
  Limits(..limits, max_total_file_size: Some(bytes))
}

/// Where uploaded files are written while a request uses them. By default
/// the directory named by `TMPDIR`, `TMP` or `TEMP`, else `/tmp`. It is
/// created if missing.
pub fn temporary_directory(limits: Limits, directory: String) -> Limits {
  Limits(..limits, directory: Some(directory))
}

/// The most bytes read from the socket at a time, so tests can split a body
/// into small pieces.
@internal
pub fn chunk_size(limits: Limits, bytes: Int) -> Limits {
  Limits(..limits, chunk_size: bytes)
}

fn total_file_size(limits: Limits) -> Int {
  option.unwrap(
    limits.max_total_file_size,
    limits.max_files * limits.max_file_size,
  )
}

// -- Reading -----------------------------------------------------------------

/// Read the request body as a form, with the default `limits`: no files. A
/// wrong content type returns `415`; a body that is too large or badly
/// encoded returns `400`. The continuation never runs in either case.
pub fn read(
  ctx: GuardedContext(guarded),
  next: fn(Form) -> Response(Content),
) -> Response(Content) {
  read_with(ctx, limits(), next)
}

/// Like `read` but with a custom size limit in bytes.
pub fn read_with_limit(
  ctx: GuardedContext(guarded),
  limit: Int,
  next: fn(Form) -> Response(Content),
) -> Response(Content) {
  read_with(ctx, limits() |> max_fields_size(limit), next)
}

/// Like `read` but with the limits given, such as to accept files. Any
/// uploaded files are deleted once `next` returns, even if it crashes.
pub fn read_with(
  ctx: GuardedContext(guarded),
  limits: Limits,
  next: fn(Form) -> Response(Content),
) -> Response(Content) {
  case encoding(ctx) {
    Error(error) -> service.error_response(ctx, error)
    Ok(Urlencoded) -> read_urlencoded(ctx, limits.fields, next)
    Ok(Multipart(boundary:)) -> read_multipart(ctx, limits, boundary, next)
  }
}

fn read_urlencoded(
  ctx: GuardedContext(guarded),
  limit: Int,
  next: fn(Form) -> Response(Content),
) -> Response(Content) {
  case controller.read_body(ctx, limit:) {
    Ok(bits) ->
      case parse(bits) {
        Ok(form) -> next(form)
        Error(Nil) ->
          invalid(ctx, "request body is not a valid urlencoded form")
      }
    Error(context.BodyTooLarge) -> invalid(ctx, "request body too large")
    Error(context.InvalidBody) -> invalid(ctx, "request body could not be read")
  }
}

/// Read a form and validate it, for endpoints that answer with JSON. A
/// validation failure returns `422` with every field error, as
/// `body.validated` does. Pages that render their errors should use `read`.
pub fn validated(
  ctx: GuardedContext(guarded),
  validator: fn(Form) -> validate.Result(a),
  next: fn(a) -> Response(Content),
) -> Response(Content) {
  validated_with(ctx, limits(), validator, next)
}

/// Like `validated` but with the limits given, such as to accept files.
pub fn validated_with(
  ctx: GuardedContext(guarded),
  limits: Limits,
  validator: fn(Form) -> validate.Result(a),
  next: fn(a) -> Response(Content),
) -> Response(Content) {
  use form <- read_with(ctx, limits)
  validate.check(ctx, validator(form), next)
}

/// A form made of `fields`, for calling a validator directly in a test.
pub fn from_fields(fields: List(#(String, String))) -> Form {
  Form(fields:, files: [])
}

/// Add files to a form, for calling a validator directly in a test.
pub fn with_files(form: Form, files: List(#(String, UploadedFile))) -> Form {
  Form(..form, files: list.append(form.files, files))
}

// -- Raw access --------------------------------------------------------------

/// The first value submitted for `name`.
pub fn get(form: Form, name: String) -> Result(String, Nil) {
  list.key_find(form.fields, name)
}

/// Every value submitted for `name`, in order. An absent field gives `[]`.
pub fn all(form: Form, name: String) -> List(String) {
  form.fields
  |> list.filter(fn(field) { field.0 == name })
  |> list.map(fn(field) { field.1 })
}

/// The first value submitted for `name`, or `""`. Use it to fill an input
/// back in when rendering a form again. Escape it like any other user input.
pub fn value(form: Form, name: String) -> String {
  result.unwrap(get(form, name), "")
}

/// Every field but the files, in the order submitted.
pub fn fields(form: Form) -> List(#(String, String)) {
  form.fields
}

/// The first file submitted for `name`.
pub fn get_file(form: Form, name: String) -> Result(UploadedFile, Nil) {
  list.key_find(form.files, name)
}

/// Every file submitted for `name`, in order. An absent field gives `[]`.
pub fn all_files(form: Form, name: String) -> List(UploadedFile) {
  form.files
  |> list.filter(fn(file) { file.0 == name })
  |> list.map(fn(file) { file.1 })
}

/// Every file with the name of its field, in the order submitted.
pub fn uploaded_files(form: Form) -> List(#(String, UploadedFile)) {
  form.files
}

/// The message for `name` among validation errors, if it has one.
pub fn error(errors: List(FieldError), name: String) -> Option(String) {
  list.find(errors, fn(error) { error.field == name })
  |> result.map(fn(error) { error.message })
  |> option.from_result
}

// -- Typed fields ------------------------------------------------------------
//
// Like `validate.field`, the continuation always runs so that later fields
// are checked too. When a field cannot be read it runs with a placeholder
// and its result is discarded.

/// A required string, checked with `rules`. An empty value is kept.
pub fn string(
  form: Form,
  name: String,
  rules: List(Rule(String)),
  next: fn(String) -> validate.Result(b),
) -> validate.Result(b) {
  let value = result.try(single(form, name), option.to_result(_, required))
  field(name, value, "", rules, next)
}

/// An optional string, checked with `rules` when given. An absent or empty
/// value is `None`, as is one that `rules` leave empty, such as by trimming.
pub fn optional_string(
  form: Form,
  name: String,
  rules: List(Rule(String)),
  next: fn(Option(String)) -> validate.Result(b),
) -> validate.Result(b) {
  let blank_to_none = fn(value) {
    case value {
      Some("") -> Ok(None)
      _ -> Ok(value)
    }
  }
  let rules = [blank_to_none, optionally(rules), blank_to_none]
  field(name, single(form, name), None, rules, next)
}

/// A required integer, checked with `rules`. An empty value is missing.
pub fn int(
  form: Form,
  name: String,
  rules: List(Rule(Int)),
  next: fn(Int) -> validate.Result(b),
) -> validate.Result(b) {
  let value =
    result.try(optional_integer(form, name), option.to_result(_, required))
  field(name, value, 0, rules, next)
}

/// An optional integer, checked with `rules` when given. An absent or empty
/// value is `None`.
pub fn optional_int(
  form: Form,
  name: String,
  rules: List(Rule(Int)),
  next: fn(Option(Int)) -> validate.Result(b),
) -> validate.Result(b) {
  field(name, optional_integer(form, name), None, [optionally(rules)], next)
}

/// Whether a checkbox was ticked. Browsers leave unticked checkboxes out of
/// the submission, so this is `True` when the field is present at all.
pub fn checkbox(
  form: Form,
  name: String,
  next: fn(Bool) -> validate.Result(b),
) -> validate.Result(b) {
  next(all(form, name) != [])
}

/// Every value of a field that may repeat, such as a multi-select.
pub fn strings(
  form: Form,
  name: String,
  next: fn(List(String)) -> validate.Result(b),
) -> validate.Result(b) {
  next(all(form, name))
}

/// A required file, checked with `rules`.
pub fn file(
  form: Form,
  name: String,
  rules: List(Rule(UploadedFile)),
  next: fn(UploadedFile) -> validate.Result(b),
) -> validate.Result(b) {
  let value = result.try(single_file(form, name), option.to_result(_, required))
  field(name, value, UploadedFile("", "", 0, ""), rules, next)
}

/// An optional file, checked with `rules` when given.
pub fn optional_file(
  form: Form,
  name: String,
  rules: List(Rule(UploadedFile)),
  next: fn(Option(UploadedFile)) -> validate.Result(b),
) -> validate.Result(b) {
  field(name, single_file(form, name), None, [optionally(rules)], next)
}

/// Every file of a field that may hold several, such as an input with
/// `multiple`, each checked with `rules`.
pub fn files(
  form: Form,
  name: String,
  rules: List(Rule(UploadedFile)),
  next: fn(List(UploadedFile)) -> validate.Result(b),
) -> validate.Result(b) {
  let each = fn(files) { list.try_map(files, validate.run(rules, _)) }
  field(name, Ok(all_files(form, name)), [], [each], next)
}

/// A file of at most `bytes` bytes.
pub fn max_size(bytes: Int) -> Rule(UploadedFile) {
  fn(file: UploadedFile) {
    case file.size > bytes {
      True -> Error("must be at most " <> describe_size(bytes))
      False -> Ok(file)
    }
  }
}

/// A file whose claimed content type is one of `allowed`, such as
/// `"application/pdf"`, or matches a pattern such as `"image/*"`. The type
/// comes from the browser, so check the content too before relying on it.
pub fn file_type(allowed: List(String)) -> Rule(UploadedFile) {
  let allowed = list.map(allowed, string.lowercase)
  fn(file: UploadedFile) {
    let claimed = media_type(file.content_type)
    let matches = fn(pattern) {
      case string.ends_with(pattern, "/*") {
        True -> string.starts_with(claimed, string.drop_end(pattern, 1))
        False -> claimed == pattern
      }
    }
    case list.any(allowed, matches) {
      True -> Ok(file)
      False -> Error("must be " <> or_list(allowed))
    }
  }
}

const required = "is required"

/// The value of a field that must not repeat.
fn single(form: Form, name: String) -> Result(Option(String), String) {
  case all(form, name) {
    [] -> Ok(None)
    [value] -> Ok(Some(value))
    _ -> Error("must occur only once")
  }
}

fn single_file(
  form: Form,
  name: String,
) -> Result(Option(UploadedFile), String) {
  case all_files(form, name) {
    [] -> Ok(None)
    [file] -> Ok(Some(file))
    _ -> Error("must occur only once")
  }
}

fn describe_size(bytes: Int) -> String {
  let in = fn(unit, name) {
    case bytes >= unit && bytes % unit == 0 {
      True -> Ok(int.to_string(bytes / unit) <> " " <> name)
      False -> Error(Nil)
    }
  }
  in(1_048_576, "MB")
  |> result.lazy_or(fn() { in(1_000_000, "MB") })
  |> result.lazy_or(fn() { in(1024, "KB") })
  |> result.lazy_or(fn() { in(1000, "KB") })
  |> result.unwrap(int.to_string(bytes) <> " bytes")
}

fn or_list(items: List(String)) -> String {
  case list.reverse(items) {
    [] -> "nothing"
    [only] -> only
    [last, ..rest] -> string.join(list.reverse(rest), ", ") <> " or " <> last
  }
}

fn optional_integer(form: Form, name: String) -> Result(Option(Int), String) {
  use value <- result.try(single(form, name))
  case value {
    None | Some("") -> Ok(None)
    Some(value) ->
      case int.parse(value) {
        Ok(value) -> Ok(Some(value))
        Error(Nil) -> Error("must be an integer")
      }
  }
}

/// Apply rules to the value inside `Some`, leaving `None` alone.
fn optionally(rules: List(Rule(a))) -> Rule(Option(a)) {
  fn(value) {
    case value {
      Some(value) -> result.map(validate.run(rules, value), Some)
      None -> Ok(None)
    }
  }
}

fn field(
  name: String,
  value: Result(a, String),
  placeholder: a,
  rules: List(Rule(a)),
  next: fn(a) -> validate.Result(b),
) -> validate.Result(b) {
  case value {
    Ok(value) -> validate.field(name, value, rules, next)
    Error(message) ->
      validate.field(name, placeholder, [fn(_) { Error(message) }], next)
  }
}

// -- Parsing -----------------------------------------------------------------

type Encoding {
  Urlencoded
  Multipart(boundary: String)
}

fn encoding(ctx: GuardedContext(guarded)) -> Result(Encoding, service.Error) {
  let header =
    request.get_header(ctx.request, "content-type") |> result.unwrap("")
  let #(media, parameters) = case string.split(header, ";") {
    [media, ..parameters] -> #(media, parameters)
    [] -> #("", [])
  }
  case media_type(media) {
    "application/x-www-form-urlencoded" -> Ok(Urlencoded)
    "multipart/form-data" ->
      case boundary(parameters) {
        Ok(boundary) -> Ok(Multipart(boundary:))
        Error(Nil) ->
          Error(service.Invalid("multipart form has no valid boundary"))
      }
    _ ->
      Error(service.UnsupportedMediaType(
        "content type must be application/x-www-form-urlencoded or multipart/form-data",
      ))
  }
}

fn media_type(content_type: String) -> String {
  case string.split_once(content_type, ";") {
    Ok(#(media, _)) -> media
    Error(Nil) -> content_type
  }
  |> string.trim
  |> string.lowercase
}

/// The boundary parameter: 1 to 70 characters, perhaps quoted (RFC 2046).
fn boundary(parameters: List(String)) -> Result(String, Nil) {
  use parameter <- result.try(
    list.find_map(parameters, fn(parameter) {
      case string.split_once(string.trim(parameter), "=") {
        Ok(#(name, value)) ->
          case string.lowercase(string.trim(name)) {
            "boundary" -> Ok(string.trim(value))
            _ -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
    }),
  )
  let boundary = case
    string.starts_with(parameter, "\""),
    string.ends_with(parameter, "\"")
  {
    True, True if parameter != "\"" ->
      parameter |> string.drop_start(1) |> string.drop_end(1)
    _, _ -> parameter
  }
  case string.length(boundary) {
    length if length >= 1 && length <= 70 -> Ok(boundary)
    _ -> Error(Nil)
  }
}

fn parse(bits: BitArray) -> Result(Form, Nil) {
  use text <- result.try(bit_array.to_string(bits))
  use fields <- result.map(query.parse_query(text))
  Form(fields:, files: [])
}

fn invalid(ctx: GuardedContext(guarded), message: String) -> Response(Content) {
  service.error_response(ctx, service.Invalid(message))
}

// -- Multipart ---------------------------------------------------------------
//
// The body is read a piece at a time. Text fields are kept in memory and
// count towards the fields limit along with part headers and boundaries;
// files are appended to temporary files as they arrive and count towards
// the file limits. Every part ends at a delimiter: CRLF, `--` and the
// boundary. The first boundary has no CRLF before it, so reading starts
// with one, which makes everything before the first boundary a preamble to
// skip like any other.

type Reading {
  Reading(
    reader: context.Reader,
    limits: Limits,
    delimiter: BitArray,
    part: Part,
    fields: List(#(String, String)),
    files: List(#(String, UploadedFile)),
    fields_size: Int,
    files_size: Int,
    watcher: Option(Watcher),
    directory: String,
  )
}

/// The part being read.
type Part {
  /// Bytes to throw away: the preamble.
  Skipped
  TextField(name: String, value: BitArray)
  FileField(
    name: String,
    file_name: String,
    content_type: String,
    path: Option(String),
    size: Int,
  )
}

type Failure {
  TooLarge(String)
  Malformed(String)
  Unreadable
  Unwritable(String)
}

type Watcher

@external(erlang, "howdy_form_ffi", "watch")
fn watch() -> Watcher

@external(erlang, "howdy_form_ffi", "track")
fn track(watcher: Watcher, path: String) -> Nil

@external(erlang, "howdy_form_ffi", "finish")
fn finish(watcher: Watcher) -> Nil

@external(erlang, "howdy_form_ffi", "find")
fn find(data: BitArray, pattern: BitArray, from: Int) -> Result(Int, Nil)

@external(erlang, "howdy_form_ffi", "append")
fn append(path: String, data: BitArray) -> Result(Nil, String)

@external(erlang, "howdy_form_ffi", "default_temporary_directory")
fn default_temporary_directory() -> String

@external(erlang, "howdy_form_ffi", "random_name")
fn random_name() -> String

@external(erlang, "howdy_ffi", "cleanup")
fn cleanup(after cleanup: fn() -> b, run run: fn() -> a) -> a

fn read_multipart(
  ctx: GuardedContext(guarded),
  limits: Limits,
  boundary: String,
  next: fn(Form) -> Response(Content),
) -> Response(Content) {
  // Only a form that may take files needs its files deleted afterwards.
  let watcher = case limits.max_files > 0 {
    True -> Some(watch())
    False -> None
  }
  let reading =
    Reading(
      reader: context.reader(
        ctx.request,
        limit: limits.fields + total_file_size(limits),
      ),
      limits:,
      delimiter: <<"\r\n--":utf8, boundary:utf8>>,
      part: Skipped,
      fields: [],
      files: [],
      fields_size: 0,
      files_size: 0,
      watcher:,
      directory: option.lazy_unwrap(
        limits.directory,
        default_temporary_directory,
      ),
    )
  let finished = fn() { option.map(watcher, finish) }
  case read_part(reading, <<"\r\n":utf8>>) {
    Ok(form) ->
      case watcher {
        None -> next(form)
        Some(_) -> cleanup(after: finished, run: fn() { next(form) })
      }
    Error(failure) -> {
      finished()
      service.error_response(ctx, case failure {
        TooLarge(message) | Malformed(message) -> service.Invalid(message)
        Unreadable -> service.Invalid("request body could not be read")
        Unwritable(reason) ->
          service.Internal(
            "howdy/form: could not write an uploaded file: " <> reason,
          )
      })
    }
  }
}

/// Read the current part up to the delimiter that ends it, then what
/// follows.
fn read_part(reading: Reading, buffer: BitArray) -> Result(Form, Failure) {
  let size = bit_array.byte_size(buffer)
  let delimiter_size = bit_array.byte_size(reading.delimiter)
  case find(buffer, reading.delimiter, 0) {
    Ok(at) -> {
      use reading <- result.try(take(reading, slice(buffer, 0, at)))
      use reading <- result.try(end_part(reading))
      use reading <- result.try(charge(reading, delimiter_size))
      let rest = slice(buffer, at + delimiter_size, size - at - delimiter_size)
      after_delimiter(reading, rest)
    }
    Error(Nil) -> {
      // The end of the buffer may be the start of a delimiter, so keep it.
      let kept = int.min(size, delimiter_size - 1)
      use reading <- result.try(take(reading, slice(buffer, 0, size - kept)))
      use #(reading, more) <- result.try(more(reading))
      read_part(reading, <<slice(buffer, size - kept, kept):bits, more:bits>>)
    }
  }
}

/// A delimiter is followed by `--` after the last part, or by CRLF and the
/// headers of the next.
fn after_delimiter(
  reading: Reading,
  buffer: BitArray,
) -> Result(Form, Failure) {
  case buffer {
    <<"--":utf8, _:bits>> -> {
      use reading <- result.try(drain(reading))
      Ok(Form(
        fields: list.reverse(reading.fields),
        files: list.reverse(reading.files),
      ))
    }
    <<"\r\n":utf8, rest:bits>> -> {
      use reading <- result.try(charge(reading, 2))
      read_headers(reading, rest, 0)
    }
    <<>> | <<"-":utf8>> | <<"\r":utf8>> -> {
      use #(reading, more) <- result.try(more(reading))
      after_delimiter(reading, <<buffer:bits, more:bits>>)
    }
    _ -> Error(Malformed("multipart form has a malformed boundary"))
  }
}

/// Read a part's headers. The end of them is looked for from `from` on, so
/// headers sent a byte at a time are not searched again for each byte.
fn read_headers(
  reading: Reading,
  buffer: BitArray,
  from: Int,
) -> Result(Form, Failure) {
  let size = bit_array.byte_size(buffer)
  let found = case buffer {
    <<"\r\n":utf8, _:bits>> -> Ok(#(<<>>, 2))
    _ ->
      find(buffer, <<"\r\n\r\n":utf8>>, from)
      |> result.map(fn(at) { #(slice(buffer, 0, at), at + 4) })
  }
  case found {
    Ok(#(block, used)) -> {
      use reading <- result.try(charge(reading, used))
      use headers <- result.try(parse_headers(block))
      use part <- result.try(start_part(headers))
      read_part(Reading(..reading, part:), slice(buffer, used, size - used))
    }
    Error(Nil) -> {
      // Headers count as fields, so do not wait for more than could fit.
      use <- bool.guard(
        reading.fields_size + size > reading.limits.fields,
        Error(TooLarge("request body too large")),
      )
      use #(reading, more) <- result.try(more(reading))
      read_headers(reading, <<buffer:bits, more:bits>>, int.max(size - 3, 0))
    }
  }
}

fn parse_headers(block: BitArray) -> Result(List(#(String, String)), Failure) {
  let malformed = Malformed("multipart form has a malformed part header")
  use text <- result.try(
    bit_array.to_string(block) |> result.replace_error(malformed),
  )
  case text {
    "" -> Ok([])
    _ ->
      string.split(text, "\r\n")
      |> list.try_map(fn(line) {
        case string.split_once(line, ":") {
          Ok(#(name, value)) ->
            Ok(#(string.lowercase(string.trim(name)), string.trim(value)))
          Error(Nil) -> Error(malformed)
        }
      })
  }
}

fn start_part(headers: List(#(String, String))) -> Result(Part, Failure) {
  let disposition =
    list.key_find(headers, "content-disposition")
    |> result.try(parse_disposition)
  case disposition {
    Ok(#("form-data", parameters)) ->
      case list.key_find(parameters, "name") {
        Ok(name) ->
          case list.key_find(parameters, "filename") {
            Ok(file_name) -> {
              let content_type =
                list.key_find(headers, "content-type")
                |> result.unwrap("application/octet-stream")
              Ok(FileField(
                name:,
                file_name: base_name(file_name),
                content_type:,
                path: None,
                size: 0,
              ))
            }
            Error(Nil) -> Ok(TextField(name:, value: <<>>))
          }
        Error(Nil) -> Error(Malformed("multipart form has a part with no name"))
      }
    _ -> Error(Malformed("multipart form has a part that is not form-data"))
  }
}

/// A `Content-Disposition` value: its type, then its parameters with their
/// names lowercased. Browsers percent-encode quotes in a quoted value rather
/// than escape them, so a backslash, common in Windows paths, is kept as it
/// is (HTML's multipart/form-data encoding algorithm).
fn parse_disposition(
  value: String,
) -> Result(#(String, List(#(String, String))), Nil) {
  let #(kind, rest) = case string.split_once(value, ";") {
    Ok(#(kind, rest)) -> #(kind, rest)
    Error(Nil) -> #(value, "")
  }
  use parameters <- result.map(disposition_parameters(rest, []))
  #(string.lowercase(string.trim(kind)), parameters)
}

fn disposition_parameters(
  rest: String,
  parameters: List(#(String, String)),
) -> Result(List(#(String, String)), Nil) {
  case string.trim_start(rest) {
    "" -> Ok(list.reverse(parameters))
    rest -> {
      use #(name, rest) <- result.try(string.split_once(rest, "="))
      let name = string.lowercase(string.trim(name))
      use #(value, rest) <- result.try(case string.trim_start(rest) {
        "\"" <> quoted -> {
          use #(value, rest) <- result.try(string.split_once(quoted, "\""))
          case string.trim_start(rest) {
            "" -> Ok(#(value, ""))
            ";" <> rest -> Ok(#(value, rest))
            _ -> Error(Nil)
          }
        }
        token ->
          case string.split_once(token, ";") {
            Ok(#(value, rest)) -> Ok(#(string.trim(value), rest))
            Error(Nil) -> Ok(#(string.trim(token), ""))
          }
      })
      disposition_parameters(rest, [#(name, value), ..parameters])
    }
  }
}

/// Drop any directories, which old browsers sent in Windows form.
fn base_name(file_name: String) -> String {
  let last = fn(name, separator) {
    string.split(name, separator) |> list.last |> result.unwrap(name)
  }
  file_name |> last("/") |> last("\\")
}

/// Add bytes to the current part.
fn take(reading: Reading, data: BitArray) -> Result(Reading, Failure) {
  case bit_array.byte_size(data), reading.part {
    0, _ -> Ok(reading)
    size, Skipped -> charge(reading, size)
    size, TextField(name:, value:) -> {
      use reading <- result.try(charge(reading, size))
      Ok(
        Reading(
          ..reading,
          part: TextField(name:, value: <<value:bits, data:bits>>),
        ),
      )
    }
    size, FileField(..) as part -> {
      use #(reading, path) <- result.try(case part.path {
        Some(path) -> Ok(#(reading, path))
        None -> new_file(reading)
      })
      let limits = reading.limits
      use <- bool.guard(
        part.size + size > limits.max_file_size,
        Error(TooLarge("the file in " <> part.name <> " is too large")),
      )
      use <- bool.guard(
        reading.files_size + size > total_file_size(limits),
        Error(TooLarge("the files are too large")),
      )
      use Nil <- result.try(append(path, data) |> result.map_error(Unwritable))
      Ok(
        Reading(
          ..reading,
          files_size: reading.files_size + size,
          part: FileField(..part, path: Some(path), size: part.size + size),
        ),
      )
    }
  }
}

/// Count bytes that are not file contents against the fields limit.
fn charge(reading: Reading, size: Int) -> Result(Reading, Failure) {
  let fields_size = reading.fields_size + size
  case fields_size > reading.limits.fields {
    True -> Error(TooLarge("request body too large"))
    False -> Ok(Reading(..reading, fields_size:))
  }
}

/// A temporary file for the file part being read, tracked before it is
/// created so it is deleted however the request ends.
fn new_file(reading: Reading) -> Result(#(Reading, String), Failure) {
  case reading.watcher {
    None -> Error(TooLarge("this form does not accept files"))
    Some(watcher) -> {
      use <- bool.guard(
        list.length(reading.files) >= reading.limits.max_files,
        Error(TooLarge("too many files")),
      )
      use Nil <- result.try(
        simplifile.create_directory_all(reading.directory)
        |> result.map_error(fn(error) {
          Unwritable(simplifile.describe_error(error))
        }),
      )
      let path =
        filepath.join(reading.directory, "howdy-upload-" <> random_name())
      track(watcher, path)
      use Nil <- result.try(append(path, <<>>) |> result.map_error(Unwritable))
      Ok(#(reading, path))
    }
  }
}

fn end_part(reading: Reading) -> Result(Reading, Failure) {
  let reading = case reading.part {
    Skipped -> Ok(reading)
    TextField(name:, value:) ->
      case bit_array.to_string(value) {
        Ok(value) ->
          Ok(Reading(..reading, fields: [#(name, value), ..reading.fields]))
        Error(Nil) ->
          Error(Malformed("the field " <> name <> " is not valid UTF-8"))
      }
    // A file input left empty.
    FileField(path: None, file_name: "", ..) -> Ok(reading)
    FileField(name:, file_name:, content_type:, path:, size:) -> {
      use #(reading, path) <- result.try(case path {
        Some(path) -> Ok(#(reading, path))
        None -> new_file(reading)
      })
      let file = UploadedFile(file_name:, content_type:, size:, path:)
      Ok(Reading(..reading, files: [#(name, file), ..reading.files]))
    }
  }
  result.map(reading, fn(reading) { Reading(..reading, part: Skipped) })
}

/// The next piece of the body, which must not have ended yet.
fn more(reading: Reading) -> Result(#(Reading, BitArray), Failure) {
  case
    context.read_chunk(reading.reader, max_bytes: reading.limits.chunk_size)
  {
    Ok(Some(#(data, reader))) -> Ok(#(Reading(..reading, reader:), data))
    Ok(None) -> Error(Malformed("multipart form ended early"))
    Error(context.BodyTooLarge) -> Error(TooLarge("request body too large"))
    Error(context.InvalidBody) -> Error(Unreadable)
  }
}

/// Read and drop the epilogue after the last part.
fn drain(reading: Reading) -> Result(Reading, Failure) {
  case
    context.read_chunk(reading.reader, max_bytes: reading.limits.chunk_size)
  {
    Ok(Some(#(_, reader))) -> drain(Reading(..reading, reader:))
    Ok(None) -> Ok(reading)
    Error(context.BodyTooLarge) -> Error(TooLarge("request body too large"))
    Error(context.InvalidBody) -> Error(Unreadable)
  }
}

fn slice(bits: BitArray, from: Int, length: Int) -> BitArray {
  let assert Ok(part) = bit_array.slice(bits, from, length)
  part
}
