//// The database pages: the list of tables, a live grid of each table's
//// rows, and forms to insert, edit and delete a row.

import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import gloo/repo.{type Repo}
import howdy/admin/internal/config.{type Config}
import howdy/admin/internal/data/forms
import howdy/admin/internal/data/grid
import howdy/admin/internal/layout
import howdy/admin/internal/schema.{Row}
import howdy/content.{type Content}
import howdy/controller.{type Context, type Controller}
import howdy/database.{Postgres, Sqlite}
import howdy/form
import howdy/ui
import howdy/ui/button
import howdy/ui/live
import lustre/attribute
import lustre/element.{text}
import lustre/element/html

pub fn controller(config: Config, repo: Repo) -> Controller {
  controller.new(config.prefix)
  |> controller.get("/data", fn(ctx) { index(config, repo, ctx) })
  |> controller.get("/data/:table", fn(ctx) { show(config, repo, ctx) })
  |> controller.get("/data/:table/new", fn(ctx) { new(config, repo, ctx) })
  |> controller.post("/data/:table", fn(ctx) { create(config, repo, ctx) })
  |> controller.get("/data/:table/row", fn(ctx) { edit(config, repo, ctx) })
  |> controller.post("/data/:table/row", fn(ctx) { save(config, repo, ctx) })
  |> controller.post("/data/:table/row/delete", fn(ctx) {
    remove(config, repo, ctx)
  })
  |> controller.get("/live/data/:table", fn(ctx) { socket(config, repo, ctx) })
}

// -- Pages -------------------------------------------------------------------

/// Howdy's own packages keep their tables under this prefix. They are
/// hidden by default so the application's own stand out; `?all=1` shows
/// them.
const framework_prefix = "howdy_"

fn index(config: Config, repo: Repo, ctx: Context) -> Response(Content) {
  let all =
    request.get_query(ctx.request) |> result.unwrap([]) |> list.key_find("all")
    == Ok("1")
  let listed = {
    use names <- result.try(schema.tables(repo))
    let hidden =
      list.count(names, fn(name) { string.starts_with(name, framework_prefix) })
    let names = case all {
      True -> names
      False ->
        list.filter(names, fn(name) {
          !string.starts_with(name, framework_prefix)
        })
    }
    use backend <- result.try(database.backend(repo))
    use counted <- result.try(
      list.try_map(names, fn(name) {
        use table <- result.try(schema.table(repo, name))
        use count <- result.try(schema.count(repo, table, schema.query()))
        Ok(#(table, count))
      }),
    )
    Ok(#(backend, counted, hidden))
  }
  case listed {
    Error(error) ->
      layout.failure(
        config,
        ctx,
        current: "/data",
        heading: "Tables",
        error:,
        back: config.path(config, ""),
      )
    Ok(#(backend, tables, hidden)) ->
      layout.page(
        config,
        ctx,
        current: "/data",
        heading: "Tables",
        live: False,
        content: [
          ui.p([
            text(case backend {
              Postgres -> "PostgreSQL"
              Sqlite -> "SQLite"
            }),
            text(" · "),
            text(int.to_string(list.length(tables)) <> " tables"),
            case all, hidden {
              _, 0 -> element.none()
              True, _ ->
                element.fragment([
                  text(" · "),
                  ui.link(config.path(config, "/data"), [
                    text("Hide Howdy's own tables"),
                  ]),
                ])
              False, _ ->
                element.fragment([
                  text(" · "),
                  ui.link(config.path(config, "/data?all=1"), [
                    text(
                      "Show " <> int.to_string(hidden) <> " Howdy tables too",
                    ),
                  ]),
                ])
            },
          ]),
          ui.table([], [
            ui.table_header([], [
              ui.table_row([], [
                ui.table_head([], [text("Table")]),
                ui.table_head([], [text("Columns")]),
                ui.table_head([], [text("Rows")]),
              ]),
            ]),
            ui.table_body(
              [],
              list.map(tables, fn(entry) {
                let #(table, count) = entry
                ui.table_row([], [
                  ui.table_cell([], [
                    ui.link(forms.table_path(config, table.name), [
                      text(table.name),
                    ]),
                  ]),
                  ui.table_cell([], [
                    text(int.to_string(list.length(table.columns))),
                  ]),
                  ui.table_cell([], [text(int.to_string(count))]),
                ])
              }),
            ),
          ]),
        ],
      )
  }
}

fn show(config: Config, repo: Repo, ctx: Context) -> Response(Content) {
  use table <- forms.with_table(config, repo, ctx)
  layout.page(
    config,
    ctx,
    current: "/data",
    heading: table.name,
    live: True,
    content: [
      ui.row([], [
        ui.link(config.path(config, "/data"), [text("All tables")]),
        ui.link(forms.table_path(config, table.name) <> "/new", [
          text("Insert row"),
        ]),
      ]),
      live.mount(config.path(
        config,
        "/live/data/" <> uri.percent_encode(table.name),
      )),
      ui.card([], [
        ui.card_header([], [ui.card_title([text("Columns")])]),
        ui.card_content([], [
          ui.table([], [
            ui.table_header([], [
              ui.table_row([], [
                ui.table_head([], [text("Name")]),
                ui.table_head([], [text("Type")]),
                ui.table_head([], [text("Nullable")]),
                ui.table_head([], [text("Key")]),
              ]),
            ]),
            ui.table_body(
              [],
              list.map(table.columns, fn(column) {
                ui.table_row([], [
                  ui.table_cell([], [text(column.name)]),
                  ui.table_cell([], [text(column.kind)]),
                  ui.table_cell([], [text(forms.yes_no(column.nullable))]),
                  ui.table_cell([], [text(forms.yes_no(column.key))]),
                ])
              }),
            ),
          ]),
        ]),
      ]),
    ],
  )
}

fn new(config: Config, repo: Repo, ctx: Context) -> Response(Content) {
  use table <- forms.with_table(config, repo, ctx)
  layout.page(
    config,
    ctx,
    current: "/data",
    heading: "Insert into " <> table.name,
    live: False,
    content: [
      ui.p([
        ui.muted(
          "Columns left empty take their default. Tick NULL to store a null.",
        ),
      ]),
      forms.row_form(
        action: forms.table_path(config, table.name),
        table:,
        row: None,
        submit: "Insert",
        cancel: forms.table_path(config, table.name),
      ),
    ],
  )
}

fn create(config: Config, repo: Repo, ctx: Context) -> Response(Content) {
  use table <- forms.with_table(config, repo, ctx)
  use form <- form.read(ctx)
  let values =
    list.filter_map(table.columns, fn(column) {
      case forms.submitted(form, column) {
        Some(value) -> Ok(#(column, value))
        None -> Error(Nil)
      }
    })
  case schema.insert(repo, table, values) {
    Ok(Nil) -> layout.redirect(forms.table_path(config, table.name))
    Error(error) ->
      layout.page(
        config,
        ctx,
        current: "/data",
        heading: "Insert into " <> table.name,
        live: False,
        content: [
          layout.problem(error),
          forms.row_form(
            action: forms.table_path(config, table.name),
            table:,
            row: Some(Row(
              key: [],
              cells: list.map(table.columns, fn(column) {
                option.flatten(forms.submitted(form, column))
              }),
            )),
            submit: "Insert",
            cancel: forms.table_path(config, table.name),
          ),
        ],
      )
  }
}

fn edit(config: Config, repo: Repo, ctx: Context) -> Response(Content) {
  use table <- forms.with_table(config, repo, ctx)
  let key = forms.key_from(ctx)
  case schema.row(repo, table, key) {
    Error(error) ->
      layout.failure(
        config,
        ctx,
        current: "/data",
        heading: table.name,
        error:,
        back: forms.table_path(config, table.name),
      )
    Ok(row) ->
      layout.page(
        config,
        ctx,
        current: "/data",
        heading: "Edit " <> table.name <> " " <> string.join(row.key, ", "),
        live: False,
        content: [
          forms.row_form(
            action: forms.row_path(config, table.name, row.key),
            table:,
            row: Some(row),
            submit: "Save",
            cancel: forms.table_path(config, table.name),
          ),
          html.form(
            [
              attribute.method("post"),
              attribute.action(
                forms.row_path(config, table.name, row.key) <> "/delete",
              ),
            ],
            [ui.submit_button(button.Danger, [], [text("Delete row")])],
          ),
        ],
      )
  }
}

fn save(config: Config, repo: Repo, ctx: Context) -> Response(Content) {
  use table <- forms.with_table(config, repo, ctx)
  let key = forms.key_from(ctx)
  use form <- form.read(ctx)
  // Key columns are shown but not written; the key names the row.
  let editable = list.filter(table.columns, fn(column) { !column.key })
  let values =
    list.map(editable, fn(column) {
      #(column, case forms.submitted(form, column) {
        Some(value) -> value
        None -> Some("")
      })
    })
  case schema.update(repo, table, key, values) {
    Ok(Nil) -> layout.redirect(forms.table_path(config, table.name))
    Error(error) ->
      layout.page(
        config,
        ctx,
        current: "/data",
        heading: "Edit " <> table.name,
        live: False,
        content: [
          layout.problem(error),
          forms.row_form(
            action: forms.row_path(config, table.name, key),
            table:,
            row: Some(Row(
              key:,
              cells: list.map(table.columns, fn(column) {
                option.flatten(forms.submitted(form, column))
              }),
            )),
            submit: "Save",
            cancel: forms.table_path(config, table.name),
          ),
        ],
      )
  }
}

fn remove(config: Config, repo: Repo, ctx: Context) -> Response(Content) {
  use table <- forms.with_table(config, repo, ctx)
  case schema.delete(repo, table, forms.key_from(ctx)) {
    Ok(Nil) -> layout.redirect(forms.table_path(config, table.name))
    Error(error) ->
      layout.failure(
        config,
        ctx,
        current: "/data",
        heading: table.name,
        error:,
        back: forms.table_path(config, table.name),
      )
  }
}

fn socket(config: Config, repo: Repo, ctx: Context) -> Response(Content) {
  use table <- forms.with_table(config, repo, ctx)
  live.serve(ctx, grid.grid(), with: grid.Args(config, repo, table))
}
