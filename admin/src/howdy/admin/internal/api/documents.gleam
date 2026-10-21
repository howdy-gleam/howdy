//// The OpenAPI documents the app serves, which one a page is about, and
//// the small pieces every API page shares.

import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam/uri
import howdy/admin/internal/api_spec.{type Document, type Operation}
import howdy/admin/internal/config.{type Api, type Config}
import howdy/openapi
import howdy/service
import howdy/ui
import howdy/ui/badge
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html

// -- Documents ---------------------------------------------------------------

/// The documents to offer: one per version when the app has versions, or
/// the one it serves.
pub fn documents(api: Api) -> List(openapi.Served) {
  case list.filter(api.documents, fn(served) { !served.main }) {
    [] -> api.documents
    versions -> versions
  }
}

pub fn key(served: openapi.Served) -> String {
  option.unwrap(served.version, "")
}

/// The document asked for by `version`, or the one the app serves at the
/// path given to `openapi.serve`.
pub fn pick(
  api: Api,
  version: String,
) -> Result(#(openapi.Served, Document), service.Error) {
  let offered = documents(api)
  let main =
    list.find(api.documents, fn(served) { served.main })
    |> result.map(key)
    |> result.unwrap("")
  let wanted = case version {
    "" -> main
    _ -> version
  }
  use served <- result.try(
    list.find(offered, fn(served) { key(served) == wanted })
    |> result.lazy_or(fn() { list.first(offered) })
    |> result.replace_error(service.NotFound("OpenAPI document")),
  )
  use document <- result.map(
    api_spec.parse(served.document)
    |> result.map_error(service.Invalid),
  )
  #(served, document)
}

pub fn operation_href(
  config: Config,
  served: openapi.Served,
  operation: Operation,
) -> String {
  config.path(config, "/api/operation?")
  <> uri.query_to_string([
    #("version", key(served)),
    #("method", operation.method),
    #("path", operation.path),
  ])
}

// -- Small pieces ------------------------------------------------------------

pub fn method_badge(method: String) -> Element(msg) {
  let variant = case method {
    "get" -> badge.Secondary
    "delete" -> badge.Danger
    _ -> badge.Primary
  }
  ui.badge(variant, [attribute.style("font-family", "var(--howdy-font-mono)")], [
    text(string.uppercase(method)),
  ])
}

pub fn status_badge(status: Int) -> Element(msg) {
  let variant = case status {
    s if s >= 400 -> badge.Danger
    s if s >= 300 -> badge.Outline
    0 -> badge.Outline
    _ -> badge.Primary
  }
  let label = case status {
    0 -> "default"
    s -> int.to_string(s)
  }
  ui.badge(variant, [], [text(label)])
}

pub fn monospace(value: String) -> Element(msg) {
  html.pre(
    [
      attribute.style("white-space", "pre-wrap"),
      attribute.style("overflow-wrap", "anywhere"),
      attribute.style("font-family", "var(--howdy-font-mono)"),
      attribute.style("font-size", "0.8125rem"),
      attribute.style("margin", "0"),
    ],
    [text(value)],
  )
}
