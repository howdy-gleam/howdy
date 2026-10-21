//// Tables, columns and rows of whatever database the application opened,
//// on PostgreSQL and SQLite. Every value crosses as text: the admin shows
//// and edits any column without knowing its type, and the database casts
//// what it is given. Driver errors are shown, not hidden: this runs in
//// development, for the developer.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gloo/error
import gloo/repo.{type Repo}
import gloo/sql
import gloo/value.{type GlooValue}
import howdy/database.{type Backend, Postgres, Sqlite}
import howdy/service

pub type Column {
  Column(name: String, kind: String, nullable: Bool, key: Bool)
}

/// How a row is identified: by its primary key, or, without one, by the
/// database's own row address.
pub type Key {
  Columns(List(Column))
  RowId
  Ctid
}

pub type Table {
  Table(name: String, backend: Backend, columns: List(Column), key: Key)
}

/// `key` has one value per key column, or one row address.
pub type Row {
  Row(key: List(String), cells: List(Option(String)))
}

@external(erlang, "howdy_admin_ffi", "cells")
fn cells(row: Dynamic) -> List(Option(String))

/// Every table in the application's schema, by name.
pub fn tables(repo: Repo) -> service.Result(List(String)) {
  use conn <- database.connect(repo)
  use backend <- result.try(database.backend(conn))
  let statement = case backend {
    Postgres ->
      "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r', 'p') AND n.nspname = current_schema() ORDER BY c.relname"
    Sqlite ->
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
  }
  all(conn, statement, [], decode.field(0, decode.string, decode.success))
}

/// The table, or `NotFound` when the schema has no table of that name.
/// `name` may come from a request: it is matched against the schema, never
/// interpolated.
pub fn table(repo: Repo, name: String) -> service.Result(Table) {
  use names <- result.try(tables(repo))
  use _ <- result.try(case list.contains(names, name) {
    True -> Ok(Nil)
    False -> Error(service.NotFound("table"))
  })
  use conn <- database.connect(repo)
  use backend <- result.try(database.backend(conn))
  use columns <- result.try(case backend {
    Postgres ->
      all(
        conn,
        "SELECT a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull, EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = a.attrelid AND i.indisprimary AND a.attnum = ANY (i.indkey)) FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = current_schema() AND c.relname = $1 AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum",
        [sql.string(name)],
        {
          use name <- decode.field(0, decode.string)
          use kind <- decode.field(1, decode.string)
          use required <- decode.field(2, decode.bool)
          use key <- decode.field(3, decode.bool)
          decode.success(Column(name:, kind:, nullable: !required, key:))
        },
      )
    Sqlite ->
      all(
        conn,
        "SELECT name, type, \"notnull\", pk FROM pragma_table_info($1) ORDER BY cid",
        [sql.string(name)],
        {
          use name <- decode.field(0, decode.string)
          use kind <- decode.field(1, decode.string)
          use required <- decode.field(2, decode.int)
          use key <- decode.field(3, decode.int)
          decode.success(Column(
            name:,
            kind:,
            nullable: required == 0,
            key: key > 0,
          ))
        },
      )
  })
  let key = case list.filter(columns, fn(column) { column.key }), backend {
    [], Sqlite -> RowId
    [], Postgres -> Ctid
    keys, _ -> Columns(keys)
  }
  Ok(Table(name:, backend:, columns:, key:))
}

/// The names of what identifies a row, for headings.
pub fn key_names(table: Table) -> List(String) {
  case table.key {
    Columns(columns) -> list.map(columns, fn(column) { column.name })
    RowId -> ["rowid"]
    Ctid -> ["ctid"]
  }
}

// -- Queries -----------------------------------------------------------------

pub type Direction {
  Ascending
  Descending
}

pub type Operator {
  Equals
  NotEquals
  Contains
  Greater
  Less
  IsNull
  NotNull
}

/// One condition on one column. `value` is ignored by `IsNull` and
/// `NotNull`.
pub type Filter {
  Filter(column: String, operator: Operator, value: String)
}

/// What to show of a table: a page of the rows matching a search across
/// every column and a list of filters, in a chosen order.
pub type Query {
  Query(
    search: String,
    filters: List(Filter),
    sort: Option(#(String, Direction)),
    limit: Int,
    offset: Int,
  )
}

/// Everything, in key order, fifty at a time.
pub fn query() -> Query {
  Query(search: "", filters: [], sort: None, limit: 50, offset: 0)
}

pub fn operators() -> List(Operator) {
  [Equals, NotEquals, Contains, Greater, Less, IsNull, NotNull]
}

/// The operator's form value and label.
pub fn operator_name(operator: Operator) -> String {
  case operator {
    Equals -> "eq"
    NotEquals -> "ne"
    Contains -> "contains"
    Greater -> "gt"
    Less -> "lt"
    IsNull -> "null"
    NotNull -> "not_null"
  }
}

pub fn operator_label(operator: Operator) -> String {
  case operator {
    Equals -> "="
    NotEquals -> "≠"
    Contains -> "contains"
    Greater -> ">"
    Less -> "<"
    IsNull -> "is null"
    NotNull -> "is not null"
  }
}

pub fn operator_from(name: String) -> Result(Operator, Nil) {
  list.find(operators(), fn(operator) { operator_name(operator) == name })
}

/// How many rows match the query's search and filters.
pub fn count(repo: Repo, table: Table, query: Query) -> service.Result(Int) {
  use conn <- database.connect(repo)
  let #(where, parameters) = conditions(table, query, from: 1)
  use counts <- result.try(all(
    conn,
    "SELECT COUNT(*) FROM " <> quote(table.name) <> where,
    parameters,
    decode.field(0, decode.int, decode.success),
  ))
  case counts {
    [count, ..] -> Ok(count)
    [] -> Ok(0)
  }
}

/// The query's page of rows.
pub fn rows(
  repo: Repo,
  table: Table,
  query: Query,
) -> service.Result(List(Row)) {
  use conn <- database.connect(repo)
  let #(where, parameters) = conditions(table, query, from: 1)
  let next = list.length(parameters) + 1
  all(
    conn,
    select(table)
      <> where
      <> " ORDER BY "
      <> string.join(order(table, query), ", ")
      <> " LIMIT $"
      <> int.to_string(next)
      <> " OFFSET $"
      <> int.to_string(next + 1),
    list.append(parameters, [sql.int(query.limit), sql.int(query.offset)]),
    row_decoder(table),
  )
}

/// A `WHERE` clause for the search and every filter naming a real column,
/// numbering placeholders from `from`. Empty when there is nothing to
/// match, so it can be appended as is.
fn conditions(
  table: Table,
  query: Query,
  from from: Int,
) -> #(String, List(GlooValue)) {
  let search = case string.trim(query.search) {
    "" -> []
    term -> {
      let pattern = sql.string("%" <> escape_like(term) <> "%")
      [
        list.map(table.columns, fn(column) {
          #(contains(table, column, "$"), pattern)
        }),
      ]
    }
  }
  let filters =
    list.filter_map(query.filters, fn(filter) {
      use column <- result.try(
        list.find(table.columns, fn(column) { column.name == filter.column }),
      )
      Ok([
        case filter.operator {
          Equals -> #(quote(column.name) <> " = $", sql.string(filter.value))
          NotEquals -> #(
            quote(column.name) <> " <> $",
            sql.string(filter.value),
          )
          Greater -> #(quote(column.name) <> " > $", sql.string(filter.value))
          Less -> #(quote(column.name) <> " < $", sql.string(filter.value))
          Contains -> #(
            contains(table, column, "$"),
            sql.string("%" <> escape_like(filter.value) <> "%"),
          )
          IsNull -> #(quote(column.name) <> " IS NULL", value.GNull)
          NotNull -> #(quote(column.name) <> " IS NOT NULL", value.GNull)
        }
        |> fn(pair) {
          case filter.operator {
            Equals | NotEquals | Greater | Less -> #(
              string.replace(pair.0, " $", " " <> typed(table, column, "$")),
              pair.1,
            )
            _ -> pair
          }
        },
      ])
    })
  // Each group is OR-ed within and AND-ed with the others.
  let groups = list.append(search, filters)
  let #(clauses, parameters, _) =
    list.fold(groups, #([], [], from), fn(state, group) {
      let #(clauses, parameters, next) = state
      let #(parts, parameters, next) =
        list.fold(group, #([], parameters, next), fn(state, part) {
          let #(parts, parameters, next) = state
          let #(text, parameter) = part
          case parameter {
            value.GNull -> #([text, ..parts], parameters, next)
            _ -> #(
              [string.replace(text, "$", "$" <> int.to_string(next)), ..parts],
              [parameter, ..parameters],
              next + 1,
            )
          }
        })
      #(
        ["(" <> string.join(list.reverse(parts), " OR ") <> ")", ..clauses],
        parameters,
        next,
      )
    })
  case clauses {
    [] -> #("", [])
    _ -> #(
      " WHERE " <> string.join(list.reverse(clauses), " AND "),
      list.reverse(parameters),
    )
  }
}

/// A case-insensitive substring match on the column read as text.
fn contains(table: Table, column: Column, placeholder: String) -> String {
  case table.backend {
    Postgres ->
      "CAST(" <> quote(column.name) <> " AS text) ILIKE " <> placeholder
    // SQLite has no default escape character, so the backslashes
    // `escape_like` adds mean nothing without this.
    Sqlite ->
      "CAST("
      <> quote(column.name)
      <> " AS text) LIKE "
      <> placeholder
      <> " ESCAPE '\\'"
  }
}

/// A placeholder cast to the column's type, for comparisons. See `bind`.
fn typed(table: Table, column: Column, placeholder: String) -> String {
  case table.backend {
    Postgres ->
      "CAST(CAST(" <> placeholder <> " AS text) AS " <> column.kind <> ")"
    Sqlite -> placeholder
  }
}

fn escape_like(term: String) -> String {
  term
  |> string.replace("%", "\\%")
  |> string.replace("_", "\\_")
}

fn order(table: Table, query: Query) -> List(String) {
  let key = case table.key {
    Columns(columns) -> list.map(columns, fn(column) { quote(column.name) })
    RowId -> ["rowid"]
    Ctid -> ["ctid"]
  }
  case query.sort {
    Some(#(name, direction)) ->
      case list.find(table.columns, fn(column) { column.name == name }) {
        Ok(column) -> [
          quote(column.name)
            <> case direction {
            Ascending -> " ASC"
            Descending -> " DESC"
          },
          ..key
        ]
        Error(Nil) -> key
      }
    None -> key
  }
}

/// One row by key, or `NotFound`.
pub fn row(repo: Repo, table: Table, key: List(String)) -> service.Result(Row) {
  use conn <- database.connect(repo)
  use #(condition, parameters) <- result.try(condition(table, key, from: 1))
  use rows <- result.try(all(
    conn,
    select(table) <> " WHERE " <> condition,
    parameters,
    row_decoder(table),
  ))
  case rows {
    [row, ..] -> Ok(row)
    [] -> Error(service.NotFound("row"))
  }
}

/// Insert a row. Columns given `None` are set to NULL; columns not given
/// take their defaults.
pub fn insert(
  repo: Repo,
  table: Table,
  values: List(#(Column, Option(String))),
) -> service.Result(Nil) {
  use conn <- database.connect(repo)
  case values {
    [] ->
      execute(
        conn,
        "INSERT INTO " <> quote(table.name) <> " DEFAULT VALUES",
        [],
      )
    _ -> {
      let names =
        list.map(values, fn(value) { quote({ value.0 }.name) })
        |> string.join(", ")
      let placeholders =
        list.index_map(values, fn(value, index) {
          bind(table, value.0, index + 1)
        })
        |> string.join(", ")
      execute(
        conn,
        "INSERT INTO "
          <> quote(table.name)
          <> " ("
          <> names
          <> ") VALUES ("
          <> placeholders
          <> ")",
        list.map(values, fn(value) { parameter(value.1) }),
      )
    }
  }
}

/// Write the given columns of the row at `key`.
pub fn update(
  repo: Repo,
  table: Table,
  key: List(String),
  values: List(#(Column, Option(String))),
) -> service.Result(Nil) {
  use conn <- database.connect(repo)
  use _ <- result.try(case values {
    [] -> Error(service.Invalid("nothing to update"))
    _ -> Ok(Nil)
  })
  let assignments =
    list.index_map(values, fn(value, index) {
      quote({ value.0 }.name) <> " = " <> bind(table, value.0, index + 1)
    })
    |> string.join(", ")
  use #(condition, parameters) <- result.try(condition(
    table,
    key,
    from: list.length(values) + 1,
  ))
  execute(
    conn,
    "UPDATE "
      <> quote(table.name)
      <> " SET "
      <> assignments
      <> " WHERE "
      <> condition,
    list.append(list.map(values, fn(value) { parameter(value.1) }), parameters),
  )
}

pub fn delete(
  repo: Repo,
  table: Table,
  key: List(String),
) -> service.Result(Nil) {
  use conn <- database.connect(repo)
  use #(condition, parameters) <- result.try(condition(table, key, from: 1))
  execute(
    conn,
    "DELETE FROM " <> quote(table.name) <> " WHERE " <> condition,
    parameters,
  )
}

// -- SQL ---------------------------------------------------------------------

/// A double-quoted identifier. Names come from the schema itself.
pub fn quote(name: String) -> String {
  "\"" <> string.replace(name, "\"", "\"\"") <> "\""
}

/// The key expressions, then every column.
fn select(table: Table) -> String {
  let key = case table.key {
    Columns(columns) -> list.map(columns, fn(column) { quote(column.name) })
    RowId -> ["rowid"]
    Ctid -> ["ctid::text"]
  }
  let columns = list.map(table.columns, fn(column) { quote(column.name) })
  "SELECT "
  <> string.join(list.append(key, columns), ", ")
  <> " FROM "
  <> quote(table.name)
}

fn row_decoder(table: Table) -> decode.Decoder(Row) {
  let width = case table.key {
    Columns(columns) -> list.length(columns)
    RowId | Ctid -> 1
  }
  use row <- decode.then(decode.dynamic)
  let #(key, cells) = list.split(cells(row), width)
  decode.success(Row(
    key: list.map(key, fn(value) { option.unwrap(value, "") }),
    cells:,
  ))
}

/// A placeholder that the database casts to the column's type. Every value
/// is sent as text. On PostgreSQL the parameter is declared text first, so
/// the driver does not infer the column's type and refuse the string, and
/// is then cast; SQLite converts by column affinity on its own.
fn bind(table: Table, column: Column, index: Int) -> String {
  let placeholder = "$" <> int.to_string(index)
  case table.backend {
    Postgres ->
      "CAST(CAST(" <> placeholder <> " AS text) AS " <> column.kind <> ")"
    Sqlite -> placeholder
  }
}

fn parameter(value: Option(String)) -> GlooValue {
  value.nullable(sql.string, value)
}

/// `WHERE` text and parameters that match `key`, numbering placeholders
/// from `from`.
fn condition(
  table: Table,
  key: List(String),
  from from: Int,
) -> service.Result(#(String, List(GlooValue))) {
  case table.key, key {
    RowId, [id] ->
      case int.parse(id) {
        Ok(id) -> Ok(#("rowid = $" <> int.to_string(from), [sql.int(id)]))
        Error(_) -> Error(service.Invalid("the row id must be a number"))
      }
    Ctid, [address] ->
      Ok(
        #("ctid = CAST(CAST($" <> int.to_string(from) <> " AS text) AS tid)", [
          sql.string(address),
        ]),
      )
    Columns(columns), values ->
      case list.strict_zip(columns, values) {
        Error(_) -> Error(service.Invalid("the key does not match the table"))
        Ok(pairs) -> {
          let conditions =
            list.index_map(pairs, fn(pair, index) {
              quote({ pair.0 }.name)
              <> " = "
              <> bind(table, pair.0, from + index)
            })
          Ok(#(string.join(conditions, " AND "), list.map(values, sql.string)))
        }
      }
    _, _ -> Error(service.Invalid("the key does not match the table"))
  }
}

fn all(
  conn: Repo,
  statement: String,
  parameters: List(GlooValue),
  decoder: decode.Decoder(a),
) -> service.Result(List(a)) {
  repo.all(conn, statement, parameters, decoder)
  |> result.map_error(failed)
}

fn execute(
  conn: Repo,
  statement: String,
  parameters: List(GlooValue),
) -> service.Result(Nil) {
  repo.execute(conn, statement, parameters)
  |> result.map(fn(_) { Nil })
  |> result.map_error(failed)
}

/// The driver's message, for the developer to read. Never do this in an
/// application: it can carry data from the row.
fn failed(reason: error.GlooError) -> service.Error {
  service.Invalid(error.to_string(reason))
}
