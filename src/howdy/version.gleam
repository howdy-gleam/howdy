//// Route requests to controllers by API version.
////
//// A version group resolves the requested version with one strategy, then
//// matches the request against that version's controllers. Later versions
//// fall back to earlier ones for any route they do not override, so a new
//// version only declares what changed.
////
//// ```gleam
//// import howdy/version
////
//// let api =
////   version.new(version.path())
////   |> version.default("v1")
////   |> version.add("v1", [user_v1.controller(), order.controller()])
////   |> version.add("v2", [user_v2.controller()])
////
//// howdy.new()
//// |> howdy.controller(status.controller())
//// |> howdy.versions(api)
//// |> howdy.handler
//// ```
////
//// With the path strategy `GET /v2/users` hits `user_v2` and `GET /v2/orders`
//// falls back to the `v1` order controller. `GET /users` uses the default
//// version. Handlers read the resolved version from `ctx.version`.
////
//// Strategies:
////
//// - `path()`: the first path segment, such as `/v2/users`. The segment is
////   removed before routing. A segment that is not a declared version is
////   left alone, so `/status` still reaches unversioned controllers.
//// - `header("x-api-version")`: a request header holding the version name.
//// - `accept("vnd.howdy")`: a vendor media type such as
////   `application/vnd.howdy.v2+json` in the `accept` header.
//// - `custom(fn)`: any function from the request to an optional version.
////
//// Only one strategy applies per app. Mixing strategies with precedence rules
//// makes requests ambiguous; if you need it, write a `custom` resolver.
////
//// Header, accept and custom strategies answer `400` for an unknown version
//// and, when no default is set, for a missing one. Header and accept also
//// add a `vary` header to every response from the group so caches keep
//// versions apart. The path strategy answers `404` in both cases, since the
//// path simply does not match anything.
////
//// Versions are opaque strings ordered by declaration. Configuration errors
//// such as duplicate version names panic when the app is built.

import gleam/dict.{type Dict}
import gleam/http/request.{type Request}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import howdy/context.{type Body}
import howdy/controller.{type Controller}

/// How the requested version is read from a request.
pub opaque type Resolver {
  Path
  Header(name: String)
  Accept(vendor: String)
  Custom(fn(Request(Body)) -> Option(String))
}

/// Read the version from the first path segment, such as `/v2/users`.
pub fn path() -> Resolver {
  Path
}

/// Read the version from a request header, such as `x-api-version: v2`.
pub fn header(name: String) -> Resolver {
  Header(string.lowercase(name))
}

/// Read the version from a vendor media type in the `accept` header.
/// `accept("vnd.howdy")` matches `application/vnd.howdy.v2+json`.
pub fn accept(vendor: String) -> Resolver {
  Accept(vendor)
}

/// Read the version with your own function. Return `None` when the request
/// carries no version.
pub fn custom(resolve: fn(Request(Body)) -> Option(String)) -> Resolver {
  Custom(resolve)
}

/// A set of versions, each with its own controllers.
pub opaque type Group {
  Group(
    resolver: Resolver,
    default: Option(String),
    fallback: Bool,
    versions: List(#(String, List(Controller))),
  )
}

/// Create a group that resolves versions with `resolver`. Fallback to
/// earlier versions is on; see `no_fallback`.
pub fn new(resolver: Resolver) -> Group {
  Group(resolver:, default: None, fallback: True, versions: [])
}

/// The version used when a request carries none. Must be added with `add`
/// before the app is built.
pub fn default(group: Group, name: String) -> Group {
  Group(..group, default: Some(name))
}

/// Make every version answer only the routes it declares itself.
pub fn no_fallback(group: Group) -> Group {
  Group(..group, fallback: False)
}

/// Add a version. Declaration order is the fallback order: a version falls
/// back to the ones added before it, newest first. Adding a version twice or
/// with an empty name panics.
pub fn add(group: Group, name: String, controllers: List(Controller)) -> Group {
  case name == "", is_known(group, name) {
    True, _ -> panic as "howdy/version: version names must not be empty"
    _, True -> panic as { "howdy/version: version " <> name <> " added twice" }
    False, False ->
      Group(
        ..group,
        versions: list.append(group.versions, [#(name, controllers)]),
      )
  }
}

// -- Reading a group ---------------------------------------------------------
//
// For packages that describe an app's routes, such as `howdy_openapi`.

/// How a group reads the version, as set by its resolver.
pub type Strategy {
  /// `path()`: the first path segment, as in `/v2/users`.
  PathStrategy
  /// `header(name)`: a request header. `name` is lowercase.
  HeaderStrategy(name: String)
  /// `accept(vendor)`: a vendor media type such as
  /// `application/vnd.howdy.v2+json`.
  AcceptStrategy(vendor: String)
  /// `custom(fn)`: a function that cannot be described.
  CustomStrategy
}

pub fn strategy(group: Group) -> Strategy {
  case group.resolver {
    Path -> PathStrategy
    Header(name) -> HeaderStrategy(name)
    Accept(vendor) -> AcceptStrategy(vendor)
    Custom(_) -> CustomStrategy
  }
}

/// The version names, in declaration order.
pub fn names(group: Group) -> List(String) {
  list.map(group.versions, fn(version) { version.0 })
}

/// The version a request without one gets, if the group has a default.
pub fn default_version(group: Group) -> Option(String) {
  group.default
}

/// The controllers that answer for a version, with fallback applied: its
/// own first, then earlier versions', newest first. The first route that
/// matches a request wins, so a version's overrides come before what it
/// inherits. `Error` for a version that was never added.
pub fn controllers(
  group: Group,
  name: String,
) -> Result(List(Controller), Nil) {
  dict.get(table(group), name)
}

/// The outcome of resolving a request's version.
@internal
pub type Resolved {
  /// A declared version, with the path the router should match.
  Version(name: String, path: String)
  /// The request cannot be served by the group and the client should be told
  /// why with a `400`.
  Missing(message: String)
  /// The request carries no version and the group has no default. The
  /// request is not for this group.
  NotVersioned
}

/// Work out which version a request asks for, applying the default.
@internal
pub fn resolve(group: Group, request: Request(Body)) -> Resolved {
  case group.resolver {
    Path -> resolve_path(group, request)
    Header(name) ->
      request.get_header(request, name)
      |> option.from_result
      |> resolve_named(group, request, _)
    Accept(vendor) ->
      request.get_header(request, "accept")
      |> option.from_result
      |> option.then(accept_version(_, vendor))
      |> resolve_named(group, request, _)
    Custom(resolve) -> resolve_named(group, request, resolve(request))
  }
}

fn resolve_path(group: Group, request: Request(Body)) -> Resolved {
  case controller.segments(request.path) {
    [first, ..rest] ->
      case is_known(group, first) {
        True -> Version(name: first, path: "/" <> string.join(rest, "/"))
        False -> resolve_default(group, request, or: NotVersioned)
      }
    [] -> resolve_default(group, request, or: NotVersioned)
  }
}

fn resolve_named(
  group: Group,
  request: Request(Body),
  name: Option(String),
) -> Resolved {
  case name {
    Some(name) ->
      case is_known(group, name) {
        True -> Version(name:, path: request.path)
        False -> Missing("unknown API version " <> name)
      }
    None -> resolve_default(group, request, or: Missing("missing API version"))
  }
}

fn resolve_default(
  group: Group,
  request: Request(Body),
  or missing: Resolved,
) -> Resolved {
  case group.default {
    Some(name) -> Version(name:, path: request.path)
    None -> missing
  }
}

/// Extract `v2` from `application/vnd.howdy.v2+json` when `vendor` is
/// `vnd.howdy`. The version runs until `+`, `;`, `,`, whitespace or the end.
fn accept_version(header: String, vendor: String) -> Option(String) {
  case string.split_once(header, vendor <> ".") {
    Ok(#(_, rest)) ->
      case take_until(string.to_graphemes(rest), "") {
        "" -> None
        name -> Some(name)
      }
    Error(Nil) -> None
  }
}

fn take_until(graphemes: List(String), acc: String) -> String {
  case graphemes {
    [] -> acc
    [char, ..rest] ->
      case char {
        "+" | ";" | "," | " " | "\t" -> acc
        _ -> take_until(rest, acc <> char)
      }
  }
}

/// The controllers to match for each version, with fallback applied. A
/// version's own controllers come first, then earlier versions' in reverse
/// declaration order, so `router.match` prefers overrides. Panics when the
/// default names a version that was never added.
@internal
pub fn table(group: Group) -> Dict(String, List(Controller)) {
  case group.default {
    Some(name) ->
      case is_known(group, name) {
        True -> Nil
        False ->
          panic as {
            "howdy/version: default version " <> name <> " was never added"
          }
      }
    None -> Nil
  }

  let #(table, _) =
    list.fold(group.versions, #(dict.new(), []), fn(acc, version) {
      let #(table, earlier) = acc
      let #(name, controllers) = version
      let all = case group.fallback {
        True -> list.append(controllers, earlier)
        False -> controllers
      }
      #(dict.insert(table, name, all), list.append(controllers, earlier))
    })
  table
}

/// The `vary` header value responses from the group should carry, if any.
@internal
pub fn vary_header(group: Group) -> Option(String) {
  case group.resolver {
    Path -> None
    Header(name) -> Some(name)
    Accept(_) -> Some("accept")
    Custom(_) -> None
  }
}

fn is_known(group: Group, name: String) -> Bool {
  list.any(group.versions, fn(version) { version.0 == name })
}
