//// Matches an incoming method and path against a set of controllers.

import gleam/dict.{type Dict}
import gleam/http.{type Method}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import howdy/controller.{
  type Controller, type Handler, type Middleware, type Route,
}

pub type Match {
  /// A route matched. Params are the values captured by `:name` segments
  /// and by a trailing `*name` segment, which holds the rest of the path.
  /// `route` is the pattern that matched, such as `/user/:id`.
  Found(handler: Handler, params: Dict(String, String), route: String)
  /// The path matched at least one route but none with this method. An
  /// `OPTIONS` request never produces this: it is answered by
  /// `controller.options_handler` instead, and neither does a `HEAD` request
  /// to a path with a `GET` route, which the `GET` handler answers. `allowed`
  /// lists `HEAD` wherever it lists `GET`.
  MethodNotAllowed(allowed: List(Method))
  /// Nothing matched the path.
  NotFound
}

/// A routing snapshot with middleware composed once, at handler construction.
///
/// Exact routes are indexed by segment count and first literal segment, so a
/// request only scans routes that could match it. Declaration order is kept
/// by numbering entries and merging the literal and parameter-first buckets
/// by that number, so which overlapping route wins is unchanged.
@internal
pub opaque type Table {
  Table(
    exact: Dict(Int, Bucket),
    wildcards: Bucket,
    middleware: List(Middleware),
  )
}

type Entry {
  Entry(index: Int, controller: Controller, route: Route)
}

/// Routes that share a shape, split by how their first segment matches.
/// `open` holds patterns whose first segment is a parameter or a wildcard,
/// or that have no segments at all; they can match any first segment.
type Bucket {
  Bucket(literal: Dict(String, List(Entry)), open: List(Entry))
}

@internal
pub fn compile(
  controllers: List(Controller),
  middleware: List(Middleware),
) -> Table {
  let entries =
    list.flat_map(controllers, fn(ctrl) {
      list.map(controller.routes(ctrl), fn(route) {
        Entry(
          0,
          ctrl,
          controller.Route(
            ..route,
            handler: controller.wrap_all(route.handler, middleware),
          ),
        )
      })
    })
    |> list.index_map(fn(entry, index) { Entry(..entry, index:) })
  let #(exact, wildcards) =
    list.partition(entries, fn(entry) { !is_wildcard(entry.route) })
  let exact =
    list.group(exact, fn(entry) { list.length(entry.route.segments) })
    |> dict.map_values(fn(_, entries) { bucket(list.reverse(entries)) })
  Table(exact:, wildcards: bucket(wildcards), middleware:)
}

/// Entries must be in declaration order; the bucket's lists keep it.
fn bucket(entries: List(Entry)) -> Bucket {
  let #(open, literal) =
    list.partition(entries, fn(entry) {
      case entry.route.segments {
        [":" <> _, ..] | ["*" <> _, ..] | [] -> True
        _ -> False
      }
    })
  let literal =
    list.group(literal, fn(entry) {
      let assert [first, ..] = entry.route.segments
      first
    })
    |> dict.map_values(fn(_, entries) { list.reverse(entries) })
  Bucket(literal:, open:)
}

/// The routes in a bucket that could match a path starting with `first`,
/// in declaration order.
fn candidates(bucket: Bucket, first: Option(String)) -> List(Entry) {
  let literal = case first {
    Some(first) -> dict.get(bucket.literal, first) |> result.unwrap([])
    None -> []
  }
  case literal, bucket.open {
    [], open -> open
    literal, [] -> literal
    literal, open -> merge(literal, open)
  }
}

fn merge(a: List(Entry), b: List(Entry)) -> List(Entry) {
  case a, b {
    [], rest | rest, [] -> rest
    [x, ..xs], [y, ..ys] ->
      case x.index < y.index {
        True -> [x, ..merge(xs, b)]
        False -> [y, ..merge(a, ys)]
      }
  }
}

/// Find the first route, in declaration order, matching `method` and `path`.
/// For repeated dispatch, `howdy.handler` compiles the table once.
pub fn match(
  controllers: List(Controller),
  method: Method,
  path: String,
) -> Match {
  match_table(compile(controllers, []), method, path)
}

@internal
pub fn match_table(table: Table, method: Method, path: String) -> Match {
  let segments = controller.segments(path)
  let first = option.from_result(list.first(segments))
  let exact =
    dict.get(table.exact, list.length(segments))
    |> result.map(candidates(_, first))
    |> result.unwrap([])
  case scan(exact, segments, method, [], None, None, table.middleware) {
    NotFound ->
      scan(
        candidates(table.wildcards, first),
        segments,
        method,
        [],
        None,
        None,
        table.middleware,
      )
    found -> found
  }
}

// Exact patterns always take precedence over wildcards, even if their methods
// do not match. Stop as soon as the first handler for the requested method wins.
// Only 405/implicit OPTIONS need the full list of matching methods.
//
// A `HEAD` request with no `HEAD` route of its own is answered by the first
// matching `GET` route, held in `get` until the scan shows no explicit `HEAD`
// route exists. The server drops the body of a response to `HEAD`.
fn scan(
  entries: List(Entry),
  path: List(String),
  method: Method,
  allowed: List(Method),
  first: Option(Candidate),
  get: Option(Candidate),
  middleware: List(Middleware),
) -> Match {
  case entries {
    [] ->
      case first, get {
        None, _ -> NotFound
        _, Some(Candidate(route:, params:, ..)) ->
          Found(handler: route.handler, params:, route: pattern(route))
        Some(Candidate(controller: ctrl, params:, route:)), None -> {
          let allowed = allowed |> list.reverse |> list.unique |> with_head
          case method {
            http.Options ->
              Found(
                handler: controller.options_handler(ctrl, allowed)
                  |> controller.wrap_all(middleware),
                params:,
                route: pattern(route),
              )
            _ -> MethodNotAllowed(allowed:)
          }
        }
      }
    [Entry(controller: ctrl, route:, ..), ..rest] ->
      case match_segments(route.segments, path, dict.new()) {
        Error(Nil) -> scan(rest, path, method, allowed, first, get, middleware)
        Ok(params) ->
          case route.method == method {
            True ->
              Found(handler: route.handler, params:, route: pattern(route))
            False -> {
              let candidate = Some(Candidate(ctrl, route, params))
              let first = option.or(first, candidate)
              let get = case method, route.method {
                http.Head, http.Get -> option.or(get, candidate)
                _, _ -> get
              }
              scan(
                rest,
                path,
                method,
                [route.method, ..allowed],
                first,
                get,
                middleware,
              )
            }
          }
      }
  }
}

/// A `GET` route also answers `HEAD`, so report it right after `GET`.
fn with_head(allowed: List(Method)) -> List(Method) {
  case list.contains(allowed, http.Head) {
    True -> allowed
    False ->
      list.flat_map(allowed, fn(method) {
        case method {
          http.Get -> [http.Get, http.Head]
          _ -> [method]
        }
      })
  }
}

fn pattern(route: Route) -> String {
  "/" <> string.join(route.segments, "/")
}

fn is_wildcard(route: Route) -> Bool {
  case list.last(route.segments) {
    Ok("*" <> _) -> True
    _ -> False
  }
}

type Candidate {
  Candidate(controller: Controller, route: Route, params: Dict(String, String))
}

fn match_segments(
  pattern: List(String),
  path: List(String),
  params: Dict(String, String),
) -> Result(Dict(String, String), Nil) {
  case pattern, path {
    [], [] -> Ok(params)
    ["*" <> name], rest ->
      case list.try_map(rest, decode_capture) {
        Ok(decoded) -> Ok(dict.insert(params, name, string.join(decoded, "/")))
        Error(Nil) -> Error(Nil)
      }
    [":" <> name, ..pattern], [value, ..path] ->
      case decode_capture(value) {
        Ok(decoded) ->
          match_segments(pattern, path, dict.insert(params, name, decoded))
        Error(Nil) -> Error(Nil)
      }
    [expected, ..pattern], [actual, ..path] if expected == actual ->
      match_segments(pattern, path, params)
    _, _ -> Error(Nil)
  }
}

/// A captured segment, percent-decoded so `/users/john%20doe` gives a param
/// of `"john doe"`. A segment that does not decode, or that hides a `/` or a
/// NUL behind an escape, matches nothing: the first is malformed, and the
/// other two would let one segment stand for several.
fn decode_capture(segment: String) -> Result(String, Nil) {
  case uri.percent_decode(segment) {
    Ok(decoded) ->
      case string.contains(decoded, "/") || string.contains(decoded, "\u{0}") {
        True -> Error(Nil)
        False -> Ok(decoded)
      }
    Error(Nil) -> Error(Nil)
  }
}
