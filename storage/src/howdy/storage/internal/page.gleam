//// Paging a sorted listing, for the adapters that list in memory.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import howdy/storage

/// Whether `key` belongs in a listing of `prefix` after `after`.
pub fn wanted(key: String, prefix: String, after: Option(String)) -> Bool {
  string.starts_with(key, prefix)
  && case after {
    Some(after) -> string.compare(key, after) == order.Gt
    None -> True
  }
}

/// The first `limit` of `matching`, which is sorted by key, with the key
/// to go on from if there are more.
pub fn of(matching: List(storage.Summary), limit: Int) -> storage.Page {
  let objects = list.take(matching, limit)
  let next = case list.length(matching) > limit, list.last(objects) {
    True, Ok(last) -> Some(last.key)
    _, _ -> None
  }
  storage.Page(objects:, next:)
}
