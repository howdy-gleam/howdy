//// The row form the insert and edit pages share, what it says, and the
//// paths of tables and rows.

import gleam/http/request
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/uri
import gloo/repo.{type Repo}
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/layout
import howdy/admin/internal/schema.{type Row, type Table, Row}
import howdy/content.{type Content}
import howdy/controller.{type Context}
import howdy/form
import howdy/ui
import howdy/ui/button
import lustre/attribute
import lustre/element.{type Element, text}
import lustre/element/html

/// One input per column, with a NULL checkbox for nullable ones. Key
/// columns of an existing row are read-only.
pub fn row_form(
  action action: String,
  table table: Table,
  row row: Option(Row),
  submit submit: String,
  cancel cancel: String,
) -> Element(msg) {
  let cells = case row {
    Some(row) -> row.cells
    None -> list.map(table.columns, fn(_) { None })
  }
  let existing = case row {
    Some(Row(key: [_, ..], ..)) -> True
    _ -> False
  }
  html.form([attribute.method("post"), attribute.action(action)], [
    ui.stack(
      [],
      list.append(
        list.map2(table.columns, cells, fn(column, value) {
          let id = "column-" <> column.name
          let locked = existing && column.key
          ui.field([], [
            ui.label([attribute.for(id)], [
              text(column.name),
              text(" "),
              ui.muted(column.kind),
            ]),
            ui.input([
              attribute.id(id),
              attribute.name("value-" <> column.name),
              attribute.value(option.unwrap(value, "")),
              attribute.readonly(locked),
            ]),
            case column.nullable && !locked {
              True ->
                ui.choice(
                  ui.checkbox([
                    attribute.name("null-" <> column.name),
                    attribute.value("1"),
                    attribute.checked(value == None && row != None),
                  ]),
                  [text("NULL")],
                )
              False -> element.none()
            },
          ])
        }),
        [
          ui.row([], [
            ui.submit_button(button.Primary, [], [text(submit)]),
            ui.link(cancel, [text("Cancel")]),
          ]),
        ],
      ),
    ),
  ])
}

/// What the form said about a column: `None` when it was left empty and
/// should take its default, `Some(None)` for an explicit NULL.
pub fn submitted(
  form: form.Form,
  column: schema.Column,
) -> Option(Option(String)) {
  case
    form.get(form, "null-" <> column.name),
    form.get(form, "value-" <> column.name)
  {
    Ok(_), _ -> Some(None)
    _, Ok("") -> None
    _, Ok(value) -> Some(Some(value))
    _, Error(_) -> None
  }
}

pub fn with_table(
  config: Config,
  repo: Repo,
  ctx: Context,
  next: fn(Table) -> Response(Content),
) -> Response(Content) {
  let name = result.unwrap(controller.param(ctx, "table"), "")
  case schema.table(repo, name) {
    Ok(table) -> next(table)
    Error(error) ->
      layout.failure(
        config,
        ctx,
        current: "/data",
        heading: "Tables",
        error:,
        back: config.path(config, "/data"),
      )
  }
}

/// The row key from the `k` query parameters, one per key column.
pub fn key_from(ctx: Context) -> List(String) {
  request.get_query(ctx.request)
  |> result.unwrap([])
  |> list.filter_map(fn(pair) {
    case pair {
      #("k", value) -> Ok(value)
      _ -> Error(Nil)
    }
  })
}

pub fn table_path(config: Config, table: String) -> String {
  config.path(config, "/data/" <> uri.percent_encode(table))
}

pub fn row_path(config: Config, table: String, key: List(String)) -> String {
  table_path(config, table)
  <> "/row?"
  <> uri.query_to_string(list.map(key, fn(value) { #("k", value) }))
}

pub fn yes_no(flag: Bool) -> String {
  case flag {
    True -> "yes"
    False -> "no"
  }
}
