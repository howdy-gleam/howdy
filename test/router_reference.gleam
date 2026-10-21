//// Frozen pre-compilation matcher used as an independent equivalence oracle.
//// Keep this implementation unchanged when optimizing production routing.

import gleam/dict.{type Dict}
import gleam/http.{type Method}
import gleam/list
import gleam/string
import howdy/controller.{type Controller, type Route}

import howdy/router.{type Match, Found, MethodNotAllowed, NotFound}

/// Find the first route, in declaration order, matching `method` and `path`.
pub fn match(
  controllers: List(Controller),
  method: Method,
  path: String,
) -> Match {
  let segments = controller.segments(path)

  let candidates =
    list.flat_map(controllers, fn(ctrl) {
      list.filter_map(controller.routes(ctrl), fn(route) {
        case match_segments(route.segments, segments, dict.new()) {
          Ok(params) -> Ok(Candidate(ctrl, route, params))
          Error(Nil) -> Error(Nil)
        }
      })
    })

  // Routes with a `*rest` segment are fallbacks. When any exact route
  // matches the path, only exact routes decide the handler and the
  // methods a `405` reports.
  let candidates = case
    list.partition(candidates, fn(candidate) { !is_wildcard(candidate.route) })
  {
    #([], wildcards) -> wildcards
    #(exact, _) -> exact
  }

  case
    list.find(candidates, fn(candidate) { candidate.route.method == method })
  {
    Ok(Candidate(route:, params:, ..)) ->
      Found(handler: route.handler, params:, route: pattern(route))
    Error(Nil) ->
      case candidates, head_fallback(candidates, method) {
        [], _ -> NotFound
        _, Ok(Candidate(route:, params:, ..)) ->
          Found(handler: route.handler, params:, route: pattern(route))
        [Candidate(controller: ctrl, params:, route:), ..], Error(Nil) -> {
          let allowed =
            candidates
            |> list.map(fn(candidate) { candidate.route.method })
            |> list.unique
            |> with_head
          case method {
            http.Options ->
              Found(
                handler: controller.options_handler(ctrl, allowed),
                params:,
                route: pattern(route),
              )
            _ -> MethodNotAllowed(allowed:)
          }
        }
      }
  }
}

/// A `HEAD` request with no `HEAD` route is answered by the first `GET` route.
fn head_fallback(
  candidates: List(Candidate),
  method: Method,
) -> Result(Candidate, Nil) {
  case method {
    http.Head ->
      list.find(candidates, fn(candidate) { candidate.route.method == http.Get })
    _ -> Error(Nil)
  }
}

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
    ["*" <> name], rest -> Ok(dict.insert(params, name, string.join(rest, "/")))
    [":" <> name, ..pattern], [value, ..path] ->
      match_segments(pattern, path, dict.insert(params, name, value))
    [expected, ..pattern], [actual, ..path] if expected == actual ->
      match_segments(pattern, path, params)
    _, _ -> Error(Nil)
  }
}

fn pattern(route: controller.Route) -> String {
  "/" <> string.join(route.segments, "/")
}
