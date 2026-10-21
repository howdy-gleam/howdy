//// One operation: what it does, a form to call it, the response, and
//// the schemas of what it takes and returns.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/float
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import howdy/admin/internal/api/calling
import howdy/admin/internal/api/documents
import howdy/admin/internal/api_spec.{
  type Document, type Operation, type Parameter, ApiKey, Bearer, Other,
}
import howdy/admin/internal/config.{type Api, type Config}
import howdy/admin/internal/layout
import howdy/auth/user.{type User}
import howdy/auth/users
import howdy/content.{type Content}
import howdy/controller.{type Context}
import howdy/form
import howdy/openapi
import howdy/query
import howdy/service
import howdy/ui
import howdy/ui/badge
import howdy/ui/button
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html

pub fn page(
  config: Config,
  api: Api,
  ctx: Context,
  submitted: Option(form.Form),
) -> Response(Content) {
  use version <- query.string_or(ctx, "version", default: "")
  use method <- query.string(ctx, "method")
  use path <- query.string(ctx, "path")
  let found = {
    use #(served, document) <- result.try(documents.pick(api, version))
    use operation <- result.map(
      list.find(document.operations, fn(operation) {
        operation.method == method && operation.path == path
      })
      |> result.replace_error(service.NotFound("operation")),
    )
    #(served, document, operation)
  }
  case found {
    Error(error) ->
      layout.failure(
        config,
        ctx,
        current: "/api",
        heading: "API",
        error:,
        back: config.path(config, "/api"),
      )
    Ok(#(served, document, operation)) -> {
      let outcome =
        option.map(submitted, calling.call(
          config,
          api,
          ctx,
          document,
          operation,
          _,
        ))
      let values = case submitted {
        Some(fields) -> dict.from_list(form.fields(fields))
        None -> defaults(document, operation)
      }
      // Listed once here, for the "Send as" select, not on every render.
      let accounts = case config.identity {
        None -> None
        Some(identity) ->
          Some(users.list(identity) |> result.unwrap([]) |> list.take(200))
      }
      layout.page(
        config,
        ctx,
        current: "/api",
        heading: string.uppercase(method) <> " " <> path,
        live: False,
        content: [
          ui.stack([], [
            ui.p([
              ui.link(
                config.path(
                  config,
                  "/api?version=" <> uri.percent_encode(documents.key(served)),
                ),
                [text("All endpoints")],
              ),
            ]),
            summary_card(document, operation),
            request_card(config, served, document, operation, values, accounts),
            case outcome {
              Some(outcome) -> outcome_card(outcome)
              None -> element.none()
            },
            responses_card(document, operation),
            case operation.body {
              Some(schema) -> schema_card("Request body", document, schema)
              None -> element.none()
            },
          ]),
        ],
      )
    }
  }
}

fn summary_card(document: Document, operation: Operation) -> Element(msg) {
  ui.card([], [
    ui.card_header([], [
      ui.card_title([
        documents.method_badge(operation.method),
        text(" "),
        text(case operation.summary {
          "" -> operation.path
          summary -> summary
        }),
      ]),
      ui.card_description([
        text(string.join(operation.tags, ", ")),
        case operation.id {
          "" -> element.none()
          id -> text(" · " <> id)
        },
      ]),
    ]),
    ui.card_content([], [
      case operation.description {
        "" -> element.none()
        description -> ui.p([text(description)])
      },
      case operation.deprecated {
        True -> ui.p([ui.badge(badge.Outline, [], [text("deprecated")])])
        False -> element.none()
      },
      case api_spec.security_of(document, operation) {
        [] -> ui.p([ui.muted("No authentication documented.")])
        schemes ->
          ui.p([
            ui.muted("Requires " <> string.join(schemes, " or ") <> "."),
          ])
      },
    ]),
  ])
}

/// Starting values: the only value a parameter can take, such as a version
/// header, and an example body from its schema.
fn defaults(document: Document, operation: Operation) -> Dict(String, String) {
  let parameters =
    list.map(operation.parameters, fn(parameter) {
      #(calling.field_name(parameter), api_spec.preset(parameter.schema))
    })
  let body = case operation.body {
    Some(schema) -> [
      #("body", api_spec.pretty(api_spec.example(document, schema))),
    ]
    None -> []
  }
  dict.from_list(list.append(parameters, body))
}

fn request_card(
  config: Config,
  served: openapi.Served,
  document: Document,
  operation: Operation,
  values: Dict(String, String),
  accounts: Option(List(User)),
) -> Element(msg) {
  let value = fn(name) { dict.get(values, name) |> result.unwrap("") }
  let required = api_spec.security_of(document, operation)
  ui.card([], [
    ui.card_header([], [
      ui.card_title([text("Try it")]),
      ui.card_description([
        text(
          "Sent through the app in this process, past its middleware and guards.",
        ),
      ]),
    ]),
    ui.card_content([], [
      html.form(
        [
          attribute.method("post"),
          attribute.action(documents.operation_href(config, served, operation)),
        ],
        [
          ui.stack([], [
            identity_field(accounts, value("as")),
            ..list.flatten([
              list.filter_map(document.schemes, fn(entry) {
                let #(name, scheme) = entry
                case list.contains(required, name) {
                  True ->
                    Ok(scheme_field(name, scheme, value("scheme:" <> name)))
                  False -> Error(Nil)
                }
              }),
              list.map(operation.parameters, fn(parameter) {
                parameter_field(parameter, value(calling.field_name(parameter)))
              }),
              case operation.body {
                Some(_) -> [
                  ui.field([], [
                    ui.label([attribute.for("body")], [text("Body (JSON)")]),
                    ui.textarea(
                      [
                        attribute.id("body"),
                        attribute.name("body"),
                        attribute.rows(12),
                        attribute.style("font-family", "var(--howdy-font-mono)"),
                        attribute.attribute("spellcheck", "false"),
                      ],
                      value("body"),
                    ),
                  ]),
                ]
                None -> []
              },
              [
                ui.row([], [
                  ui.submit_button(button.Primary, [], [text("Send request")]),
                ]),
              ],
            ])
          ]),
        ],
      ),
    ]),
  ])
}

/// Who to send as, from the users listed for this request; nothing
/// without auth.
fn identity_field(
  accounts: Option(List(User)),
  selected: String,
) -> Element(msg) {
  case accounts {
    None -> element.none()
    Some(listed) -> {
      ui.field([], [
        ui.label([attribute.for("as")], [text("Send as")]),
        ui.native_select([attribute.id("as"), attribute.name("as")], [
          html.option(
            [attribute.value(""), attribute.selected(selected == "")],
            "Nobody (no session)",
          ),
          ..list.map(listed, fn(account) {
            html.option(
              [
                attribute.value(account.id),
                attribute.selected(selected == account.id),
              ],
              account.email,
            )
          })
        ]),
        ui.field_description([], [
          text(
            "Signs in as the user with a session of the admin's own, sent as a bearer token. Guards see a real session.",
          ),
        ]),
      ])
    }
  }
}

fn scheme_field(
  name: String,
  scheme: api_spec.Scheme,
  value: String,
) -> Element(msg) {
  let id = "scheme:" <> name
  let #(label, description) = case scheme {
    Bearer -> #(name <> " token", "Sent as authorization: Bearer <token>.")
    ApiKey(location:, name: key) -> #(
      name,
      "Sent in the " <> key <> " " <> location <> ".",
    )
    Other(kind) -> #(
      name,
      "A " <> kind <> " scheme; the admin cannot send it for you.",
    )
  }
  ui.field([], [
    ui.label([attribute.for(id)], [text(label)]),
    ui.input([attribute.id(id), attribute.name(id), attribute.value(value)]),
    ui.field_description([], [text(description)]),
  ])
}

fn parameter_field(parameter: Parameter, value: String) -> Element(msg) {
  let id = calling.field_name(parameter)
  let kind = case parameter.schema {
    Some(schema) -> api_spec.type_text(schema)
    None -> "string"
  }
  let notes = case parameter.schema {
    Some(schema) -> api_spec.notes(schema)
    None -> ""
  }
  let input = case api_spec.choices(parameter.schema) {
    [] ->
      ui.input([
        attribute.id(id),
        attribute.name(id),
        attribute.value(value),
        attribute.required(parameter.required),
        attribute.placeholder(case api_spec.is_array(parameter.schema) {
          True -> "values, separated by commas"
          False -> kind
        }),
      ])
    choices ->
      ui.native_select([attribute.id(id), attribute.name(id)], [
        html.option([attribute.value("")], ""),
        ..list.map(choices, fn(choice) {
          html.option(
            [attribute.value(choice), attribute.selected(choice == value)],
            choice,
          )
        })
      ])
  }
  ui.field([], [
    ui.label([attribute.for(id)], [
      text(parameter.name),
      case parameter.required {
        True -> text(" *")
        False -> element.none()
      },
    ]),
    input,
    ui.field_description([], [
      text(
        [parameter.location <> " · " <> kind, notes, parameter.description]
        |> list.filter(fn(part) { part != "" })
        |> string.join(" · "),
      ),
    ]),
  ])
}

fn responses_card(document: Document, operation: Operation) -> Element(msg) {
  ui.card([], [
    ui.card_header([], [ui.card_title([text("Responses")])]),
    ui.card_content([], [
      ui.stack([], [
        ui.table([], [
          ui.table_body(
            [],
            list.map(operation.responses, fn(reply) {
              ui.table_row([], [
                ui.table_cell([attribute.style("width", "5rem")], [
                  documents.status_badge(result.unwrap(
                    int.parse(reply.status),
                    0,
                  )),
                ]),
                ui.table_cell([], [text(reply.description)]),
                ui.table_cell([], [
                  case reply.schema {
                    Some(schema) -> layout.mono(api_spec.type_text(schema))
                    None -> ui.muted("no body")
                  },
                ]),
                ui.table_cell([], [
                  ui.muted(option.unwrap(reply.media_type, "")),
                ]),
              ])
            }),
          ),
        ]),
        schema_tables(document, operation),
      ]),
    ]),
  ])
}

/// The fields of the named schemas the responses use, once each.
fn schema_tables(document: Document, operation: Operation) -> Element(msg) {
  let names =
    list.filter_map(operation.responses, fn(reply) {
      option.then(reply.schema, fn(schema) {
        case api_spec.reference(schema) {
          Some(name) -> Some(name)
          None -> api_spec.items(schema) |> option.then(api_spec.reference)
        }
      })
      |> option.to_result(Nil)
    })
    |> list.unique
  ui.stack(
    [],
    list.filter_map(names, fn(name) {
      dict.get(document.schemas, name)
      |> result.map(fn(schema) {
        ui.stack([], [ui.h4(name), fields_table(document, schema)])
      })
    }),
  )
}

fn schema_card(
  title: String,
  document: Document,
  schema: Dynamic,
) -> Element(msg) {
  ui.card([], [
    ui.card_header([], [
      ui.card_title([text(title)]),
      ui.card_description([layout.mono(api_spec.type_text(schema))]),
    ]),
    ui.card_content([], [fields_table(document, schema)]),
  ])
}

fn fields_table(document: Document, schema: Dynamic) -> Element(msg) {
  case api_spec.properties(document, schema) {
    [] -> element.none()
    properties ->
      ui.table([], [
        ui.table_header([], [
          ui.table_row([], [
            ui.table_head([], [text("Field")]),
            ui.table_head([], [text("Type")]),
            ui.table_head([], [text("Notes")]),
          ]),
        ]),
        ui.table_body(
          [],
          list.map(properties, fn(property) {
            let #(name, schema, required) = property
            ui.table_row([], [
              ui.table_cell([], [
                layout.mono(name),
                case required {
                  True -> text(" *")
                  False -> element.none()
                },
              ]),
              ui.table_cell([], [text(api_spec.type_text(schema))]),
              ui.table_cell([], [ui.muted(api_spec.notes(schema))]),
            ])
          }),
        ),
      ])
  }
}

fn outcome_card(outcome: calling.Outcome) -> Element(msg) {
  case outcome {
    calling.Failed(error) -> layout.problem(error)
    calling.Outcome(status:, headers:, body:, milliseconds:, as_user:, curl:) ->
      ui.card([attribute.id("response")], [
        ui.card_header([], [
          ui.card_title([text("Response "), documents.status_badge(status)]),
          ui.card_description([
            text(float.to_string(float.to_precision(milliseconds, 1)) <> " ms"),
            text(case as_user {
              Some(email) -> " · as " <> email
              None -> " · anonymously"
            }),
          ]),
        ]),
        ui.card_content([], [
          ui.stack([], [
            case body {
              "" -> ui.muted("No body.")
              body -> documents.monospace(api_spec.pretty_text(body))
            },
            ui.table([], [
              ui.table_body(
                [],
                list.map(headers, fn(header) {
                  ui.table_row([], [
                    ui.table_cell([], [layout.mono(header.0)]),
                    ui.table_cell([], [text(header.1)]),
                  ])
                }),
              ),
            ]),
            ui.h4("As curl"),
            documents.monospace(curl),
          ]),
        ]),
      ])
  }
}
