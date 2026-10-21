//// Notice when source files change by polling. Each poll records every
//// file's modification time, size and a checksum of its contents, so an
//// edit that keeps the size and lands in the same second, or one that
//// restores the timestamp, is still noticed. Polling needs no native file
//// watcher, so it works the same on Linux, macOS and Windows.

import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// What was known about one file.
pub type Stamp {
  Stamp(mtime_seconds: Int, size: Int, hash: Int)
}

/// What was known about every file at one moment.
pub type Snapshot =
  Dict(String, Stamp)

@external(erlang, "howdy_dev_ffi", "file_hash")
fn file_hash(path: String) -> Result(Int, Nil)

/// Every file under `directories`. A file that cannot be read, for example
/// one an editor is replacing, is left out and shows up again next poll.
pub fn snapshot(directories: List(String)) -> Snapshot {
  directories
  |> list.flat_map(fn(directory) {
    simplifile.get_files(in: directory) |> result.unwrap([])
  })
  |> list.filter_map(fn(path) {
    use info <- result.try(
      simplifile.file_info(path) |> result.replace_error(Nil),
    )
    use hash <- result.map(file_hash(path))
    #(path, Stamp(mtime_seconds: info.mtime_seconds, size: info.size, hash:))
  })
  |> dict.from_list
}

/// The paths that were added, removed or modified between two snapshots.
pub fn changed(before: Snapshot, after: Snapshot) -> List(String) {
  let gone =
    dict.keys(before)
    |> list.filter(fn(path) { !dict.has_key(after, path) })
  let new_or_modified =
    dict.to_list(after)
    |> list.filter_map(fn(entry) {
      let #(path, stamp) = entry
      case dict.get(before, path) {
        Ok(previous) if previous == stamp -> Error(Nil)
        _ -> Ok(path)
      }
    })
  list.append(gone, new_or_modified) |> list.sort(string.compare)
}
