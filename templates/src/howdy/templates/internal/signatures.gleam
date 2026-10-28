//// Gleam function parameters, read from source: the ones a template's
//// header functions declare.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Param {
  Param(label: Option(String), name: String, type_: String)
}

/// `label name: Type`, `name: Type`, `label name` or `name`.
pub fn param(source: String) -> Result(Param, Nil) {
  let #(before, type_) = case string.split_once(source, ":") {
    Ok(#(before, type_)) -> #(before, string.trim(type_))
    Error(_) -> #(source, "")
  }
  case
    string.split(string.trim(before), " ") |> list.filter(fn(w) { w != "" })
  {
    [name] -> Ok(Param(label: None, name:, type_:))
    [label, name] -> Ok(Param(label: Some(label), name:, type_:))
    _ -> Error(Nil)
  }
}
