//// Conditional requests: answer `304 Not Modified` when the client already
//// has the current version of a response, and `412 Precondition Failed`
//// when a write was based on a version that is no longer current.
////
//// Describe the version of what a handler is about to send with
//// validators, then let `when` decide whether to send it:
////
//// ```gleam
//// import howdy/conditional
////
//// fn show(ctx: Context) {
////   use id <- param.int(ctx, "id")
////   case notes.find(repo, id) {
////     Error(error) -> service.error_response(ctx, error)
////     Ok(note) -> {
////       use <- conditional.when(
////         ctx,
////         conditional.etag(["note", int.to_string(id), int.to_string(note.version)])
////           |> conditional.last_modified(note.updated_at),
////       )
////       controller.json(ctx, note_to_json(note))
////     }
////   }
//// }
//// ```
////
//// A browser that saw this note before sends its `etag` back in
//// `if-none-match`. While the note is unchanged it gets an empty `304` and
//// the rest of the handler never runs: the JSON is not built and the body
//// is not sent. The database read still happens, since that is what tells
//// the version; cache it with `howdy_cache` if it is the expensive part.
////
//// The response is `cache-control: private, no-cache` unless you say
//// otherwise with `cache_control`. Browsers keep it, but ask every time
//// whether it is still current, which is what makes the `304`s happen.
//// Shared caches never store it. A page that differs per user must put
//// the user in the etag too, so that one user's version is never confirmed
//// to another.
////
//// Static files from `howdy/static` use the same rules.

import gleam/bit_array
import gleam/bytes_tree
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import howdy/content.{type Content}
import howdy/controller.{type Context, type GuardedContext, type Next}

// -- Validators --------------------------------------------------------------

/// What identifies the version of a response: an entity tag, a
/// modification time, or both, and the `cache-control` to send with it.
pub opaque type Validators {
  Validators(
    etag: Option(String),
    last_modified: Option(Int),
    cache_control: Option(CacheControl),
  )
}

/// A weak entity tag hashed from `parts`. List whatever changes when the
/// response would change: a record's id and version or update time, the
/// signed-in user for a per-user page, the language for a translated one.
///
/// Weak means the tag vouches for the data, not for the exact bytes, which
/// is right for a response rendered from data: the same note still has the
/// same tag after a gzip middleware compresses it. Use `strong_etag` to
/// protect writes with `if-match`.
pub fn etag(parts: List(String)) -> Validators {
  with_etag(weak_tag(parts))
}

/// A strong entity tag hashed from `parts`: a promise that responses with
/// the same tag are byte-for-byte the same. `if-match` compares only strong
/// tags, so a handler that guards writes with `when` needs one.
pub fn strong_etag(parts: List(String)) -> Validators {
  with_etag(strong_tag(parts))
}

/// Validators with only a modification time, in seconds since the Unix
/// epoch. HTTP dates carry whole seconds, so two changes within the same
/// second look like one; prefer an etag when that matters.
pub fn modified_at(seconds: Int) -> Validators {
  Validators(etag: None, last_modified: Some(seconds), cache_control: default)
}

/// Add a modification time to validators that have an etag. Clients that
/// send `if-none-match` are judged by the etag alone; older clients and
/// some proxies use the time.
pub fn last_modified(validators: Validators, seconds: Int) -> Validators {
  Validators(..validators, last_modified: Some(seconds))
}

/// Send `policy` as the `cache-control` of the response and of its `304`,
/// instead of `private, no-cache`.
pub fn cache_control(
  validators: Validators,
  policy: CacheControl,
) -> Validators {
  Validators(..validators, cache_control: Some(policy))
}

/// Leave `cache-control` alone: the response keeps whatever the handler
/// set, and a `304` carries none.
pub fn without_cache_control(validators: Validators) -> Validators {
  Validators(..validators, cache_control: None)
}

/// An entity tag exactly as given, already quoted, such as `"\"v42\""` or
/// `"W/\"v42\""`. For a version the application already stores, such as a
/// content hash; `etag` and `strong_etag` hash parts for you.
pub fn quoted_etag(tag: String) -> Validators {
  with_etag(tag)
}

const default = Some(CacheControl(Private, None, None, None, False, False))

fn with_etag(tag: String) -> Validators {
  Validators(etag: Some(tag), last_modified: None, cache_control: default)
}

fn weak_tag(parts: List(String)) -> String {
  "W/" <> strong_tag(parts)
}

fn strong_tag(parts: List(String)) -> String {
  // Each part is length-prefixed, so ["ab", "c"] and ["a", "bc"] differ.
  let source =
    list.fold(parts, bytes_tree.new(), fn(tree, part) {
      tree
      |> bytes_tree.append_string(int.to_string(string.byte_size(part)))
      |> bytes_tree.append_string(":")
      |> bytes_tree.append_string(part)
    })
  quote(bytes_tree.to_bit_array(source))
}

fn quote(source: BitArray) -> String {
  "\"" <> bit_array.base64_url_encode(digest(source), False) <> "\""
}

@external(erlang, "howdy_conditional_ffi", "digest")
fn digest(source: BitArray) -> BitArray

// -- Answering ---------------------------------------------------------------

/// Answer from the validators when the request's conditions allow it,
/// otherwise run `respond` and stamp the validators on its response.
///
/// - `GET` and `HEAD` get a `304` with no body when `if-none-match` names
///   the current etag, or, without `if-none-match`, when
///   `if-modified-since` is no earlier than the modification time.
/// - Any method gets a `412` when `if-match` names no current strong etag,
///   or, without `if-match`, when the resource changed after
///   `if-unmodified-since`. Other methods also get a `412` when
///   `if-none-match` matches. This is how a `PUT` is refused when the
///   client edited an old copy; describe the version as it is before the
///   write.
///
/// Only a `2xx` response to `GET` or `HEAD` gets the validators. A
/// response to a write describes the new version, which these validators
/// do not, and an error is not a version at all. Headers the handler set
/// itself are kept.
pub fn when(
  ctx: GuardedContext(guarded),
  validators: Validators,
  respond: fn() -> Response(Content),
) -> Response(Content) {
  let reading = is_read(ctx.request)
  case evaluate(ctx.request, validators, reading) {
    NotModified ->
      response.new(304)
      |> response.set_body(content.Empty)
      |> stamp(validators, replace: True)
    PreconditionFailed -> precondition_failed()
    Proceed -> {
      let response = respond()
      case reading && response.status >= 200 && response.status < 300 {
        True -> stamp(response, validators, replace: False)
        False -> response
      }
    }
  }
}

/// Whether the client's copy is current: what `when` uses to decide on a
/// `304`, for handlers that build their own response. Always `False` for
/// methods other than `GET` and `HEAD`.
pub fn is_fresh(ctx: GuardedContext(guarded), validators: Validators) -> Bool {
  let reading = is_read(ctx.request)
  reading && evaluate(ctx.request, validators, reading) == NotModified
}

/// Middleware that gives every `200` text or bytes response to a `GET` or
/// `HEAD` a weak etag hashed from its body, and answers `304` when the
/// client already has that body.
///
/// ```gleam
/// howdy.new() |> howdy.middleware(conditional.auto_etag)
/// ```
///
/// The handler still runs in full, so this saves bandwidth, not work: use
/// `when` where building the response is the cost. Responses that already
/// have an etag, say `cache-control: no-store`, set a cookie, or stream
/// their body (files, server-sent events, chunked bodies) are left alone.
pub fn auto_etag(ctx: Context, next: Next) -> Response(Content) {
  let response = next(ctx)
  case is_read(ctx.request) && response.status == 200 {
    False -> response
    True ->
      case body_bits(response.body), skip_auto_etag(response) {
        Ok(bits), False -> {
          let tag = "W/" <> quote(bits)
          let response = response.set_header(response, "etag", tag)
          case request.get_header(ctx.request, "if-none-match") {
            Ok(header) ->
              case matches(header, tag, weak_equal) {
                True -> not_modified_from(response)
                False -> response
              }
            Error(Nil) -> response
          }
        }
        _, _ -> response
      }
  }
}

fn skip_auto_etag(response: Response(Content)) -> Bool {
  let has = fn(name) { result_is_ok(response.get_header(response, name)) }
  has("etag")
  || has("set-cookie")
  || case response.get_header(response, "cache-control") {
    Ok(value) -> string.contains(string.lowercase(value), "no-store")
    Error(Nil) -> False
  }
}

fn result_is_ok(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn body_bits(body: Content) -> Result(BitArray, Nil) {
  case body {
    content.Text(text) -> Ok(bit_array.from_string(text))
    content.Bytes(tree) -> Ok(bytes_tree.to_bit_array(tree))
    content.Empty | content.Native(_) -> Error(Nil)
  }
}

/// A `304` keeps the headers a cache needs to update what it stored, and
/// drops those that describe the body it no longer has.
fn not_modified_from(response: Response(Content)) -> Response(Content) {
  let headers =
    list.filter(response.headers, fn(header) {
      !list.contains(["content-type", "content-length"], header.0)
    })
  response.Response(status: 304, headers:, body: content.Empty)
}

type Outcome {
  Proceed
  NotModified
  PreconditionFailed
}

fn is_read(req: Request(a)) -> Bool {
  req.method == http.Get || req.method == http.Head
}

/// RFC 9110, section 13.2.2: `if-match` (or else `if-unmodified-since`)
/// first, then `if-none-match` (or else `if-modified-since`).
fn evaluate(req: Request(a), validators: Validators, reading: Bool) -> Outcome {
  case write_precondition_holds(req, validators) {
    False -> PreconditionFailed
    True ->
      case request.get_header(req, "if-none-match") {
        Ok(header) ->
          case validators.etag {
            Some(tag) ->
              case matches(header, tag, weak_equal) {
                True if reading -> NotModified
                True -> PreconditionFailed
                False -> Proceed
              }
            None ->
              case string.trim(header) == "*" {
                True if reading -> NotModified
                True -> PreconditionFailed
                False -> Proceed
              }
          }
        Error(Nil) ->
          case reading, validators.last_modified {
            True, Some(modified) ->
              case header_date(req, "if-modified-since") {
                Ok(since) if modified <= since -> NotModified
                _ -> Proceed
              }
            _, _ -> Proceed
          }
      }
  }
}

fn write_precondition_holds(req: Request(a), validators: Validators) -> Bool {
  case request.get_header(req, "if-match") {
    Ok(header) ->
      string.trim(header) == "*"
      || case validators.etag {
        Some(tag) -> matches(header, tag, strong_equal)
        None -> False
      }
    Error(Nil) ->
      case validators.last_modified, header_date(req, "if-unmodified-since") {
        Some(modified), Ok(since) -> modified <= since
        _, _ -> True
      }
  }
}

fn header_date(req: Request(a), name: String) -> Result(Int, Nil) {
  case request.get_header(req, name) {
    Ok(value) -> parse_http_date(string.trim(value))
    Error(Nil) -> Error(Nil)
  }
}

/// Whether a list of entity tags from a request header names `tag`.
fn matches(
  header: String,
  tag: String,
  equal: fn(String, String) -> Bool,
) -> Bool {
  header
  |> entity_tags
  |> list.any(fn(candidate) { candidate == "*" || equal(candidate, tag) })
}

/// The entity tags listed in an `if-match` or `if-none-match` header. A
/// quoted tag may itself contain commas, so commas only separate tags
/// outside quotes. Read byte by byte: as graphemes, a quote followed by a
/// combining mark would be one character, and the quote would be missed.
fn entity_tags(header: String) -> List(String) {
  split_tags(<<header:utf8>>, <<>>, False, [])
}

fn split_tags(
  rest: BitArray,
  current: BitArray,
  quoted: Bool,
  tags: List(String),
) -> List(String) {
  case rest, quoted {
    <<>>, _ -> list.reverse(add_tag(tags, current))
    <<",", rest:bits>>, False ->
      split_tags(rest, <<>>, False, add_tag(tags, current))
    <<"\"", rest:bits>>, _ ->
      split_tags(rest, <<current:bits, "\"">>, !quoted, tags)
    <<byte, rest:bits>>, _ ->
      split_tags(rest, <<current:bits, byte>>, quoted, tags)
    _, _ -> list.reverse(add_tag(tags, current))
  }
}

/// Only ASCII bytes split a tag, so each piece is still valid UTF-8.
fn add_tag(tags: List(String), tag: BitArray) -> List(String) {
  case bit_array.to_string(tag) {
    Ok(tag) ->
      case string.trim(tag) {
        "" -> tags
        tag -> [tag, ..tags]
      }
    Error(Nil) -> tags
  }
}

fn weak_equal(a: String, b: String) -> Bool {
  opaque_tag(a) == opaque_tag(b)
}

fn strong_equal(a: String, b: String) -> Bool {
  !string.starts_with(a, "W/") && !string.starts_with(b, "W/") && a == b
}

fn opaque_tag(tag: String) -> String {
  case tag {
    "W/" <> rest -> rest
    _ -> tag
  }
}

fn stamp(
  response: Response(Content),
  validators: Validators,
  replace replace: Bool,
) -> Response(Content) {
  let set = fn(response, name, value) {
    case replace, response.get_header(response, name) {
      False, Ok(_) -> response
      _, _ -> response.set_header(response, name, value)
    }
  }
  let response = case validators.etag {
    Some(tag) -> set(response, "etag", tag)
    None -> response
  }
  let response = case validators.last_modified {
    Some(seconds) -> set(response, "last-modified", http_date(seconds))
    None -> response
  }
  case validators.cache_control {
    Some(policy) -> set(response, "cache-control", to_string(policy))
    None -> response
  }
}

fn precondition_failed() -> Response(Content) {
  response.new(412)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_body(
    content.Text(
      json.to_string(
        json.object([#("error", json.string("precondition failed"))]),
      ),
    ),
  )
}

// -- Cache-Control -------------------------------------------------------------

/// Who may store a response, and for how long it counts as current.
/// Start from `private`, `public` or `no_store`.
pub opaque type CacheControl {
  CacheControl(
    scope: Scope,
    max_age: Option(Int),
    shared_max_age: Option(Int),
    stale_while_revalidate: Option(Int),
    must_revalidate: Bool,
    immutable: Bool,
  )
}

type Scope {
  Private
  Public
  NoStore
}

/// Only the user's browser may store the response, and it asks whether
/// its copy is current before each use: `private, no-cache`. The default
/// for `when`, and right for anything that differs per user.
pub fn private() -> CacheControl {
  CacheControl(Private, None, None, None, False, False)
}

/// Shared caches such as a CDN may store the response too: `public,
/// no-cache`. Only for responses that are the same for everyone.
pub fn public() -> CacheControl {
  CacheControl(Public, None, None, None, False, False)
}

/// Nobody may store the response: `no-store`. For secrets, and anything
/// that must never be shown from a cache, such as a page after sign-out.
/// The other settings are ignored.
pub fn no_store() -> CacheControl {
  CacheControl(NoStore, None, None, None, False, False)
}

/// Use a stored copy for `seconds` without asking, instead of asking every
/// time.
pub fn max_age(policy: CacheControl, seconds: Int) -> CacheControl {
  CacheControl(..policy, max_age: Some(int.max(seconds, 0)))
}

/// A different `max_age` for shared caches: `s-maxage`. Lets a CDN keep a
/// page for minutes while browsers ask every time.
pub fn shared_max_age(policy: CacheControl, seconds: Int) -> CacheControl {
  CacheControl(..policy, shared_max_age: Some(int.max(seconds, 0)))
}

/// After `max_age` runs out, keep serving the stored copy for up to
/// `seconds` more while fetching a new one in the background.
pub fn stale_while_revalidate(
  policy: CacheControl,
  seconds: Int,
) -> CacheControl {
  CacheControl(..policy, stale_while_revalidate: Some(int.max(seconds, 0)))
}

/// Never use the stored copy once `max_age` has run out, even when the
/// server cannot be reached.
pub fn must_revalidate(policy: CacheControl) -> CacheControl {
  CacheControl(..policy, must_revalidate: True)
}

/// The response at this URL never changes, so browsers need not ask even
/// when the user reloads. For fingerprinted assets, with a long `max_age`.
pub fn immutable(policy: CacheControl) -> CacheControl {
  CacheControl(..policy, immutable: True)
}

/// The `cache-control` header value.
pub fn to_string(policy: CacheControl) -> String {
  case policy.scope {
    NoStore -> "no-store"
    scope -> {
      let seconds = fn(name, value) {
        case value {
          Some(seconds) -> [name <> "=" <> int.to_string(seconds)]
          None -> []
        }
      }
      let flag = fn(name, on) {
        case on {
          True -> [name]
          False -> []
        }
      }
      [
        [
          case scope {
            Public -> "public"
            _ -> "private"
          },
        ],
        // `no-cache` binds shared caches too, and makes the settings below
        // meaningless, so it is only sent when there are none.
        case policy.max_age, needs_freshness(policy) {
          Some(_), _ -> seconds("max-age", policy.max_age)
          None, True -> ["max-age=0"]
          None, False -> ["no-cache"]
        },
        seconds("s-maxage", policy.shared_max_age),
        seconds("stale-while-revalidate", policy.stale_while_revalidate),
        flag("must-revalidate", policy.must_revalidate),
        flag("immutable", policy.immutable),
      ]
      |> list.flatten
      |> string.join(", ")
    }
  }
}

fn needs_freshness(policy: CacheControl) -> Bool {
  option.is_some(policy.shared_max_age)
  || option.is_some(policy.stale_while_revalidate)
  || policy.immutable
}

/// Set the `cache-control` header of a response, for handlers that do not
/// go through `when`.
pub fn set_cache_control(
  response: Response(Content),
  policy: CacheControl,
) -> Response(Content) {
  response.set_header(response, "cache-control", to_string(policy))
}

/// Add header names to the response's `vary`, keeping any already there.
/// A cache stores one copy per combination of these request headers, so
/// list every header that changes the response: `accept` for content
/// negotiation, `accept-language` for translations.
pub fn vary(
  response: Response(Content),
  headers: List(String),
) -> Response(Content) {
  let existing = case response.get_header(response, "vary") {
    Ok(value) ->
      value
      |> string.split(",")
      |> list.map(string.trim)
      |> list.filter(fn(name) { name != "" })
    Error(Nil) -> []
  }
  let names =
    list.fold(headers, existing, fn(names, name) {
      let name = string.lowercase(string.trim(name))
      case
        name == ""
        || list.any(names, fn(seen) { string.lowercase(seen) == name })
      {
        True -> names
        False -> list.append(names, [name])
      }
    })
  response.set_header(response, "vary", string.join(names, ", "))
}

// -- HTTP dates ----------------------------------------------------------------

/// Seconds since the Unix epoch as an HTTP date, such as
/// `Sun, 06 Nov 1994 08:49:37 GMT`.
@external(erlang, "howdy_conditional_ffi", "http_date")
pub fn http_date(seconds: Int) -> String

/// An HTTP date back to seconds since the Unix epoch. Accepts the
/// preferred format and the two obsolete ones HTTP still allows,
/// `Sunday, 06-Nov-94 08:49:37 GMT` and `Sun Nov  6 08:49:37 1994`.
@external(erlang, "howdy_conditional_ffi", "parse_http_date")
pub fn parse_http_date(date: String) -> Result(Int, Nil)
