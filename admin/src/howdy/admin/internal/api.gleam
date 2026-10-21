//// The API pages: the endpoints of the OpenAPI documents the app serves,
//// and a form on each to call it and see the response.
////
//// Calls go through the app in this process, with `howdy/testing.send`, so
//// they pass through the app's middleware and guards exactly as a request
//// from outside would, but need no network, CORS or CSRF token. To call as
//// a user, the admin issues a session for them with `auth.impersonate` and
//// sends its token as a bearer credential, which `auth.required` accepts
//// without an Origin. The token is kept for later calls, and replaced if
//// the app ever answers `401` to it.

import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import howdy/admin/internal/api/documents
import howdy/admin/internal/api/operation
import howdy/admin/internal/api_spec.{type Document, type Operation}
import howdy/admin/internal/config.{type Api, type Config}
import howdy/admin/internal/layout
import howdy/content.{type Content}
import howdy/controller.{type Context, type Controller}
import howdy/form
import howdy/openapi
import howdy/query
import howdy/ui
import howdy/ui/badge
import lustre/attribute
import lustre/element.{type Element, text}

pub fn controller(config: Config, api: Api) -> Controller {
  controller.new(config.prefix)
  |> controller.get("/api", fn(ctx) { index(config, api, ctx) })
  |> controller.get("/api/operation", fn(ctx) {
    operation.page(config, api, ctx, None)
  })
  |> controller.post("/api/operation", fn(ctx) {
    use fields <- form.read(ctx)
    operation.page(config, api, ctx, Some(fields))
  })
}

// -- Index -------------------------------------------------------------------

fn index(config: Config, api: Api, ctx: Context) -> Response(Content) {
  use version <- query.string_or(ctx, "version", default: "")
  case documents.pick(api, version) {
    Error(error) ->
      layout.failure(
        config,
        ctx,
        current: "/api",
        heading: "API",
        error:,
        back: config.path(config, ""),
      )
    Ok(#(served, document)) ->
      layout.page(
        config,
        ctx,
        current: "/api",
        heading: "API",
        live: False,
        content: [
          ui.stack([], [
            versions(config, api, served),
            about(served, document),
            ..list.map(by_tag(document.operations), fn(group) {
              let #(tag, operations) = group
              operations_card(config, served, document, tag, operations)
            })
          ]),
        ],
      )
  }
}

fn versions(config: Config, api: Api, current: openapi.Served) -> Element(msg) {
  case documents.documents(api) {
    [_, _, ..] as offered ->
      ui.row([], [
        ui.muted("Version"),
        ..list.map(offered, fn(served) {
          case documents.key(served) == documents.key(current) {
            True -> ui.badge(badge.Primary, [], [text(documents.key(served))])
            False ->
              ui.link(
                config.path(
                  config,
                  "/api?version=" <> uri.percent_encode(documents.key(served)),
                ),
                [text(documents.key(served))],
              )
          }
        })
      ])
    _ -> element.none()
  }
}

fn about(served: openapi.Served, document: Document) -> Element(msg) {
  ui.card([], [
    ui.card_header([], [
      ui.card_title([text(document.title)]),
      ui.card_description([
        text("Version " <> document.version <> " · "),
        ui.link(served.path, [text(served.path)]),
      ]),
    ]),
    case document.description {
      "" -> element.none()
      description -> ui.card_content([], [ui.p([text(description)])])
    },
  ])
}

/// Operations grouped by their first tag, in the order tags first appear.
fn by_tag(operations: List(Operation)) -> List(#(String, List(Operation))) {
  let tag_of = fn(operation: Operation) {
    list.first(operation.tags) |> result.unwrap("Other")
  }
  let tags = operations |> list.map(tag_of) |> list.unique
  list.map(tags, fn(tag) {
    #(tag, list.filter(operations, fn(operation) { tag_of(operation) == tag }))
  })
}

fn operations_card(
  config: Config,
  served: openapi.Served,
  document: Document,
  tag: String,
  operations: List(Operation),
) -> Element(msg) {
  ui.card([], [
    ui.card_header([], [ui.card_title([text(tag)])]),
    ui.card_content([], [
      ui.table([], [
        ui.table_body(
          [],
          list.map(operations, fn(operation) {
            ui.table_row([], [
              ui.table_cell([attribute.style("width", "5rem")], [
                documents.method_badge(operation.method),
              ]),
              ui.table_cell([], [
                ui.link(documents.operation_href(config, served, operation), [
                  layout.mono(operation.path),
                ]),
              ]),
              ui.table_cell([], [
                text(operation.summary),
                case operation.deprecated {
                  True -> ui.badge(badge.Outline, [], [text("deprecated")])
                  False -> element.none()
                },
              ]),
              ui.table_cell([attribute.style("text-align", "right")], [
                case api_spec.security_of(document, operation) {
                  [] -> element.none()
                  schemes ->
                    ui.badge(badge.Secondary, [], [
                      text("needs " <> string.join(schemes, ", ")),
                    ])
                },
              ]),
            ])
          }),
        ),
      ]),
    ]),
  ])
}
